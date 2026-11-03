import Foundation
import Testing
@testable import WonderWhisper

/// MausBot automations: delivery headers, reserved custom headers, address recognition and the
/// editor's secret move, receiver replies, the 48,000-character guard and `part.sha256`.
/// Addresses and secrets here are made up.
@Suite(.serialized)
struct MeetingWebhookMausBotTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
  private static let appInfo = MeetingWebhookAppInfo(
    name: "WonderWhisper",
    version: "2026-10-12.1",
    build: "2026101201"
  )
  private static let builder = MeetingWebhookPayloadBuilder(appInfo: appInfo)
  /// `whsec_` plus 43 base64url characters, like a real MausBot secret.
  private static let secret = "whsec_" + String(repeating: "Ab3-_", count: 8) + "xyz"
  private static let hookBase = "http://127.0.0.1:8800/hooks/wh_AbC123xYz"
  private static var fullAddress: String { hookBase + "/" + secret }

  private static func session(
    markdown: String = "## Summary\n\n- Planned the sprint.",
    attendees: [String] = []
  ) -> MeetingSession {
    MeetingSession(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
      title: "Planning",
      startedAt: fixedDate,
      endedAt: fixedDate.addingTimeInterval(2_712),
      recordedDuration: 2_712,
      detectedApp: nil,
      status: .completed,
      notesMarkdown: markdown,
      attendees: attendees
    )
  }

  private static func service(
    _ transport: MeetingWebhookTransport,
    sleeper: RecordingSleeper = RecordingSleeper()
  ) -> MeetingWebhookDeliveryService {
    MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: { sleeper.sleep($0) },
      clock: { fixedDate },
      jitter: { 0 }
    )
  }

  private static func jobs(
    for session: MeetingSession,
    event: MeetingWebhookEvent,
    endpoint: MeetingWebhookEndpoint
  ) throws -> [MeetingWebhookDeliveryJob] {
    let sendID = UUID()
    let plan = try builder.plan(
      for: session,
      event: event,
      endpoint: endpoint,
      sendID: sendID,
      sentAt: fixedDate
    )
    return plan.payloads.map { payload in
      MeetingWebhookDeliveryJob(
        deliveryID: payload.deliveryId,
        sendID: sendID,
        partIndex: payload.part?.index ?? 1,
        partTotal: payload.part?.total ?? 1,
        endpoint: endpoint,
        url: URL(string: endpoint.url) ?? URL(fileURLWithPath: "/"),
        event: event,
        noteID: session.id,
        noteTitle: session.title,
        body: payload.body,
        signingSecret: "topsecret",
        customHeaders: [:],
        userAgent: appInfo.userAgent,
        splitInfo: plan.split
      )
    }
  }

  private static func bodyDeliveryID(_ request: URLRequest) -> String? {
    let json = request.httpBody.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    return json?["deliveryId"] as? String
  }

  // MARK: - 1. Headers

  @Test(arguments: [MeetingWebhookEvent.noteCompleted, .noteResent, .test], [false, true])
  func everyRequestCarriesOneDeliveryIDAndTheEvent(
    event: MeetingWebhookEvent,
    split: Bool
  ) async throws {
    let endpoint = MeetingWebhookEndpoint(
      name: "Notes Bot",
      url: "https://example.com/hook",
      splitIntoParts: split,
      maxBodyCharacters: 1_500
    )
    let markdown = (0..<20).map { "## Topic \($0)\n\nSome detail here." }
      .joined(separator: "\n\n")
    let jobs = try Self.jobs(for: Self.session(markdown: markdown), event: event,
                             endpoint: endpoint)
    #expect(split ? jobs.count > 1 : jobs.count == 1)
    let transport = FakeMeetingWebhookTransport([])
    _ = await Self.service(transport).deliverParts(jobs)
    #expect(transport.requests.count == jobs.count)
    for request in transport.requests {
      let deliveryID = try #require(Self.bodyDeliveryID(request))
      #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == deliveryID)
      #expect(request.value(forHTTPHeaderField: "X-WonderWhisper-Delivery") == deliveryID)
      #expect(request.value(forHTTPHeaderField: "X-Webhook-Event") == event.rawValue)
      #expect(request.value(forHTTPHeaderField: "X-WonderWhisper-Event") == event.rawValue)
      #expect(request.value(forHTTPHeaderField: "X-WonderWhisper-Signature") != nil)
    }
  }

  @Test func retriesRepeatTheSameDeliveryID() async throws {
    let endpoint = MeetingWebhookEndpoint(name: "Notes Bot", url: "https://example.com/hook")
    let jobs = try Self.jobs(for: Self.session(), event: .noteCompleted, endpoint: endpoint)
    let transport = FakeMeetingWebhookTransport([
      .status(503), .failure(URLError(.timedOut)), .status(200)
    ])
    let record = await Self.service(transport).deliver(try #require(jobs.first))
    #expect(record.state == .delivered && record.attempts == 3)
    let keys = transport.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
    let deliveries = transport.requests.map {
      $0.value(forHTTPHeaderField: "X-WonderWhisper-Delivery")
    }
    #expect(Set(keys).count == 1)
    #expect(keys == deliveries)
    #expect(keys.first == Self.bodyDeliveryID(try #require(transport.requests.first)))
  }

  // MARK: - 2. Reserved custom headers

  @Test func reservedHeadersAreRefusedInAnyCase() {
    let always = ["Content-Type", "idempotency-key", "IDEMPOTENCY-KEY", "x-webhook-event",
                  "X-Webhook-Event", "X-WonderWhisper-Anything", " x-wonderwhisper-delivery "]
    for name in always {
      #expect(MeetingWebhookRequestBuilder.isReservedHeader(name), "\(name)")
      #expect(MeetingWebhookRequestBuilder.isReservedHeader(name, forMausBot: true), "\(name)")
    }
    let mausBotOnly = ["X-GitHub-Event", "x-github-event", "X-Event-Type", "ce-type",
                       "CE-Type", "X-Webhook-Id", "webhook-id", "Webhook-ID"]
    for name in mausBotOnly {
      #expect(!MeetingWebhookRequestBuilder.isReservedHeader(name), "\(name)")
      #expect(MeetingWebhookRequestBuilder.isReservedHeader(name, forMausBot: true), "\(name)")
    }
    #expect(!MeetingWebhookRequestBuilder.isReservedHeader("Authorization", forMausBot: true))
    #expect(!MeetingWebhookRequestBuilder.isReservedHeader("X-GitHub-Delivery"))
  }

  @Test func savedHeadersThatAreNowReservedAreNotSent() {
    let custom = ["Idempotency-Key": "mine", "x-webhook-event": "mine", "X-GitHub-Event": "push",
                  "CE-Type": "x", "Authorization": "Bearer t"]
    let other = MeetingWebhookRequestBuilder.headers(
      event: .noteCompleted, deliveryID: UUID(), timestamp: 1, body: Data(),
      signingSecret: nil, userAgent: "UA", customHeaders: custom
    )
    #expect(other["Idempotency-Key"] != "mine")
    #expect(other["X-Webhook-Event"] == "meeting.note.completed")
    #expect(other["x-webhook-event"] == nil)
    // Other addresses keep sending what they sent before.
    #expect(other["X-GitHub-Event"] == "push")
    #expect(other["CE-Type"] == "x")
    let mausBot = MeetingWebhookRequestBuilder.headers(
      event: .noteCompleted, deliveryID: UUID(), timestamp: 1, body: Data(),
      signingSecret: nil, userAgent: "UA", customHeaders: custom, forMausBot: true
    )
    #expect(mausBot["X-GitHub-Event"] == nil)
    #expect(mausBot["CE-Type"] == nil)
    #expect(mausBot["Authorization"] == "Bearer t")

    var job = MeetingWebhookDeliveryJob(
      deliveryID: UUID(),
      endpoint: MeetingWebhookEndpoint(url: Self.hookBase),
      url: URL(string: Self.hookBase) ?? URL(fileURLWithPath: "/"),
      event: .test, noteID: UUID(), noteTitle: "t", body: Data(), signingSecret: nil,
      customHeaders: custom, userAgent: "UA"
    )
    let request = MeetingWebhookRequestBuilder.request(for: job, at: Self.fixedDate)
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Event") == nil)
    job = MeetingWebhookDeliveryJob(
      deliveryID: UUID(),
      endpoint: MeetingWebhookEndpoint(url: "https://example.com/hook"),
      url: URL(string: "https://example.com/hook") ?? URL(fileURLWithPath: "/"),
      event: .test, noteID: UUID(), noteTitle: "t", body: Data(), signingSecret: nil,
      customHeaders: custom, userAgent: "UA"
    )
    let otherRequest = MeetingWebhookRequestBuilder.request(for: job, at: Self.fixedDate)
    #expect(otherRequest.value(forHTTPHeaderField: "X-GitHub-Event") == "push")
  }

  @Test func reservedHeaderMessagesNameTheReason() {
    #expect(MeetingWebhookCenter.reservedHeaderMessage("Authorization", forMausBot: true) == nil)
    #expect(MeetingWebhookCenter.reservedHeaderMessage("idempotency-key", forMausBot: false)
      == "idempotency-key is set by WonderWhisper and can't be overridden.")
    #expect(MeetingWebhookCenter.reservedHeaderMessage("X-Event-Type", forMausBot: false) == nil)
    #expect(MeetingWebhookCenter.reservedHeaderMessage("X-Event-Type", forMausBot: true)
      == "X-Event-Type can't be added for a MausBot address.")
  }

  // MARK: - 3. Address recognition

  @Test func aCompleteAddressIsRecognisedAndItsSecretExtracted() throws {
    let extracted = try #require(MeetingWebhookMausBotAddress.extract(from: Self.fullAddress))
    #expect(extracted.url == Self.hookBase)
    #expect(extracted.secret == Self.secret)
    #expect(extracted.authorizationValue == "Bearer \(Self.secret)")
    // Surrounding whitespace from a paste is fine; https and private hosts too.
    #expect(MeetingWebhookMausBotAddress.extract(from: "  \(Self.fullAddress)\n")?.secret
      == Self.secret)
    let https = "https://bots.example.com/hooks/wh_Q-r_9/" + Self.secret
    #expect(MeetingWebhookMausBotAddress.extract(from: https)?.url
      == "https://bots.example.com/hooks/wh_Q-r_9")
    #expect(MeetingWebhookMausBotAddress.matches(Self.hookBase))
    #expect(MeetingWebhookMausBotAddress.matches(Self.fullAddress))
  }

  @Test func theSecretIsPercentDecodedExactlyOnce() throws {
    let encoded = Self.secret.replacingOccurrences(of: "_", with: "%5F")
    let once = try #require(MeetingWebhookMausBotAddress.extract(from: Self.hookBase + "/"
      + encoded))
    #expect(once.secret == Self.secret)
    let twice = Self.secret.replacingOccurrences(of: "_", with: "%255F")
    #expect(MeetingWebhookMausBotAddress.extract(from: Self.hookBase + "/" + twice) == nil)
  }

  @Test func incompleteOrOtherAddressesAreNotRecognised() {
    let partial = Self.hookBase + "/" + String(Self.secret.dropLast())
    let cases = [
      partial,
      Self.hookBase + "/whsec_",
      Self.hookBase + "/" + Self.secret + "x",
      Self.hookBase + "/" + Self.secret + "?a=1",
      Self.hookBase + "/" + Self.secret + "#f",
      Self.hookBase + "/" + Self.secret + "/",
      "http://127.0.0.1:8800/hooks/xx_AbC/" + Self.secret,
      "http://127.0.0.1:8800/api/hooks/wh_AbC/" + Self.secret,
      "http://example.com/hooks/wh_AbC/" + Self.secret,
      "ftp://127.0.0.1/hooks/wh_AbC/" + Self.secret,
      "https://example.com/hook",
      Self.hookBase
    ]
    for url in cases {
      #expect(MeetingWebhookMausBotAddress.extract(from: url) == nil, "\(url)")
    }
    #expect(!MeetingWebhookMausBotAddress.matches("https://example.com/hook"))
    #expect(!MeetingWebhookMausBotAddress.matches("http://example.com/hooks/wh_AbC"))
    #expect(!MeetingWebhookMausBotAddress.matches(Self.hookBase + "/"))
  }

  // MARK: - 3/4. Editor draft

  @Test func pastingIntoANewWebhookMovesTheSecretAndAppliesDefaults() {
    var draft = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    #expect(draft.endpoint.url == Self.hookBase)
    #expect(draft.headers.map(\.name) == ["Authorization"])
    #expect(draft.headers.first?.value == "Bearer \(Self.secret)")
    #expect(draft.showsMausBotBadge && draft.showsMausBotDefaults)
    #expect(draft.endpoint.content == .full)
    #expect(draft.endpoint.splitIntoParts)
    #expect(draft.endpoint.maxBodyCharacters == 40_000)
    #expect(draft.endpoint.partDelaySeconds == 30 && draft.endpoint.noteDelaySeconds == 30)
    // The URL change that follows (the stripped address) changes nothing.
    let before = draft
    draft.urlChanged()
    #expect(draft == before)
  }

  @Test func defaultsApplyOncePerDraftAndAnyAuthorizationIsReplaced() {
    var draft = MeetingWebhookEditorDraft(
      endpoint: MeetingWebhookEndpoint(),
      isNew: true,
      headers: [
        .init(name: "X-Team", value: "a"),
        .init(name: "authorization", value: "Basic old"),
        .init(name: "AUTHORIZATION ", value: "Bearer older")
      ]
    )
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    #expect(draft.headers.map(\.name) == ["X-Team", "Authorization"])
    draft.endpoint.maxBodyCharacters = 20_000
    let second = "whsec_" + String(repeating: "Z", count: 43)
    draft.endpoint.url = Self.hookBase + "/" + second
    draft.urlChanged()
    #expect(draft.headers.last?.value == "Bearer \(second)")
    #expect(draft.headers.count == 2)
    #expect(draft.endpoint.maxBodyCharacters == 20_000)
  }

  @Test func aPartlyTypedSecretIsLeftAlone() {
    var draft = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    let partial = Self.hookBase + "/" + String(Self.secret.prefix(20))
    draft.endpoint.url = partial
    draft.urlChanged()
    #expect(draft.endpoint.url == partial)
    #expect(draft.headers.isEmpty)
    #expect(!draft.showsMausBotBadge && !draft.showsMausBotDefaults)
    #expect(!draft.endpoint.splitIntoParts)
    #expect(draft.endpoint.maxBodyCharacters == MeetingWebhookEndpoint.defaultMaxBodyCharacters)
  }

  @Test func pointingTheURLElsewhereClearsTheMovedSecret() {
    var draft = MeetingWebhookEditorDraft(
      endpoint: MeetingWebhookEndpoint(),
      isNew: true,
      headers: [.init(name: "X-Team", value: "a")]
    )
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    // Same destination, written differently: kept.
    draft.endpoint.url = "HTTP://127.0.0.1:8800/hooks/wh_AbC123xYz"
    draft.urlChanged()
    #expect(draft.headers.count == 2 && draft.showsMausBotBadge)
    // Another destination: cleared, other headers kept, no badge.
    draft.endpoint.url = "http://127.0.0.1:8800/hooks/wh_Other"
    draft.urlChanged()
    #expect(draft.headers.map(\.name) == ["X-Team"])
    #expect(!draft.showsMausBotBadge && !draft.showsMausBotDefaults)
  }

  @Test func anEditedMovedHeaderIsNotCleared() {
    var draft = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    draft.headers[0].value = "Bearer typed-by-hand"
    draft.endpoint.url = "https://example.com/hook"
    draft.urlChanged()
    #expect(draft.headers.map(\.value) == ["Bearer typed-by-hand"])
  }

  @Test func editingAnExistingWebhookMovesTheSecretButKeepsDeliverySettings() {
    let saved = MeetingWebhookEndpoint(
      name: "Notes Bot",
      url: "https://example.com/hook",
      splitIntoParts: false,
      maxBodyCharacters: 3_800,
      content: .summary,
      partDelaySeconds: 7,
      noteDelaySeconds: 45
    )
    var draft = MeetingWebhookEditorDraft(endpoint: saved, isNew: false)
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    #expect(draft.endpoint.url == Self.hookBase)
    #expect(draft.headers.first?.value == "Bearer \(Self.secret)")
    #expect(draft.showsMausBotBadge && !draft.showsMausBotDefaults)
    var expected = saved
    expected.url = Self.hookBase
    #expect(draft.endpoint == expected)
  }

  @Test func anyOtherAddressShowsNoneOfThis() {
    var draft = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    for url in ["https://example.com/hook", "https://example.com/hook/" + Self.secret,
                Self.hookBase] {
      draft.endpoint.url = url
      draft.urlChanged()
      #expect(draft.endpoint.url == url)
      #expect(draft.headers.isEmpty)
      #expect(!draft.showsMausBotBadge && !draft.showsMausBotDefaults)
      #expect(draft.endpoint == MeetingWebhookEndpoint(id: draft.endpoint.id, url: url))
    }
  }

  @MainActor
  @Test func saveStoresTheURLWithoutTheSecretAndTheSecretOnlyInTheKeychain() throws {
    let key = MeetingWebhookEndpointStore.defaultsKey
    let previous = AppConfig.defaults.object(forKey: key)
    defer { AppConfig.defaults.set(previous, forKey: key) }
    AppConfig.defaults.removeObject(forKey: key)
    let secrets = MeetingWebhookInMemorySecretStore()
    let store = MeetingWebhookEndpointStore(defaults: { AppConfig.defaults }, secrets: secrets)
    let center = MeetingWebhookCenter(
      store: store,
      deliveryService: MeetingWebhookDeliveryService(transport: FakeMeetingWebhookTransport([])),
      log: MeetingWebhookDeliveryLog(fileURL: AppStoragePaths.appSupportRoot()
        .appendingPathComponent("webhook-log-test-\(UUID().uuidString).json"))
    )

    var cancelled = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    cancelled.endpoint.url = Self.fullAddress
    cancelled.urlChanged()
    // Cancel: the sheet just drops the draft. Nothing reached either store.
    #expect(store.load().isEmpty && secrets.storedKeys.isEmpty)

    var draft = MeetingWebhookEditorDraft(endpoint: MeetingWebhookEndpoint(), isNew: true)
    draft.endpoint.url = Self.fullAddress
    draft.urlChanged()
    let headers = try draft.editedHeaders().get()
    #expect(center.saveEndpoint(draft.endpoint, signingSecret: nil, headers: headers) == nil)
    let raw = String(decoding: AppConfig.defaults.data(forKey: key) ?? Data(), as: UTF8.self)
    #expect(!raw.contains("whsec_"))
    #expect(store.load().first?.url == Self.hookBase)
    #expect(store.load().first?.headerNames == ["Authorization"])
    #expect(try store.headers(for: draft.endpoint.id)
      == ["Authorization": "Bearer \(Self.secret)"])
    center.deleteEndpoint(draft.endpoint.id)
    #expect(secrets.storedKeys.isEmpty)
  }

  @MainActor
  @Test func saveRefusesReservedHeadersForTheAddress() {
    let key = MeetingWebhookEndpointStore.defaultsKey
    let previous = AppConfig.defaults.object(forKey: key)
    defer { AppConfig.defaults.set(previous, forKey: key) }
    AppConfig.defaults.removeObject(forKey: key)
    let store = MeetingWebhookEndpointStore(
      defaults: { AppConfig.defaults },
      secrets: MeetingWebhookInMemorySecretStore()
    )
    let center = MeetingWebhookCenter(
      store: store,
      deliveryService: MeetingWebhookDeliveryService(transport: FakeMeetingWebhookTransport([])),
      log: MeetingWebhookDeliveryLog(fileURL: AppStoragePaths.appSupportRoot()
        .appendingPathComponent("webhook-log-test-\(UUID().uuidString).json"))
    )
    let other = MeetingWebhookEndpoint(url: "https://example.com/hook")
    #expect(center.saveEndpoint(other, signingSecret: nil, headers: ["IDEMPOTENCY-KEY": "x"])
      == "IDEMPOTENCY-KEY is set by WonderWhisper and can't be overridden.")
    #expect(center.saveEndpoint(other, signingSecret: nil, headers: ["X-Webhook-Id": "x"]) == nil)
    let mausBot = MeetingWebhookEndpoint(url: Self.hookBase)
    #expect(center.saveEndpoint(mausBot, signingSecret: nil, headers: ["x-webhook-id": "x"])
      == "x-webhook-id can't be added for a MausBot address.")
    center.deleteEndpoint(other.id)
  }

  // MARK: - 5. Receiver replies

  @Test func onlyLiteralJSONBooleansCount() {
    func parse(_ text: String, overflowed: Bool = false) -> MeetingWebhookReceiverOutcome? {
      MeetingWebhookReceiverOutcome.parse(Data(text.utf8), overflowed: overflowed)
    }
    #expect(parse(#"{"accepted":true,"duplicate":false,"ignored":true}"#) == .ignored)
    #expect(parse(#"{"accepted":true,"deliveryId":"x","duplicate":false,"captured":true}"#)
      == .captured)
    #expect(parse(#"{"accepted":true,"runId":"r","duplicate":true}"#) == .duplicate)
    #expect(parse(#"{"accepted":true,"runId":"r","duplicate":false}"#) == nil)
    #expect(parse(#"{"ignored":"true","captured":"true"}"#) == nil)
    #expect(parse(#"{"ignored":1,"captured":1.0}"#) == nil)
    #expect(parse(#"[{"ignored":true}]"#) == nil)
    #expect(parse("true") == nil)
    #expect(parse("ignored: true") == nil)
    #expect(parse("") == nil)
    #expect(parse(#"{"ignored":true}"#, overflowed: true) == nil)
    let padded = #"{"ignored":true,"pad":""# + String(repeating: "x", count: 4_100) + #""}"#
    #expect(parse(padded) == nil)
  }

  @Test func ignoredAndCapturedRepliesAreDeliveredWithoutRetry() async throws {
    for outcome in [MeetingWebhookReceiverOutcome.ignored, .captured, .duplicate] {
      let endpoint = MeetingWebhookEndpoint(name: "Notes Bot", url: Self.hookBase)
      let job = try #require(try Self.jobs(for: Self.session(), event: .test,
                                           endpoint: endpoint).first)
      let transport = FakeMeetingWebhookTransport([.reply(202, outcome)])
      let record = await Self.service(transport).deliver(job)
      #expect(record.state == .delivered)
      #expect(record.attempts == 1 && transport.requests.count == 1)
      #expect(record.receiverOutcome == outcome)
      #expect(record.lastError == nil)
    }
  }

  @Test func statusTextAndBadgeFollowTheOutcome() {
    var record = MeetingWebhookDeliveryRecord(
      id: UUID(), endpointID: UUID(), endpointName: "Glofox notes", noteID: UUID(),
      noteTitle: "t", event: .test, state: .delivered, attempts: 1, maximumAttempts: 5,
      lastStatusCode: 202, lastError: nil, createdAt: Self.fixedDate, updatedAt: Self.fixedDate
    )
    record.receiverOutcome = .ignored
    #expect(MeetingWebhookStatusFormatter.text(for: record, now: Self.fixedDate)
      == "Reached Glofox notes, but it ignored this event type")
    #expect(StatusBadge.Kind.webhookDelivered(record) == .warning)
    record.receiverOutcome = .captured
    #expect(MeetingWebhookStatusFormatter.text(for: record, now: Self.fixedDate)
      == "Reached Glofox notes. Its automation is off, so it saved this as a setup check only")
    #expect(StatusBadge.Kind.webhookDelivered(record) == .info)
    for outcome in [MeetingWebhookReceiverOutcome.duplicate, nil] {
      record.receiverOutcome = outcome
      #expect(MeetingWebhookStatusFormatter.text(for: record, now: Self.fixedDate)
        == "Sent to Glofox notes just now")
      #expect(StatusBadge.Kind.webhookDelivered(record) == .ok)
    }
  }

  @Test func aSplitSendWithOneIgnoredPartShowsIgnored() async throws {
    let endpoint = MeetingWebhookEndpoint(
      name: "Notes Bot",
      url: Self.hookBase,
      splitIntoParts: true,
      maxBodyCharacters: 1_500
    )
    let markdown = (0..<80).map { "## Topic \($0)\n\nSome detail here." }
      .joined(separator: "\n\n")
    let jobs = try Self.jobs(for: Self.session(markdown: markdown), event: .noteCompleted,
                             endpoint: endpoint)
    #expect(jobs.count >= 3)
    let transport = FakeMeetingWebhookTransport([.reply(202, nil), .reply(202, .ignored)])
    let records = await Self.service(transport).deliverParts(jobs)
    #expect(records.allSatisfy { $0.state == .delivered })
    #expect(transport.requests.count == jobs.count)
    let shown = try #require(MeetingWebhookStatusFormatter.latestSend(in: records.reversed()))
    #expect(shown.partIndex == 2)
    #expect(MeetingWebhookStatusFormatter.text(for: shown, now: Self.fixedDate)
      == "Reached Notes Bot, but it ignored this event type")
    // With no ignored or captured part the last part speaks for the send, as before.
    let plain = records.map { record -> MeetingWebhookDeliveryRecord in
      var copy = record
      copy.receiverOutcome = nil
      return copy
    }
    #expect(MeetingWebhookStatusFormatter.latestSend(in: plain.reversed())?.partIndex
      == jobs.count)
  }

  @Test func aReceiverNoticeOutranksProgressAndFailedParts() throws {
    let sendID = UUID()
    func part(
      _ index: Int,
      _ state: MeetingWebhookDeliveryRecord.State,
      _ outcome: MeetingWebhookReceiverOutcome? = nil
    ) -> MeetingWebhookDeliveryRecord {
      var record = MeetingWebhookDeliveryRecord(
        id: UUID(), endpointID: UUID(), endpointName: "Notes Bot", noteID: UUID(),
        noteTitle: "t", event: .noteCompleted, state: state, attempts: 1, maximumAttempts: 5,
        lastStatusCode: state == .failed ? 409 : 202, lastError: nil,
        createdAt: Self.fixedDate, updatedAt: Self.fixedDate, sendID: sendID, sendOrder: 1,
        partIndex: index, partTotal: 3
      )
      record.receiverOutcome = outcome
      return record
    }
    // Captured part 1, then the paused automation refuses part 2 (409): the setup-check
    // notice explains it.
    let captured = try #require(MeetingWebhookStatusFormatter.representative(
      of: [part(1, .delivered, .captured), part(2, .failed), part(3, .failed)]
    ))
    #expect(captured.partIndex == 1)
    #expect(MeetingWebhookStatusFormatter.text(for: captured, now: Self.fixedDate)
      == "Reached Notes Bot. Its automation is off, so it saved this as a setup check only")
    // Ignored outranks captured.
    #expect(MeetingWebhookStatusFormatter.representative(
      of: [part(1, .delivered, .captured), part(2, .delivered, .ignored), part(3, .delivered)]
    )?.partIndex == 2)
    // The notice also outranks parts still on their way.
    #expect(MeetingWebhookStatusFormatter.representative(
      of: [part(1, .delivered, .ignored), part(2, .retrying), part(3, .queued)]
    )?.partIndex == 1)
    // Without a notice the row shows progress while a part is on its way.
    #expect(MeetingWebhookStatusFormatter.representative(
      of: [part(1, .delivered), part(2, .retrying), part(3, .queued)]
    )?.partIndex == 2)
    // Without a notice a failed part still speaks for the send.
    #expect(MeetingWebhookStatusFormatter.representative(
      of: [part(1, .delivered), part(2, .failed), part(3, .failed)]
    )?.partIndex == 2)
  }

  @Test func recordsNeverHoldTheReplyBody() throws {
    var record = MeetingWebhookDeliveryRecord(
      id: UUID(), endpointID: UUID(), endpointName: "Notes Bot", noteID: UUID(),
      noteTitle: "t", event: .test, state: .delivered, attempts: 1, maximumAttempts: 5,
      lastStatusCode: 202, lastError: nil, createdAt: Self.fixedDate, updatedAt: Self.fixedDate
    )
    record.receiverOutcome = .captured
    let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(encoded.contains(#""receiverOutcome":"captured""#))
    #expect(!encoded.contains("accepted"))
    let decoded = try JSONDecoder().decode(MeetingWebhookDeliveryRecord.self,
                                           from: Data(encoded.utf8))
    #expect(decoded == record)
  }

  // MARK: - 5. URLSession transport

  @Test func theTransportReadsAtMostFourKilobytesOfA2xxReply() async throws {
    let cases: [(StubWebhookURLProtocol.Reply, Int, MeetingWebhookReceiverOutcome?)] = [
      (.init(status: 202, body: Data(#"{"accepted":true,"ignored":true}"#.utf8)), 202, .ignored),
      (.init(status: 202, body: Data(#"{"captured":true}"#.utf8)), 202, .captured),
      (.init(status: 202, body: Data(#"{"duplicate":true}"#.utf8)), 202, .duplicate),
      (.init(status: 200, body: Data(#"{"ignored":"true"}"#.utf8)), 200, nil),
      (.init(status: 200, body: Data("not json, ignored: true".utf8)), 200, nil),
      (.init(status: 202, body: Data((#"{"ignored":true,"p":""#
        + String(repeating: "x", count: 5_000) + #""}"#).utf8)), 202, nil),
      (.init(status: 202, body: Data(#"{"ignored":true}"#.utf8), failsAfterHeaders: true),
       202, nil),
      (.init(status: 500, body: Data(#"{"ignored":true}"#.utf8)), 500, nil)
    ]
    for (reply, status, outcome) in cases {
      let transport = StubWebhookURLProtocol.transport(reply)
      var request = URLRequest(url: try #require(URL(string: "https://stub.example/hook")))
      request.httpMethod = "POST"
      let response = try await transport.send(request)
      #expect(response.statusCode == status)
      #expect(response.receiverOutcome == outcome)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSendCancelledBeforeItStartsFinishes() async throws {
    let transport = StubWebhookURLProtocol.transport(
      .init(status: 202, body: Data(#"{"accepted":true}"#.utf8))
    )
    var request = URLRequest(url: try #require(URL(string: "https://stub.example/hook")))
    request.httpMethod = "POST"
    for _ in 0..<20 {
      let task = Task { try await transport.send(request) }
      task.cancel()
      // Must end (cancelled, or delivered if the stub was faster), never hang.
      _ = await task.result
    }
  }

  // MARK: - 6. The 48,000-character guard

  @Test func formattedLengthMatchesJavaScript() {
    // `JSON.stringify(JSON.parse(JSON.stringify(value)), null, 2).length` in node is 260.
    let value = MeetingWebhookJSONValue.object([
      ("event", .string("meeting.note.completed")),
      ("schemaVersion", .int(1)),
      ("part", .object([("index", .int(1)), ("total", .int(2)), ("endMarker", .string("E"))])),
      ("note", .object([
        ("attendees", .array([.string("a"), .string("b")])),
        ("markdown", .string("x\n\"y\"\u{01}é😀/")),
        ("n", .null),
        ("e", .array([]))
      ]))
    ])
    #expect(value.javaScriptFormattedLength == 260)
  }

  private static func manyAttendees(_ count: Int, prefix: String = "P") -> [String] {
    (0..<count).map { "\(prefix)\($0)" }
  }

  private static func longMarkdown(_ characters: Int) -> String {
    var text = ""
    var topic = 0
    while text.count < characters {
      text += "## Topic \(topic)\n\n" + String(repeating: "Detail line here. ", count: 40)
        + "\n\n"
      topic += 1
    }
    return text
  }

  @Test func manyShortAttendeesStillFormatUnderTheLimit() throws {
    let session = Self.session(markdown: Self.longMarkdown(120_000),
                               attendees: Self.manyAttendees(1_500))
    let endpoint = MeetingWebhookEndpoint(
      name: "MausBot",
      url: Self.hookBase,
      splitIntoParts: true,
      maxBodyCharacters: 40_000
    )
    // Without the guard, 40,000-byte parts would format past 48,000.
    let base = Self.builder.payload(for: session, event: .noteCompleted, deliveryID: UUID(),
                                    sentAt: Self.fixedDate)
    let unguarded = try MeetingWebhookPayloadSplitter.parts(of: base, sendID: UUID(),
                                                            maxBytes: 40_000)
    #expect(unguarded.contains { $0.jsonValue.javaScriptFormattedLength > 48_000 })

    let plan = try Self.builder.plan(for: session, event: .noteCompleted, endpoint: endpoint,
                                     sendID: UUID(), sentAt: Self.fixedDate)
    for part in plan.payloads {
      #expect(part.body.count <= 40_000)
      #expect(part.jsonValue.javaScriptFormattedLength
        <= MeetingWebhookMausBotAddress.formattedCharacterBudget)
    }
    let chunks = plan.payloads.map(MeetingWebhookPayloadSplitter.chunk(of:))
    #expect(chunks.joined() == base.note.markdown)

    // A partial resend cuts the same parts again under the same guard.
    let info = try #require(plan.split)
    let resent = try MeetingWebhookPayloadSplitter.resend(
      of: base, sendID: UUID(), chunkBudget: info.chunkBudget, total: plan.payloads.count,
      indexes: [1, plan.payloads.count], maxBytes: 40_000,
      maxFormattedLength: MeetingWebhookMausBotAddress.formattedCharacterBudget
    )
    #expect(resent.chunks == chunks)
  }

  @Test func otherAddressesAreNotGuarded() throws {
    let session = Self.session(markdown: Self.longMarkdown(120_000),
                               attendees: Self.manyAttendees(1_500))
    let endpoint = MeetingWebhookEndpoint(url: "https://example.com/hook", splitIntoParts: true,
                                          maxBodyCharacters: 40_000)
    let plan = try Self.builder.plan(for: session, event: .noteCompleted, endpoint: endpoint,
                                     sendID: UUID(), sentAt: Self.fixedDate)
    #expect(plan.payloads.contains { $0.jsonValue.javaScriptFormattedLength > 48_000 })
  }

  @Test func anImpossibleNoteFailsWithAClearStatus() throws {
    let session = Self.session(markdown: "## Summary", attendees: Self.manyAttendees(
      2_000, prefix: "attendee-with-a-long-name-"))
    let endpoint = MeetingWebhookEndpoint(name: "MausBot", url: Self.hookBase,
                                          splitIntoParts: true, maxBodyCharacters: 1_000_000)
    #expect(throws: MeetingWebhookPayloadSplitter.SplitError.self) {
      try Self.builder.plan(for: session, event: .noteCompleted, endpoint: endpoint,
                            sendID: UUID(), sentAt: Self.fixedDate)
    }
    do {
      _ = try Self.builder.plan(for: session, event: .noteCompleted, endpoint: endpoint,
                                sendID: UUID(), sentAt: Self.fixedDate)
    } catch let error as MeetingWebhookPayloadSplitter.SplitError {
      guard case .tooLongForMausBot = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(error.message.hasPrefix("Too long for MausBot"))
    }
  }

  @Test func anUnsplitMausBotSendThatWouldBeCutFails() throws {
    let session = Self.session(markdown: Self.longMarkdown(60_000))
    let endpoint = MeetingWebhookEndpoint(name: "MausBot", url: Self.hookBase)
    #expect(throws: MeetingWebhookPayloadSplitter.SplitError.self) {
      try Self.builder.plan(for: session, event: .noteCompleted, endpoint: endpoint,
                            sendID: UUID(), sentAt: Self.fixedDate)
    }
    // A short unsplit note still goes out as one body.
    let short = try Self.builder.plan(for: Self.session(), event: .noteCompleted,
                                      endpoint: endpoint, sendID: UUID(), sentAt: Self.fixedDate)
    #expect(short.payloads.count == 1)
  }

  // MARK: - Part checksum

  @Test func resendingASendMadeBeforeTheChecksumKeepsItsLayout() throws {
    // No break points, so every chunk is cut exactly full and the old budget leaves no room.
    let base = Self.builder.payload(
      for: Self.session(markdown: String(repeating: "x", count: 20_000)),
      event: .noteResent, deliveryID: UUID(), sentAt: Self.fixedDate
    )
    let sendID = UUID()
    let current = try MeetingWebhookPayloadSplitter.split(of: base, sendID: sendID,
                                                          maxBytes: 4_000)
    let checksumField = #","sha256":""# + String(repeating: "0", count: 64) + #"""#
    let legacyBudget = current.chunkBudget + checksumField.utf8.count
    let legacyChunks = try #require(MeetingWebhookPayloadSplitter.chunks(of: base.note.markdown,
                                                                         budget: legacyBudget))
    let resent = try MeetingWebhookPayloadSplitter.resend(
      of: base, sendID: sendID, chunkBudget: legacyBudget, total: legacyChunks.count,
      indexes: [1], maxBytes: 4_000
    )
    let part = try #require(resent.parts.first)
    #expect(part.body.count <= 4_000)
    #expect(part.part?.sha256 == nil)
    #expect(MeetingWebhookPayloadSplitter.chunk(of: part) == legacyChunks[0])
    // A current send keeps its checksum on resend.
    let again = try MeetingWebhookPayloadSplitter.resend(
      of: base, sendID: sendID, chunkBudget: current.chunkBudget, total: current.parts.count,
      indexes: [1], maxBytes: 4_000
    )
    #expect(again.parts.first?.part?.sha256 == MeetingWebhookFingerprint.of(current.chunks[0]))
  }

  @Test func splitPartsCarryTheirChunkChecksumAndUnsplitBodiesDoNot() throws {
    let endpoint = MeetingWebhookEndpoint(url: "https://example.com/hook", splitIntoParts: true,
                                          maxBodyCharacters: 1_500)
    let markdown = (0..<20).map { "## Topic \($0)\n\nSome détail 😀 here." }
      .joined(separator: "\n\n")
    let plan = try Self.builder.plan(for: Self.session(markdown: markdown),
                                     event: .noteCompleted, endpoint: endpoint,
                                     sendID: UUID(), sentAt: Self.fixedDate)
    #expect(plan.payloads.count > 1)
    for (offset, part) in plan.payloads.enumerated() {
      let json = try #require(try JSONSerialization.jsonObject(with: part.body)
        as? [String: Any])
      let partJSON = try #require(json["part"] as? [String: Any])
      let chunk = MeetingWebhookPayloadSplitter.chunk(of: part)
      #expect(partJSON["sha256"] as? String == MeetingWebhookFingerprint.of(chunk))
      #expect(plan.split?.partFingerprints[offset] == partJSON["sha256"] as? String)
      let text = String(decoding: part.body, as: UTF8.self)
      #expect(text.contains(#""endMarker":"END-OF-PAYLOAD part \#(offset + 1) of "#
        + #"\#(plan.payloads.count)","sha256":""#))
    }
    let unsplit = Self.builder.payload(for: Self.session(), event: .noteCompleted,
                                       deliveryID: UUID(), sentAt: Self.fixedDate)
    #expect(!String(decoding: unsplit.body, as: UTF8.self).contains("sha256"))
  }
}

/// Answers every request with one scripted reply, optionally failing after the headers.
final class StubWebhookURLProtocol: URLProtocol {
  struct Reply: Sendable {
    let status: Int
    let body: Data
    var failsAfterHeaders = false
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var current: Reply?
  /// What MausBot sends. With a content type URLSession hands over the response at once
  /// instead of waiting for body bytes to sniff one.
  private static let headers = [
    "Content-Type": "application/json",
    "X-Content-Type-Options": "nosniff"
  ]

  static func transport(_ reply: Reply) -> MeetingWebhookURLSessionTransport {
    lock.withLock { current = reply }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubWebhookURLProtocol.self]
    return MeetingWebhookURLSessionTransport(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let reply = Self.lock.withLock({ Self.current }), let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                         httpVersion: "HTTP/1.1",
                                         headerFields: Self.headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if reply.failsAfterHeaders {
      // The connection drops while the body is read, after the status arrived.
      client?.urlProtocol(self, didLoad: reply.body.prefix(5))
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      }
      return
    }
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
