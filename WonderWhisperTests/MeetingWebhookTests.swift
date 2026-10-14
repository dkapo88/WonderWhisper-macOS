import Foundation
import Testing
@testable import WonderWhisper

/// Scripted webhook transport: returns or throws the queued results in order and records
/// every request it receives.
final class FakeMeetingWebhookTransport: MeetingWebhookTransport, @unchecked Sendable {
  enum Step {
    case status(Int, retryAfter: String? = nil)
    case failure(Error)
  }

  private let lock = NSLock()
  private var steps: [Step]
  private var received: [URLRequest] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse {
    let step: Step = {
      lock.lock()
      defer { lock.unlock() }
      received.append(request)
      return steps.isEmpty ? .status(200) : steps.removeFirst()
    }()
    switch step {
    case let .status(code, retryAfter):
      return MeetingWebhookTransportResponse(statusCode: code, retryAfter: retryAfter)
    case let .failure(error):
      throw error
    }
  }
}

/// Records requested sleeps instead of waiting.
final class RecordingSleeper: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [TimeInterval] = []

  var delays: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func sleep(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(seconds)
  }
}

struct MeetingWebhookTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
  private static let appInfo = MeetingWebhookAppInfo(
    name: "WonderWhisper",
    version: "2026-10-12.1",
    build: "2026101201"
  )

  private static func session() -> MeetingSession {
    MeetingSession(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
      title: "Glofox planning",
      startedAt: fixedDate,
      endedAt: fixedDate.addingTimeInterval(2_712),
      recordedDuration: 2_712,
      detectedApp: "Google Meet",
      status: .completed,
      transcriptTokens: [
        MeetingTranscriptToken(source: .microphone, startTime: 0, endTime: 2, text: "Hello")
      ],
      notesMarkdown: "## Summary\n\n- Planned the sprint."
    )
  }

  private static func job(
    secret: String? = nil,
    headers: [String: String] = [:]
  ) -> MeetingWebhookDeliveryJob {
    MeetingWebhookDeliveryJob(
      deliveryID: UUID(),
      endpoint: MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook"),
      url: URL(string: "https://example.com/hook") ?? URL(fileURLWithPath: "/"),
      event: .noteCompleted,
      noteID: UUID(),
      noteTitle: "Glofox planning",
      body: Data(#"{"a":1}"#.utf8),
      signingSecret: secret,
      customHeaders: headers,
      userAgent: appInfo.userAgent
    )
  }

  private static func service(
    _ transport: FakeMeetingWebhookTransport,
    sleeper: RecordingSleeper = RecordingSleeper()
  ) -> MeetingWebhookDeliveryService {
    MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: { sleeper.sleep($0) },
      clock: { fixedDate },
      jitter: { 0 }
    )
  }

  // MARK: - Payload

  @Test func payloadEncodesNoteFieldsDatesAndMarkdown() throws {
    let session = Self.session()
    let deliveryID = UUID()
    let payload = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payload(
      for: session,
      event: .noteCompleted,
      deliveryID: deliveryID,
      sentAt: Self.fixedDate
    )
    let data = try MeetingWebhookPayloadBuilder.encode(payload)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let note = try #require(json["note"] as? [String: Any])
    let app = try #require(json["app"] as? [String: Any])

    #expect(json["event"] as? String == "meeting.note.completed")
    #expect(json["schemaVersion"] as? Int == 1)
    #expect(json["deliveryId"] as? String == deliveryID.uuidString)
    #expect(json["sentAt"] as? String == "2025-10-09T08:53:20Z")
    #expect(note["id"] as? String == session.id.uuidString)
    #expect(note["title"] as? String == "Glofox planning")
    #expect(note["startedAt"] as? String == "2025-10-09T08:53:20Z")
    #expect(note["endedAt"] as? String == "2025-10-09T09:38:32Z")
    #expect(note["durationSeconds"] as? Int == 2_712)
    #expect(note["detectedApp"] as? String == "Google Meet")
    #expect(note["markdown"] as? String == MeetingObsidianExporter.document(for: session))
    #expect(app["name"] as? String == "WonderWhisper")
    #expect(app["version"] as? String == "2026-10-12.1")
    #expect(app["build"] as? String == "2026101201")
  }

  @Test func payloadEncodesMissingEndAndAppAsNull() throws {
    var session = Self.session()
    session.endedAt = nil
    session.detectedApp = nil
    let payload = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payload(
      for: session, event: .test, deliveryID: UUID(), sentAt: Self.fixedDate
    )
    let raw = String(decoding: try MeetingWebhookPayloadBuilder.encode(payload), as: UTF8.self)
    #expect(raw.contains(#""endedAt":null"#))
    #expect(raw.contains(#""detectedApp":null"#))
    #expect(raw.contains(#""event":"webhook.test""#))
  }

  // MARK: - Signature and headers

  @Test func signatureMatchesKnownHMACVector() {
    // printf '1700000000.{"a":1}' | openssl dgst -sha256 -hmac 'topsecret'
    let signature = MeetingWebhookSigner.signature(
      secret: "topsecret",
      timestamp: 1_700_000_000,
      body: Data(#"{"a":1}"#.utf8)
    )
    #expect(
      signature == "sha256=6a939b0c71853d606167625a15168ee9188c6a511c773ef4f42d307f3849e50f"
    )
  }

  @Test func generatedSecretsAreRandomHex() {
    let first = MeetingWebhookSigner.generateSecret()
    #expect(first.count == 64)
    let isHex = first.allSatisfy { $0.isHexDigit }
    #expect(isHex)
    #expect(first != MeetingWebhookSigner.generateSecret())
  }

  @Test func customHeadersCannotOverrideReservedHeaders() {
    let deliveryID = UUID()
    let headers = MeetingWebhookRequestBuilder.headers(
      event: .noteCompleted,
      deliveryID: deliveryID,
      timestamp: 1_700_000_000,
      body: Data(#"{"a":1}"#.utf8),
      signingSecret: "topsecret",
      userAgent: "WonderWhisper/1",
      customHeaders: [
        "Authorization": "Bearer abc",
        "content-type": "text/plain",
        "X-WonderWhisper-Signature": "sha256=forged",
        "x-wonderwhisper-event": "forged",
        "Bad Header": "x"
      ]
    )
    #expect(headers["Authorization"] == "Bearer abc")
    #expect(headers["Content-Type"] == "application/json")
    #expect(headers["content-type"] == nil)
    #expect(headers["x-wonderwhisper-event"] == nil)
    #expect(headers["Bad Header"] == nil)
    #expect(headers["X-WonderWhisper-Event"] == "meeting.note.completed")
    #expect(headers["X-WonderWhisper-Delivery"] == deliveryID.uuidString.lowercased())
    #expect(headers["X-WonderWhisper-Timestamp"] == "1700000000")
    #expect(
      headers["X-WonderWhisper-Signature"]
        == "sha256=6a939b0c71853d606167625a15168ee9188c6a511c773ef4f42d307f3849e50f"
    )
    #expect(headers["User-Agent"] == "WonderWhisper/1")
  }

  @Test func unsignedRequestsCarryNoSignatureHeader() {
    let request = MeetingWebhookRequestBuilder.request(for: Self.job(), at: Self.fixedDate)
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 30)
    #expect(request.value(forHTTPHeaderField: "X-WonderWhisper-Signature") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  }

  // MARK: - Retry policy

  @Test func retryPolicyClassifiesStatuses() {
    #expect(MeetingWebhookRetryPolicy.outcome(forStatus: 200) == .delivered)
    #expect(MeetingWebhookRetryPolicy.outcome(forStatus: 204) == .delivered)
    for status in [408, 425, 429, 500, 502, 503, 599] {
      #expect(MeetingWebhookRetryPolicy.outcome(forStatus: status) == .retryable)
    }
    for status in [301, 302, 307, 400, 401, 403, 404, 410, 422] {
      #expect(MeetingWebhookRetryPolicy.outcome(forStatus: status) == .failed)
    }
    #expect(MeetingWebhookRetryPolicy.shouldRetry(URLError(.timedOut)))
    #expect(MeetingWebhookRetryPolicy.shouldRetry(URLError(.notConnectedToInternet)))
    #expect(!MeetingWebhookRetryPolicy.shouldRetry(URLError(.cancelled)))
    #expect(!MeetingWebhookRetryPolicy.shouldRetry(URLError(.badURL)))
    #expect(!MeetingWebhookRetryPolicy.shouldRetry(CancellationError()))
  }

  @Test func retryPolicyBackoffScheduleAndJitter() {
    let delays = (1...4).map { MeetingWebhookRetryPolicy.delay(afterAttempt: $0) }
    #expect(delays == [2, 10, 30, 120])
    #expect(MeetingWebhookRetryPolicy.delay(afterAttempt: 2, jitter: 1) == 12)
    let jittered = MeetingWebhookRetryPolicy.delay(afterAttempt: 3, jitter: 0.5)
    #expect(jittered > 30 && jittered < 36)
  }

  @Test func retryAfterIsParsedAndCapped() {
    let now = Self.fixedDate
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds("45", now: now) == 45)
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds("99999", now: now) == 600)
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds("-1", now: now) == nil)
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds("soon", now: now) == nil)
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds(nil, now: now) == nil)
    let date = "Thu, 09 Oct 2025 08:55:20 GMT"
    #expect(MeetingWebhookRetryPolicy.retryAfterSeconds(date, now: now) == 120)
    #expect(MeetingWebhookRetryPolicy.delay(afterAttempt: 1, retryAfter: 45) == 45)
    #expect(MeetingWebhookRetryPolicy.delay(afterAttempt: 1, retryAfter: 5_000) == 600)
  }

  // MARK: - Delivery

  @Test func deliverySucceedsOnFirstAttempt() async {
    let transport = FakeMeetingWebhookTransport([.status(200)])
    let sleeper = RecordingSleeper()
    let record = await Self.service(transport, sleeper: sleeper).deliver(Self.job())
    #expect(record.state == .delivered)
    #expect(record.attempts == 1)
    #expect(record.lastStatusCode == 200)
    #expect(record.lastError == nil)
    #expect(sleeper.delays.isEmpty)
  }

  @Test func deliveryRetriesServerErrorsThenSucceeds() async {
    let transport = FakeMeetingWebhookTransport([.status(500), .status(500), .status(200)])
    let sleeper = RecordingSleeper()
    let job = Self.job(secret: "topsecret")
    let record = await Self.service(transport, sleeper: sleeper).deliver(job)
    #expect(record.state == .delivered)
    #expect(record.attempts == 3)
    #expect(sleeper.delays == [2, 10])
    let deliveryIDs = Set(transport.requests.compactMap {
      $0.value(forHTTPHeaderField: "X-WonderWhisper-Delivery")
    })
    #expect(deliveryIDs == [job.deliveryID.uuidString.lowercased()])
    #expect(transport.requests.allSatisfy { $0.httpBody == job.body })
  }

  @Test func deliveryFailsUnauthorizedWithoutRetry() async {
    let transport = FakeMeetingWebhookTransport([.status(401), .status(200)])
    let sleeper = RecordingSleeper()
    let record = await Self.service(transport, sleeper: sleeper).deliver(Self.job())
    #expect(record.state == .failed)
    #expect(record.attempts == 1)
    #expect(record.lastStatusCode == 401)
    #expect(record.lastError == "HTTP 401")
    #expect(transport.requests.count == 1)
    #expect(sleeper.delays.isEmpty)
  }

  @Test func deliveryGivesUpAfterFiveAttempts() async {
    let transport = FakeMeetingWebhookTransport(Array(repeating: .status(503), count: 6))
    let sleeper = RecordingSleeper()
    let record = await Self.service(transport, sleeper: sleeper).deliver(Self.job())
    #expect(record.state == .failed)
    #expect(record.attempts == 5)
    #expect(record.lastError == "HTTP 503")
    #expect(transport.requests.count == 5)
    #expect(sleeper.delays == [2, 10, 30, 120])
  }

  @Test func deliveryRefusesRedirects() async {
    let transport = FakeMeetingWebhookTransport([.status(302)])
    let record = await Self.service(transport).deliver(Self.job())
    #expect(record.state == .failed)
    #expect(record.attempts == 1)
    #expect(record.lastStatusCode == 302)
    #expect(record.lastError?.contains("redirects are not followed") == true)
  }

  @Test func deliveryRetriesNetworkErrorsAndHonoursRetryAfter() async {
    let transport = FakeMeetingWebhookTransport([
      .failure(URLError(.notConnectedToInternet)),
      .status(429, retryAfter: "7"),
      .status(200)
    ])
    let sleeper = RecordingSleeper()
    let record = await Self.service(transport, sleeper: sleeper).deliver(Self.job())
    #expect(record.state == .delivered)
    #expect(record.attempts == 3)
    #expect(sleeper.delays == [2, 7])
  }

  @Test func deliveryReportsRetryingStates() async {
    let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
    let states = StateRecorder()
    _ = await Self.service(transport).deliver(Self.job()) { record in
      states.append(record.state)
    }
    #expect(states.values == [.sending, .retrying, .delivered])
  }

  // MARK: - URL validation

  @Test func urlValidationRules() {
    let valid = [
      "https://example.com/hook",
      "http://localhost:8080/hook",
      "http://127.0.0.1:3000",
      "http://10.0.0.5/hook",
      "http://172.16.4.2/hook",
      "http://192.168.1.10/hook",
      "http://100.74.170.50:8642/hook",
      "http://[::1]:9000/hook"
    ]
    for url in valid {
      #expect(MeetingWebhookURLValidator.validate(url).url != nil, "\(url) should be valid")
    }
    let invalid = [
      "",
      "not a url",
      "ftp://example.com/hook",
      "http://example.com/hook",
      "http://8.8.8.8/hook",
      "http://100.128.0.1/hook",
      "http://172.32.0.1/hook",
      "https://user:pass@example.com/hook",
      "https:///nohost"
    ]
    for url in invalid {
      #expect(MeetingWebhookURLValidator.validate(url).url == nil, "\(url) should be invalid")
    }
  }

  // MARK: - Status text

  @Test func statusTextDescribesEachState() {
    let record = MeetingWebhookDeliveryRecord(
      id: UUID(), endpointID: UUID(), endpointName: "Grok Bot", noteID: UUID(),
      noteTitle: "Planning", event: .noteCompleted, state: .retrying, attempts: 2,
      maximumAttempts: 5, lastStatusCode: 500, lastError: "HTTP 500",
      createdAt: Self.fixedDate, updatedAt: Self.fixedDate
    )
    #expect(MeetingWebhookStatusFormatter.text(for: record) == "Retrying Grok Bot (attempt 3 of 5)")
    var failed = record
    failed.state = .failed
    failed.lastError = "HTTP 401"
    #expect(MeetingWebhookStatusFormatter.text(for: failed) == "Grok Bot failed: HTTP 401")
    var delivered = record
    delivered.state = .delivered
    let text = MeetingWebhookStatusFormatter.text(
      for: delivered,
      now: Self.fixedDate.addingTimeInterval(10)
    )
    #expect(text == "Sent to Grok Bot just now")
  }

  // MARK: - Sync registry

  @Test func endpointsKeyIsExcludedFromSettingsSync() {
    let key = MeetingWebhookEndpointStore.defaultsKey
    #expect(key == "meeting.webhooks.endpoints")
    #expect(SettingsSyncRegistry.excluded[key] != nil)
    #expect(!SettingsSyncRegistry.syncedKeys.contains(key))
    #expect(!SettingsSyncRegistry.syncedKeys.contains { $0.hasPrefix("meeting.webhook") })
  }
}

/// Collects delivery states reported through `onUpdate`.
final class StateRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [MeetingWebhookDeliveryRecord.State] = []

  var values: [MeetingWebhookDeliveryRecord.State] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func append(_ state: MeetingWebhookDeliveryRecord.State) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(state)
  }
}
