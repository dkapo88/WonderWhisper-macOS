import Foundation
import Testing
@testable import WonderWhisper

/// A test clock that only moves when the paired sleeper "sleeps", so pacing runs instantly.
final class PacingTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var slept: [TimeInterval] = []

  init(_ start: Date) {
    current = start
  }

  var now: Date {
    lock.withLock { current }
  }

  var sleeps: [TimeInterval] {
    lock.withLock { slept }
  }

  func sleep(_ seconds: TimeInterval) {
    lock.withLock {
      slept.append(seconds)
      current = current.addingTimeInterval(max(0, seconds))
    }
  }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { current = current.addingTimeInterval(seconds) }
  }
}

/// Records request times, per-endpoint concurrency and answers scripted statuses.
final class PacingTestTransport: MeetingWebhookTransport, @unchecked Sendable {
  struct Sent {
    let host: String
    let time: Date
    let body: [String: Any]
  }

  private let lock = NSLock()
  private let clock: PacingTestClock?
  private var steps: [MeetingWebhookTransportResponse]
  private var sent: [Sent] = []
  private var inFlight: [String: Int] = [:]
  private var peak: [String: Int] = [:]
  private var totalInFlight = 0
  private var totalPeak = 0
  private let holdNanoseconds: UInt64
  private let gate: BackoffGate?

  init(
    clock: PacingTestClock? = nil,
    steps: [MeetingWebhookTransportResponse] = [],
    holdNanoseconds: UInt64 = 0,
    gate: BackoffGate? = nil
  ) {
    self.clock = clock
    self.steps = steps
    self.holdNanoseconds = holdNanoseconds
    self.gate = gate
  }

  var requests: [Sent] { lock.withLock { sent } }
  func peakInFlight(host: String) -> Int { lock.withLock { peak[host] ?? 0 } }
  var peakAcrossHosts: Int { lock.withLock { totalPeak } }

  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse {
    let host = request.url?.host ?? ""
    let body = request.httpBody
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let response: MeetingWebhookTransportResponse = lock.withLock {
      sent.append(Sent(host: host, time: clock?.now ?? Date(), body: body))
      inFlight[host, default: 0] += 1
      peak[host] = max(peak[host] ?? 0, inFlight[host] ?? 0)
      totalInFlight += 1
      totalPeak = max(totalPeak, totalInFlight)
      return steps.isEmpty ? MeetingWebhookTransportResponse(statusCode: 200) : steps.removeFirst()
    }
    if holdNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: holdNanoseconds)
    }
    if let gate {
      try? await gate.wait()
    }
    lock.withLock {
      inFlight[host, default: 1] -= 1
      totalInFlight -= 1
    }
    return response
  }
}

/// Pacing, the end-of-payload marker, part sizes and partial resends of split sends.
struct MeetingWebhookPacingTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
  private static let appInfo = MeetingWebhookAppInfo(
    name: "WonderWhisper",
    version: "2026-10-15",
    build: "2026101500"
  )

  // MARK: - Helpers

  private static func splitEndpoint(
    name: String = "Grok Bot",
    host: String = "example.com",
    partDelay: Int = 7,
    noteDelay: Int = 30
  ) -> MeetingWebhookEndpoint {
    MeetingWebhookEndpoint(
      name: name,
      url: "https://\(host)/hook",
      splitIntoParts: true,
      maxBodyCharacters: 3_800,
      partDelaySeconds: partDelay,
      noteDelaySeconds: noteDelay
    )
  }

  private static func jobs(
    _ count: Int,
    endpoint: MeetingWebhookEndpoint = splitEndpoint(),
    paced: Bool = true
  ) -> [MeetingWebhookDeliveryJob] {
    let sendID = UUID()
    return (1...count).map { index in
      MeetingWebhookDeliveryJob(
        deliveryID: UUID(),
        sendID: sendID,
        partIndex: index,
        partTotal: count,
        endpoint: endpoint,
        url: URL(string: endpoint.url) ?? URL(fileURLWithPath: "/"),
        event: .noteCompleted,
        noteID: UUID(),
        noteTitle: "Planning",
        body: Data("{\"part\":\(index)}".utf8),
        signingSecret: nil,
        customHeaders: [:],
        userAgent: appInfo.userAgent,
        pacing: paced ? endpoint.pacing : nil
      )
    }
  }

  private static func service(
    _ transport: MeetingWebhookTransport,
    clock: PacingTestClock
  ) -> MeetingWebhookDeliveryService {
    MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: { clock.sleep($0) },
      clock: { clock.now },
      jitter: { 0 }
    )
  }

  /// A realistic finished meeting whose exported note is about 25k characters: generated
  /// notes with headings, bullets, a quote and checkboxes, manual notes, and a transcript of
  /// short alternating lines with quotes.
  static func realisticSession(targetCharacters: Int = 25_000) -> MeetingSession {
    let micLines = [
      "Okay, so the rollout plan is next. Can we agree on owners today?",
      "I think the \"pricing page\" needs another pass before we ship.",
      "Let's keep the scope tight: checkout, receipts, and the member app.",
      "Who is talking to Ash about the padel schedule?",
      "Right, I'll take that one. Next item."
    ]
    let systemLines = [
      "Sure. We can ship after QA signs off on Thursday.",
      "The integration tests are flaky on the booking flow, about 3% of runs.",
      "Marketing wants a date; I said end of month, pending the API review.",
      "I've got a question about the migration: do we backfill old invoices?",
      "Agreed, let's park that and revisit next week."
    ]
    var notes = """
    ## Summary

    The team reviewed the Q4 rollout and agreed owners for checkout and receipts.

    ## Decisions

    - Ship checkout behind a flag on **Thursday** after QA sign-off.
    - "Keep the scope tight": no new member app screens this sprint.

    ## Action items

    - [ ] Dane: confirm the pricing page copy with marketing (due Wed).
    - [ ] QA: rerun the flaky booking tests and report the failure rate.

    > The booking flow tests fail about 3% of runs; if that holds we slip a day.

    """
    for topic in 1...6 {
      notes += "\n### Topic \(topic): booking and payments\n\n"
      notes += "- Discussed edge cases for refunds, partial payments and credits.\n"
      notes += "- Open question: \"what happens to credits after a plan change?\"\n"
    }
    var tokens: [MeetingTranscriptToken] = []
    var session = MeetingSession(
      title: "Glofox Q4 rollout planning",
      startedAt: fixedDate,
      endedAt: fixedDate.addingTimeInterval(6_720),
      recordedDuration: 2_001,
      detectedApp: "Google Meet",
      status: .completed,
      manualNotesMarkdown: "Remember the pricing page.",
      notesMarkdown: notes
    )
    var index = 0
    // Add lines in batches of four, measuring the document after each batch.
    while MeetingObsidianExporter.document(for: session).count < targetCharacters {
      for _ in 0..<4 {
        let source: MeetingAudioSource = index.isMultiple(of: 2) ? .microphone : .systemAudio
        let pool = source == .microphone ? micLines : systemLines
        let start = TimeInterval(index * 9)
        tokens.append(MeetingTranscriptToken(
          source: source,
          startTime: start,
          endTime: start + 4,
          text: pool[(index / 2) % pool.count]
        ))
        index += 1
      }
      session.transcriptTokens = tokens
    }
    return session
  }

  // MARK: - End-of-payload marker

  @Test func everySplitPartEndsWithTheMarkerAndReassemblesExactly() throws {
    let session = Self.realisticSession()
    let builder = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo)
    let parts = try builder.payloads(
      for: session,
      event: .noteCompleted,
      endpoint: Self.splitEndpoint(),
      sendID: UUID(),
      sentAt: Self.fixedDate
    )
    #expect(parts.count > 1)
    var chunks: [String] = []
    for (offset, part) in parts.enumerated() {
      let marker = "END-OF-PAYLOAD part \(offset + 1) of \(parts.count)"
      #expect(part.body.count <= 3_800)
      let lines = part.note.markdown.components(separatedBy: "\n")
      #expect(lines.last == marker)
      #expect(lines.dropLast().last == "")
      let json = try #require(JSONSerialization.jsonObject(with: part.body) as? [String: Any])
      let info = try #require(json["part"] as? [String: Any])
      #expect(info["endMarker"] as? String == marker)
      let body = String(decoding: part.body, as: UTF8.self)
      #expect(body.hasSuffix(marker + "\"}}"))
      // A receiver strips the trailing blank line and marker.
      let markdown = try #require((json["note"] as? [String: Any])?["markdown"] as? String)
      let suffix = "\n\n" + marker
      #expect(markdown.hasSuffix(suffix))
      chunks.append(String(markdown.utf8.dropLast(suffix.utf8.count)) ?? "")
    }
    #expect(chunks.joined() == MeetingObsidianExporter.document(for: session))
  }

  @Test func markerSurvivesACarriageReturnBeforeIt() throws {
    let markdown = String(repeating: "line\r", count: 600)
    let base = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payload(
      for: MeetingSession(title: "CR", status: .completed),
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.fixedDate
    )
    var payload = base
    payload.note.markdown = markdown
    let parts = try MeetingWebhookPayloadSplitter.parts(
      of: payload,
      sendID: UUID(),
      maxBytes: 1_200
    )
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.body.count <= 1_200 })
    #expect(parts.map(MeetingWebhookPayloadSplitter.chunk(of:)).joined() == markdown)
  }

  @Test func unsplitBodyHasNoMarkerAndKeepsNullFields() {
    var session = Self.realisticSession(targetCharacters: 2_000)
    session.detectedApp = nil
    session.endedAt = nil
    let payloads = try? MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payloads(
      for: session,
      event: .noteCompleted,
      endpoint: MeetingWebhookEndpoint(name: "Bot", url: "https://example.com/hook"),
      sendID: UUID(),
      sentAt: Self.fixedDate
    )
    let body = payloads?.first.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
    #expect(payloads?.count == 1)
    #expect(!body.contains("END-OF-PAYLOAD"))
    #expect(!body.contains("\"part\""))
    #expect(!body.contains("\"sendId\""))
    #expect(body.contains(
      #""durationSeconds":2001,"recordedSeconds":2001,"elapsedSeconds":null,"#
        + #""detectedApp":null,"markdown":"#
    ))
  }

  @Test func splitPartsOmitNullDetectedAppAndElapsed() throws {
    var session = Self.realisticSession(targetCharacters: 8_000)
    session.detectedApp = nil
    session.endedAt = nil
    let parts = try MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payloads(
      for: session,
      event: .noteCompleted,
      endpoint: Self.splitEndpoint(),
      sendID: UUID(),
      sentAt: Self.fixedDate
    )
    #expect(parts.count > 1)
    for part in parts {
      let body = String(decoding: part.body, as: UTF8.self)
      #expect(!body.contains("\"detectedApp\""))
      #expect(!body.contains("\"elapsedSeconds\""))
      #expect(body.contains(#""endedAt":null,"durationSeconds":2001,"recordedSeconds":2001,"#))
    }
  }

  // MARK: - Sizes

  @Test func realisticTwentyFiveKNoteFillsPartsCloseToTheMax() throws {
    let session = Self.realisticSession()
    let document = MeetingObsidianExporter.document(for: session)
    #expect(document.count >= 25_000 && document.count < 25_500)
    let parts = try MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payloads(
      for: session,
      event: .noteCompleted,
      endpoint: Self.splitEndpoint(),
      sendID: UUID(),
      sentAt: Self.fixedDate
    )
    let sizes = parts.map(\.body.count)
    let average = sizes.reduce(0, +) / max(1, sizes.count)
    #expect(sizes.allSatisfy { $0 <= 3_800 })
    // 9 parts averaging 3376 bytes before this change; the extra end marker and duration
    // fields cost about 120 bytes a part, fuller parts win it back.
    #expect(parts.count <= 9)
    #expect(average >= 3_450)
    #expect(sizes.dropLast().allSatisfy { $0 >= 3_600 })
  }

  @Test func aHeadingCutIsPreferredWhenThePartIsFullEnough() throws {
    // Filler, then a heading at about 90 percent of the budget: the cut lands before it.
    let base = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payload(
      for: MeetingSession(title: "Headings", status: .completed),
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.fixedDate
    )
    let split = try MeetingWebhookPayloadSplitter.split(
      of: base,
      sendID: UUID(),
      maxBytes: 3_800
    )
    let budget = split.chunkBudget
    let filler = String(repeating: "word ", count: Int(Double(budget) * 0.9) / 5) + "\n"
    var payload = base
    payload.note.markdown = filler + "## Next\n\n" + String(repeating: "more text. ", count: 400)
    let parts = try MeetingWebhookPayloadSplitter.split(
      of: payload,
      sendID: UUID(),
      maxBytes: 3_800
    )
    #expect(parts.chunks.first == filler)
    #expect(parts.chunks.dropFirst().first?.hasPrefix("## Next") == true)
  }

  // MARK: - Pacing (service)

  @Test func partsAreSpacedByThePartDelayAndTheNextNoteWaitsTheNoteGap() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock)
    let service = Self.service(transport, clock: clock)
    let endpoint = Self.splitEndpoint(partDelay: 7, noteDelay: 30)
    let first = await service.deliverParts(Self.jobs(3, endpoint: endpoint))
    let second = await service.deliverParts(Self.jobs(2, endpoint: endpoint))
    #expect((first + second).allSatisfy { $0.state == .delivered })
    #expect(clock.sleeps == [7, 7, 30, 7])
    let times = transport.requests.map { $0.time.timeIntervalSince(Self.fixedDate) }
    #expect(times == [0, 7, 14, 44, 51])
  }

  @Test func theNoteGapCountsTimeAlreadyPassed() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock)
    let service = Self.service(transport, clock: clock)
    let endpoint = Self.splitEndpoint(partDelay: 0, noteDelay: 30)
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    clock.advance(20)
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    #expect(clock.sleeps == [10])
  }

  @Test func queuedRecordsAnnounceTheNextPartWhileWaiting() async throws {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock)
    let service = Self.service(transport, clock: clock)
    let updates = RecordCollector()
    _ = await service.deliverParts(Self.jobs(3)) { updates.append($0) }
    let waiting = updates.values.filter { $0.state == .queued }
    #expect(waiting.map(\.partIndex) == [2, 3])
    let first = try #require(waiting.first)
    #expect(first.nextAttemptAt == Self.fixedDate.addingTimeInterval(7))
    #expect(MeetingWebhookStatusFormatter.text(for: first, now: Self.fixedDate)
      == "Sending Grok Bot part 2 of 3 (next in 7s)")
  }

  @Test func rateLimitsHonourRetryAfterAndHoldLaterParts() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock, steps: [
      MeetingWebhookTransportResponse(statusCode: 200),
      MeetingWebhookTransportResponse(statusCode: 429, retryAfter: "12"),
      MeetingWebhookTransportResponse(statusCode: 200)
    ])
    let records = await Self.service(transport, clock: clock).deliverParts(Self.jobs(3))
    #expect(records.map(\.state) == [.delivered, .delivered, .delivered])
    #expect(clock.sleeps == [7, 12, 7])
    let order = transport.requests.compactMap { $0.body["part"] as? Int }
    #expect(order == [1, 2, 2, 3])
  }

  @Test func rateLimitsWithoutRetryAfterBackOffThirtySecondsThenDouble() async {
    let clock = PacingTestClock(Self.fixedDate)
    let limited = MeetingWebhookTransportResponse(statusCode: 429)
    let unavailable = MeetingWebhookTransportResponse(statusCode: 503)
    let transport = PacingTestTransport(
      clock: clock,
      steps: [limited, unavailable, limited, limited, limited]
    )
    let records = await Self.service(transport, clock: clock).deliverParts(Self.jobs(2))
    #expect(records.map(\.state) == [.failed, .failed])
    #expect(records[0].attempts == 5)
    #expect(records[1].isSkipped)
    #expect(clock.sleeps == [30, 60, 120, 240])
    #expect(transport.requests.count == 5)
  }

  @Test func anExhaustedRateLimitWithRetryAfterHoldsTheNextNote() async throws {
    let clock = PacingTestClock(Self.fixedDate)
    let limited = MeetingWebhookTransportResponse(statusCode: 429, retryAfter: "600")
    let transport = PacingTestTransport(
      clock: clock,
      steps: Array(repeating: limited, count: 5)
    )
    let service = Self.service(transport, clock: clock)
    let endpoint = Self.splitEndpoint(partDelay: 7, noteDelay: 30)
    let first = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    #expect(first.map(\.state) == [.failed])
    #expect(clock.sleeps == [600, 600, 600, 600])
    let updates = RecordCollector()
    let second = await service.deliverParts(Self.jobs(1, endpoint: endpoint)) {
      updates.append($0)
    }
    #expect(second.map(\.state) == [.delivered])
    // The fifth 429 came at +2400s; the next note waits its 600s, not the 30s note gap.
    #expect(clock.sleeps == [600, 600, 600, 600, 600])
    #expect(transport.requests.last?.time == Self.fixedDate.addingTimeInterval(3_000))
    let waiting = try #require(updates.values.first { $0.state == .queued })
    #expect(waiting.isRateLimitWait == true)
    #expect(MeetingWebhookStatusFormatter.text(
      for: waiting,
      now: Self.fixedDate.addingTimeInterval(2_400)
    ) == "Waiting for Grok Bot rate limit (10m)")
    #expect(MeetingWebhookStatusFormatter.text(
      for: waiting,
      now: Self.fixedDate.addingTimeInterval(2_955)
    ) == "Waiting for Grok Bot rate limit (45s)")
  }

  @Test func anExhaustedRateLimitWithoutRetryAfterHoldsTheNextNoteForTheNextBackoff() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(
      clock: clock,
      steps: Array(repeating: MeetingWebhookTransportResponse(statusCode: 503), count: 5)
    )
    let service = Self.service(transport, clock: clock)
    let endpoint = Self.splitEndpoint(partDelay: 7, noteDelay: 30)
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    #expect(clock.sleeps == [30, 60, 120, 240, 240])
    #expect(transport.requests.count == 6)
  }

  @Test func aCancelledRateLimitedSendStillHoldsTheNextNote() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock, steps: [
      MeetingWebhookTransportResponse(statusCode: 429, retryAfter: "120")
    ])
    let service = MeetingWebhookDeliveryService(
      transport: transport,
      // The backoff wait is cancelled at once, as when the endpoint is edited.
      sleeper: { seconds in
        if seconds == 120 { throw CancellationError() }
        clock.sleep(seconds)
      },
      clock: { clock.now },
      jitter: { 0 }
    )
    let endpoint = Self.splitEndpoint(partDelay: 7, noteDelay: 30)
    let first = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    #expect(first.first?.lastError == MeetingWebhookDeliveryService.cancelledMessage)
    clock.advance(50)
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint))
    #expect(clock.sleeps == [70])
  }

  @Test func unsplitSendsKeepTheOriginalBackoffAndNoPacing() async {
    let clock = PacingTestClock(Self.fixedDate)
    let transport = PacingTestTransport(clock: clock, steps: [
      MeetingWebhookTransportResponse(statusCode: 429),
      MeetingWebhookTransportResponse(statusCode: 200)
    ])
    let endpoint = MeetingWebhookEndpoint(name: "Bot", url: "https://example.com/hook")
    #expect(endpoint.pacing == nil)
    let service = Self.service(transport, clock: clock)
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint, paced: false))
    _ = await service.deliverParts(Self.jobs(1, endpoint: endpoint, paced: false))
    #expect(clock.sleeps == [2])
  }

  // MARK: - Pacing (center)

  /// Each center gets its own in-memory endpoint list, so tests running in parallel never
  /// see each other's endpoints (and nothing touches a real preferences file).
  @MainActor
  private static func center(
    transport: MeetingWebhookTransport,
    sleeper: @escaping MeetingWebhookDeliveryService.Sleeper = { _ in }
  ) throws -> (MeetingWebhookCenter, MeetingWebhookEndpointStore) {
    let defaults = try #require(InMemoryUserDefaults(isolated: ()))
    let store = MeetingWebhookEndpointStore(
      defaults: { defaults },
      secrets: MeetingWebhookInMemorySecretStore()
    )
    let center = MeetingWebhookCenter(
      store: store,
      deliveryService: MeetingWebhookDeliveryService(
        transport: transport,
        sleeper: sleeper,
        jitter: { 0 }
      ),
      log: MeetingWebhookDeliveryLog(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("ww-pacing-\(UUID().uuidString).json")
      ),
      payloadBuilder: MeetingWebhookPayloadBuilder(appInfo: appInfo)
    )
    return (center, store)
  }

  @MainActor
  private static func withScratchEndpoints(
    _ body: @MainActor () async throws -> Void
  ) async rethrows {
    try await body()
  }

  @MainActor
  private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  private static func longSession(_ title: String = "Planning") -> MeetingSession {
    let session = realisticSession(targetCharacters: 9_000)
    return MeetingSession(
      title: title,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      recordedDuration: session.recordedDuration,
      status: .completed,
      transcriptTokens: session.transcriptTokens,
      notesMarkdown: session.notesMarkdown
    )
  }

  @MainActor
  @Test func sendsToOneSplitEndpointQueueOneAtATimeInOrder() async throws {
    try await Self.withScratchEndpoints {
      let transport = PacingTestTransport(holdNanoseconds: 2_000_000)
      let (center, store) = try Self.center(transport: transport)
      let endpoint = Self.splitEndpoint()
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      let first = Self.longSession("First")
      let second = Self.longSession("Second")

      #expect(center.send(first, event: .noteCompleted) == 1)
      #expect(center.send(second, event: .noteCompleted) == 1)
      let queued = try #require(center.latestRecords(forNote: second.id).first)
      #expect(queued.state == .queued)
      #expect(queued.queuedBehind == 1)
      #expect(MeetingWebhookStatusFormatter.text(for: queued)
        == "Queued for Grok Bot (behind 1 note)")

      let done = await Self.waitUntil {
        !center.deliveries.isEmpty && center.deliveries.allSatisfy { $0.state == .delivered }
      }
      #expect(done)
      #expect(transport.peakInFlight(host: "example.com") == 1)
      let titles = transport.requests.compactMap {
        ($0.body["note"] as? [String: Any])?["title"] as? String
      }
      let firstCount = titles.filter { $0 == "First" }.count
      #expect(firstCount > 1)
      #expect(titles == Array(repeating: "First", count: firstCount)
        + Array(repeating: "Second", count: titles.count - firstCount))
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func testSendsWaitTheirTurnBehindANote() async throws {
    try await Self.withScratchEndpoints {
      let gate = BackoffGate()
      let transport = PacingTestTransport()
      let (center, store) = try Self.center(
        transport: transport,
        sleeper: { _ in try await gate.wait() }
      )
      let endpoint = Self.splitEndpoint()
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      #expect(center.send(Self.longSession(), event: .noteCompleted) == 1)
      center.sendTest(to: endpoint.id)
      let test = try #require(center.latestRecord(forEndpoint: endpoint.id))
      #expect(test.event == .test)
      #expect(test.state == .queued)
      #expect(MeetingWebhookStatusFormatter.text(for: test)
        == "Queued for Grok Bot (behind 1 note)")
      let firstPartSent = await Self.waitUntil { transport.requests.count == 1 }
      #expect(firstPartSent)
      // The note is waiting out its part delay, so the test is still queued.
      try? await Task.sleep(nanoseconds: 20_000_000)
      #expect(transport.requests.count == 1)
      gate.open()
      let done = await Self.waitUntil {
        center.deliveries.allSatisfy { $0.state == .delivered }
      }
      #expect(done)
      #expect(transport.requests.last?.body["event"] as? String == "webhook.test")
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func differentEndpointsSendInParallel() async throws {
    try await Self.withScratchEndpoints {
      let transport = PacingTestTransport(holdNanoseconds: 20_000_000)
      let (center, store) = try Self.center(transport: transport)
      let first = Self.splitEndpoint(name: "A", host: "a.example.com")
      let second = Self.splitEndpoint(name: "B", host: "b.example.com")
      try store.upsert(first, signingSecret: nil, headers: [:])
      try store.upsert(second, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      #expect(center.send(Self.longSession(), event: .noteCompleted) == 2)
      let done = await Self.waitUntil {
        !center.deliveries.isEmpty && center.deliveries.allSatisfy { $0.state == .delivered }
      }
      #expect(done)
      #expect(transport.peakInFlight(host: "a.example.com") == 1)
      #expect(transport.peakInFlight(host: "b.example.com") == 1)
      #expect(transport.peakAcrossHosts == 2)
      center.deleteEndpoint(first.id)
      center.deleteEndpoint(second.id)
    }
  }

  @MainActor
  @Test func turningSplittingOnWhileAnUnsplitPostIsInFlightNeverOverlaps() async throws {
    let gate = BackoffGate()
    let transport = PacingTestTransport(gate: gate)
    let (center, store) = try Self.center(transport: transport)
    var endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
    try store.upsert(endpoint, signingSecret: nil, headers: [:])
    center.reloadEndpoints()
    #expect(center.send(Self.longSession("Unsplit"), event: .noteCompleted) == 1)
    let unsplitOnTheWire = await Self.waitUntil { transport.requests.count == 1 }
    #expect(unsplitOnTheWire)

    endpoint.splitIntoParts = true
    #expect(center.saveEndpoint(endpoint, signingSecret: nil, headers: nil) == nil)
    let split = Self.longSession("Split")
    #expect(center.send(split, event: .noteCompleted) == 1)
    let waiting = try #require(center.latestRecords(forNote: split.id).first)
    #expect(waiting.state == .queued)
    #expect(MeetingWebhookStatusFormatter.text(for: waiting)
      == "Queued for Grok Bot (behind 1 note)")
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(transport.requests.count == 1)

    gate.open()
    let done = await Self.waitUntil {
      center.deliveries.allSatisfy { $0.state == .delivered }
    }
    #expect(done)
    #expect(transport.peakInFlight(host: "example.com") == 1)
    let titles = transport.requests.compactMap {
      ($0.body["note"] as? [String: Any])?["title"] as? String
    }
    #expect(titles.first == "Unsplit" && titles.dropFirst().allSatisfy { $0 == "Split" })
    #expect(titles.count > 2)
    center.deleteEndpoint(endpoint.id)
  }

  @MainActor
  @Test func unsplitSendsStillRunAlongsideEachOther() async throws {
    let transport = PacingTestTransport(holdNanoseconds: 30_000_000)
    let (center, store) = try Self.center(transport: transport)
    let endpoint = MeetingWebhookEndpoint(name: "Bot", url: "https://example.com/hook")
    try store.upsert(endpoint, signingSecret: nil, headers: [:])
    center.reloadEndpoints()
    #expect(center.send(Self.longSession("One"), event: .noteCompleted) == 1)
    #expect(center.send(Self.longSession("Two"), event: .noteCompleted) == 1)
    #expect(center.deliveries.allSatisfy { $0.state != .queued })
    let done = await Self.waitUntil {
      center.deliveries.count == 2 && center.deliveries.allSatisfy { $0.state == .delivered }
    }
    #expect(done)
    #expect(transport.peakInFlight(host: "example.com") == 2)
    center.deleteEndpoint(endpoint.id)
  }

  @MainActor
  @Test func cancellingAnEndpointClearsItsQueue() async throws {
    try await Self.withScratchEndpoints {
      let transport = PacingTestTransport()
      let (center, store) = try Self.center(
        transport: transport,
        // Real, cancellation-aware wait: only cancellation ends the part delay.
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let endpoint = Self.splitEndpoint()
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      #expect(center.send(Self.longSession("First"), event: .noteCompleted) == 1)
      #expect(center.send(Self.longSession("Second"), event: .noteCompleted) == 1)
      let firstSent = await Self.waitUntil { transport.requests.count == 1 }
      #expect(firstSent)

      center.setEnabled(false, for: endpoint.id)
      let ended = await Self.waitUntil {
        center.deliveries.allSatisfy { !$0.state.isInFlight }
      }
      #expect(ended)
      #expect(transport.requests.count == 1)
      let unsent = center.deliveries.filter { $0.state == .failed }
      #expect(!unsent.isEmpty)
      #expect(unsent.allSatisfy { $0.lastError == MeetingWebhookCenter.disabledReason })
      #expect(Set(unsent.map(\.noteTitle)) == ["First", "Second"])
      center.deleteEndpoint(endpoint.id)
    }
  }

  // MARK: - Partial resend

  @MainActor
  @Test func resendMissingPartsSendsOnlyThoseWithTheSameSendIDAndTotal() async throws {
    try await Self.withScratchEndpoints {
      // Part 2 is refused for good; parts after it are skipped.
      let transport = PacingTestTransport(steps: [
        MeetingWebhookTransportResponse(statusCode: 200),
        MeetingWebhookTransportResponse(statusCode: 400)
      ])
      let (center, store) = try Self.center(transport: transport)
      let endpoint = Self.splitEndpoint()
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      let session = Self.longSession()

      #expect(center.send(session, event: .noteCompleted) == 1)
      let failed = await Self.waitUntil {
        !center.deliveries.isEmpty && center.deliveries.allSatisfy { !$0.state.isInFlight }
      }
      #expect(failed)
      let original = transport.requests.map(\.body)
      let total = try #require((original.first?["part"] as? [String: Any])?["total"] as? Int)
      #expect(total >= 3)
      #expect(original.count == 2)
      let sendID = try #require(original.first?["sendId"] as? String)
      let status = try #require(center.latestRecords(forNote: session.id).first)
      #expect(status.supportsPartialResend)
      #expect(center.resumableSend(noteID: session.id, endpointID: endpoint.id)?.missingIndexes
        == Array(2...total))

      let outcome = center.resendParts(session, endpointID: endpoint.id, selection: .missing)
      #expect(outcome == .started(parts: Array(2...total)))
      let resent = await Self.waitUntil {
        transport.requests.count == 2 + (total - 1)
          && center.deliveries.allSatisfy { !$0.state.isInFlight }
      }
      #expect(resent)
      let bodies = transport.requests.dropFirst(2).map(\.body)
      #expect(bodies.compactMap { ($0["part"] as? [String: Any])?["index"] as? Int }
        == Array(2...total))
      #expect(bodies.allSatisfy {
        $0["sendId"] as? String == sendID
          && ($0["part"] as? [String: Any])?["total"] as? Int == total
          && $0["event"] as? String == "meeting.note.resent"
      })
      let originalIDs = Set(original.compactMap { $0["deliveryId"] as? String })
      let newIDs = Set(bodies.compactMap { $0["deliveryId"] as? String })
      #expect(newIDs.count == total - 1 && newIDs.isDisjoint(with: originalIDs))
      // The resent part 2 carries the same chunk the original part 2 did.
      let originalChunk = (original[1]["note"] as? [String: Any])?["markdown"] as? String
      let resentChunk = (bodies.first?["note"] as? [String: Any])?["markdown"] as? String
      #expect(originalChunk != nil && originalChunk == resentChunk)

      let summary = try #require(center.latestRecords(forNote: session.id).first)
      #expect(summary.state == .delivered)
      #expect(MeetingWebhookStatusFormatter.text(for: summary)
        .hasPrefix("Sent to Grok Bot (\(total) parts)"))
      #expect(center.resumableSend(noteID: session.id, endpointID: endpoint.id)?
        .missingIndexes == [])
      #expect(center.resendParts(session, endpointID: endpoint.id, selection: .missing)
        != .started(parts: []))

      // "Resend Parts...": part 1 again even though it was delivered.
      #expect(center.resendParts(session, endpointID: endpoint.id, selection: .parts([1]))
        == .started(parts: [1]))
      let again = await Self.waitUntil { transport.requests.count == 2 + total }
      #expect(again)
      let last = try #require(transport.requests.last?.body)
      #expect(last["sendId"] as? String == sendID)
      #expect((last["part"] as? [String: Any])?["index"] as? Int == 1)
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func partialResendIsRefusedWhenTheNoteOrSettingsChanged() async throws {
    try await Self.withScratchEndpoints {
      let transport = PacingTestTransport(steps: [
        MeetingWebhookTransportResponse(statusCode: 200),
        MeetingWebhookTransportResponse(statusCode: 400)
      ])
      let (center, store) = try Self.center(transport: transport)
      var endpoint = Self.splitEndpoint()
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      let session = Self.longSession()
      #expect(center.send(session, event: .noteCompleted) == 1)
      let finished = await Self.waitUntil {
        !center.deliveries.isEmpty && center.deliveries.allSatisfy { !$0.state.isInFlight }
      }
      #expect(finished)
      let sentCount = transport.requests.count

      var edited = session
      edited.notesMarkdown = (session.notesMarkdown ?? "") + "\n- One more decision."
      #expect(center.resendParts(edited, endpointID: endpoint.id, selection: .missing)
        == .refused(MeetingWebhookPayloadSplitter.ResendError.noteChanged.message))
      var renamed = session
      renamed.attendees = ["Ash"]
      #expect(center.resendParts(renamed, endpointID: endpoint.id, selection: .missing)
        == .refused(MeetingWebhookPayloadSplitter.ResendError.noteChanged.message))
      #expect(center.resendParts(session, endpointID: endpoint.id, selection: .parts([99]))
        != .started(parts: [99]))

      endpoint.maxBodyCharacters = 5_000
      #expect(center.saveEndpoint(endpoint, signingSecret: nil, headers: nil) == nil)
      if case .refused(let message) = center.resendParts(
        session,
        endpointID: endpoint.id,
        selection: .missing
      ) {
        #expect(message.contains("settings changed"))
      } else {
        Issue.record("A changed max body size must refuse a partial resend")
      }
      try? await Task.sleep(nanoseconds: 30_000_000)
      #expect(transport.requests.count == sentCount)
      center.deleteEndpoint(endpoint.id)
    }
  }

  @Test func partListParsing() {
    #expect(MeetingWebhookPartList.parse("3", total: 3) == [3])
    #expect(MeetingWebhookPartList.parse("2,3", total: 3) == [2, 3])
    #expect(MeetingWebhookPartList.parse(" 3, 2 2 ", total: 3) == [2, 3])
    #expect(MeetingWebhookPartList.parse("2-4", total: 5) == [2, 3, 4])
    #expect(MeetingWebhookPartList.parse("4", total: 3) == nil)
    #expect(MeetingWebhookPartList.parse("0", total: 3) == nil)
    #expect(MeetingWebhookPartList.parse("a", total: 3) == nil)
    #expect(MeetingWebhookPartList.parse("", total: 3) == nil)
    #expect(MeetingWebhookPartList.parse("3-2", total: 3) == nil)
  }

  // MARK: - Decoding older data

  @Test func oldEndpointJSONDecodesWithPacingDefaults() throws {
    let json = #"{"id":"\#(UUID().uuidString)","name":"Grok Bot","#
      + #""url":"https://example.com/hook","isEnabled":true,"headerNames":[],"#
      + #""hasSecret":false,"splitIntoParts":true,"maxBodyCharacters":3800}"#
    let endpoint = try JSONDecoder().decode(MeetingWebhookEndpoint.self, from: Data(json.utf8))
    #expect(endpoint.partDelaySeconds == 7)
    #expect(endpoint.noteDelaySeconds == 30)
    #expect(endpoint.pacing == MeetingWebhookPacing(partDelay: 7, noteDelay: 30))
    let clamped = MeetingWebhookEndpoint(partDelaySeconds: 500, noteDelaySeconds: -4)
    #expect(clamped.partDelaySeconds == 60 && clamped.noteDelaySeconds == 0)
    var edited = endpoint
    edited.partDelaySeconds = 5
    edited.noteDelaySeconds = 120
    let decoded = try JSONDecoder().decode(
      MeetingWebhookEndpoint.self,
      from: JSONEncoder().encode(edited)
    )
    #expect(decoded == edited)
  }

  @Test func oldDeliveryRecordsDecodeWithoutPacingOrSplitDetails() throws {
    let json = #"{"id":"\#(UUID().uuidString)","endpointID":"\#(UUID().uuidString)","#
      + #""endpointName":"Grok Bot","noteID":"\#(UUID().uuidString)","noteTitle":"Planning","#
      + #""event":"meeting.note.completed","state":"failed","attempts":1,"#
      + #""maximumAttempts":5,"createdAt":"2025-10-09T08:53:20Z","#
      + #""updatedAt":"2025-10-09T08:53:20Z","sendID":"\#(UUID().uuidString)","#
      + #""partIndex":2,"partTotal":3}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(MeetingWebhookDeliveryRecord.self, from: Data(json.utf8))
    #expect(record.queuedBehind == nil && record.nextAttemptAt == nil)
    #expect(record.contentFingerprint == nil && record.chunkBudget == nil)
    #expect(!record.supportsPartialResend)
    let interrupted = MeetingWebhookDeliveryLog.markingInterrupted(
      [MeetingWebhookDeliveryRecord(
        job: Self.jobs(1)[0],
        state: .queued,
        maximumAttempts: 5,
        at: Self.fixedDate
      )],
      now: Self.fixedDate
    )
    #expect(interrupted.first?.state == .failed)
  }
}

/// Collects every record reported through `onUpdate`.
final class RecordCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var collected: [MeetingWebhookDeliveryRecord] = []

  var values: [MeetingWebhookDeliveryRecord] {
    lock.withLock { collected }
  }

  func append(_ record: MeetingWebhookDeliveryRecord) {
    lock.withLock { collected.append(record) }
  }
}

/// Process-local defaults for the endpoint store: only the calls the store makes.
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]

  init?(isolated: Void) {
    super.init(suiteName: nil)
  }

  override func object(forKey defaultName: String) -> Any? {
    lock.withLock { values[defaultName] }
  }

  override func data(forKey defaultName: String) -> Data? {
    object(forKey: defaultName) as? Data
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    lock.withLock { values[defaultName] = value }
  }

  override func removeObject(forKey defaultName: String) {
    lock.withLock { values[defaultName] = nil }
  }
}
