import Foundation
import Testing
@testable import WonderWhisper

/// Endpoint store and delivery log persistence. Uses the scratch `AppConfig.defaults` suite,
/// scratch app support and an in-memory secret store: never the real prefs or Keychain.
@Suite(.serialized)
struct MeetingWebhookStorageTests {
  private static func record(
    state: MeetingWebhookDeliveryRecord.State,
    createdAt: Date = Date()
  ) -> MeetingWebhookDeliveryRecord {
    MeetingWebhookDeliveryRecord(
      id: UUID(), endpointID: UUID(), endpointName: "Grok Bot", noteID: UUID(),
      noteTitle: "Planning", event: .noteCompleted, state: state, attempts: 1,
      maximumAttempts: 5, lastStatusCode: nil, lastError: nil,
      createdAt: createdAt, updatedAt: createdAt
    )
  }

  private static func scratchLogURL() -> URL {
    AppStoragePaths.appSupportRoot()
      .appendingPathComponent("webhook-log-test-\(UUID().uuidString).json")
  }

  @Test func endpointStoreRoundTripsAndDeleteRemovesSecrets() throws {
    #expect(AppConfig.defaults !== UserDefaults.standard)
    let key = MeetingWebhookEndpointStore.defaultsKey
    let previous = AppConfig.defaults.object(forKey: key)
    defer { AppConfig.defaults.set(previous, forKey: key) }
    AppConfig.defaults.removeObject(forKey: key)

    let secrets = MeetingWebhookInMemorySecretStore()
    let store = MeetingWebhookEndpointStore(defaults: { AppConfig.defaults }, secrets: secrets)
    let endpoint = MeetingWebhookEndpoint(name: " Grok Bot ", url: "https://example.com/hook")
    try store.upsert(
      endpoint,
      signingSecret: "topsecret",
      headers: ["Authorization": "Bearer abc"]
    )

    let loaded = store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.name == "Grok Bot")
    #expect(loaded.first?.hasSecret == true)
    #expect(loaded.first?.headerNames == ["Authorization"])
    #expect(try store.signingSecret(for: endpoint.id) == "topsecret")
    #expect(try store.headers(for: endpoint.id) == ["Authorization": "Bearer abc"])

    // Defaults hold no secret values.
    let raw = String(decoding: AppConfig.defaults.data(forKey: key) ?? Data(), as: UTF8.self)
    #expect(!raw.contains("topsecret") && !raw.contains("Bearer abc"))

    // nil keeps the secret; an empty string clears it.
    try store.upsert(endpoint, signingSecret: nil, headers: ["Authorization": "Bearer abc"])
    #expect(try store.signingSecret(for: endpoint.id) == "topsecret")
    try store.upsert(endpoint, signingSecret: "", headers: [:])
    #expect(store.load().first?.hasSecret == false)
    #expect(try store.headers(for: endpoint.id).isEmpty)

    try store.upsert(endpoint, signingSecret: "again", headers: ["X-Token": "t"])
    store.setEnabled(false, for: endpoint.id)
    #expect(store.load().first?.isEnabled == false)
    store.delete(endpoint.id)
    #expect(store.load().isEmpty)
    #expect(secrets.storedKeys.isEmpty)
  }

  @Test func logUpsertKeepsNewestFirstAndCapsAt200() {
    var records: [MeetingWebhookDeliveryRecord] = []
    for _ in 0..<205 {
      records = MeetingWebhookDeliveryLog.upserting(Self.record(state: .delivered), into: records)
    }
    #expect(records.count == MeetingWebhookDeliveryLog.maximumRecords)
    var first = records[0]
    first.state = .failed
    let updated = MeetingWebhookDeliveryLog.upserting(first, into: records)
    #expect(updated.count == 200)
    #expect(updated[0].id == first.id)
    #expect(updated[0].state == .failed)
  }

  @Test func logMarksInterruptedRecordsFailedOnLoad() async throws {
    let url = Self.scratchLogURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let sending = Self.record(state: .sending)
    let retrying = Self.record(state: .retrying)
    let delivered = Self.record(state: .delivered)

    let writer = MeetingWebhookDeliveryLog(fileURL: url)
    await writer.save([sending, retrying, delivered], generation: 1)
    // A stale snapshot never overwrites a newer one.
    await writer.save([], generation: 0)

    let loaded = await MeetingWebhookDeliveryLog(fileURL: url).load()
    #expect(loaded.count == 3)
    #expect(loaded[0].state == .failed)
    #expect(loaded[0].lastError == MeetingWebhookDeliveryLog.interruptedMessage)
    #expect(loaded[1].state == .failed)
    #expect(loaded[2].state == .delivered)

    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(!raw.contains("\"sending\"") && !raw.contains("\"retrying\""))
  }

  // MARK: - Review fixes

  @MainActor
  private static func scratchCenter(
    secrets: MeetingWebhookSecretStoring,
    transport: FakeMeetingWebhookTransport,
    sleeper: @escaping MeetingWebhookDeliveryService.Sleeper = { _ in }
  ) -> (MeetingWebhookCenter, MeetingWebhookEndpointStore) {
    let store = MeetingWebhookEndpointStore(defaults: { AppConfig.defaults }, secrets: secrets)
    let service = MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: sleeper,
      jitter: { 0 }
    )
    let center = MeetingWebhookCenter(
      store: store,
      deliveryService: service,
      log: MeetingWebhookDeliveryLog(fileURL: scratchLogURL()),
      payloadBuilder: MeetingWebhookPayloadBuilder(
        appInfo: MeetingWebhookAppInfo(name: "WonderWhisper", version: "test", build: "1")
      )
    )
    return (center, store)
  }

  private static func finishedSession() -> MeetingSession {
    MeetingSession(title: "Planning", endedAt: Date(), recordedDuration: 60, status: .completed)
  }

  @MainActor
  private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  @MainActor
  private static func withScratchEndpoints(
    _ body: @MainActor () async throws -> Void
  ) async rethrows {
    let key = MeetingWebhookEndpointStore.defaultsKey
    let previous = AppConfig.defaults.object(forKey: key)
    defer { AppConfig.defaults.set(previous, forKey: key) }
    AppConfig.defaults.removeObject(forKey: key)
    try await body()
  }

  @Test func completedWebhookOnlySendsAfterSuccessfulPersist() {
    #expect(MeetingCoordinator.shouldSendCompletedWebhook(persisted: true, isCancelled: false))
    #expect(!MeetingCoordinator.shouldSendCompletedWebhook(persisted: false, isCancelled: false))
    #expect(!MeetingCoordinator.shouldSendCompletedWebhook(persisted: true, isCancelled: true))
    #expect(!MeetingCoordinator.shouldSendCompletedWebhook(persisted: false, isCancelled: true))
  }

  @MainActor
  @Test func unreadableSecretsArePreservedWhenTheEditorSaves() async throws {
    try await Self.withScratchEndpoints {
      let secrets = ToggleableSecretStore()
      let (center, store) = Self.scratchCenter(
        secrets: secrets,
        transport: FakeMeetingWebhookTransport([])
      )
      let endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
      try store.upsert(endpoint, signingSecret: "topsecret", headers: ["Authorization": "B"])
      center.reloadEndpoints()

      secrets.isUnreadable = true
      #expect(throws: MeetingWebhookCredentialsError.self) { try center.headers(for: endpoint.id) }
      #expect(throws: MeetingWebhookCredentialsError.self) {
        try store.signingSecret(for: endpoint.id)
      }

      // The editor could not read the headers and the user only renamed the endpoint.
      let headers = MeetingWebhookEditorSheet.headersToSave(loaded: nil, edited: [:], isNew: false)
      #expect(headers == nil)
      var renamed = endpoint
      renamed.name = "Grok Bot 2"
      #expect(center.saveEndpoint(renamed, signingSecret: nil, headers: headers) == nil)

      secrets.isUnreadable = false
      #expect(try store.signingSecret(for: endpoint.id) == "topsecret")
      #expect(try store.headers(for: endpoint.id) == ["Authorization": "B"])
      let saved = try #require(store.load().first)
      #expect(saved.name == "Grok Bot 2")
      #expect(saved.hasSecret)
      #expect(saved.headerNames == ["Authorization"])

      // Unchanged readable headers are not rewritten either; real edits are.
      let loaded = ["Authorization": "B"]
      #expect(MeetingWebhookEditorSheet.headersToSave(
        loaded: loaded, edited: loaded, isNew: false
      ) == nil)
      #expect(MeetingWebhookEditorSheet.headersToSave(
        loaded: loaded, edited: [:], isNew: false
      ) == [:])
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func unreadableSecretsFailTheDeliveryWithoutSending() async throws {
    try await Self.withScratchEndpoints {
      let secrets = ToggleableSecretStore()
      let transport = FakeMeetingWebhookTransport([.status(200)])
      let (center, store) = Self.scratchCenter(secrets: secrets, transport: transport)
      let endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
      try store.upsert(endpoint, signingSecret: "topsecret", headers: ["Authorization": "B"])
      center.reloadEndpoints()
      var surfaced: String?
      center.onFinalFailure = { surfaced = $0 }

      secrets.isUnreadable = true
      let started = center.send(Self.finishedSession(), event: .noteCompleted)

      #expect(started == 0)
      let record = try #require(center.deliveries.first)
      #expect(record.state == .failed)
      #expect(record.lastError == MeetingWebhookCredentialsError.userMessage)
      #expect(surfaced?.contains(MeetingWebhookCredentialsError.userMessage) == true)
      try? await Task.sleep(nanoseconds: 50_000_000)
      #expect(transport.requests.isEmpty)
      secrets.isUnreadable = false
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func deletingAnEndpointDuringBackoffStopsFurtherRequests() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport,
        // Real, cancellation-aware wait: long enough that only cancellation can end it.
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      var surfaced: String?
      center.onFinalFailure = { surfaced = $0 }

      #expect(center.send(Self.finishedSession(), event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)

      center.deleteEndpoint(endpoint.id)
      let ended = await Self.waitUntil { center.deliveries.first?.state == .failed }
      #expect(ended)
      #expect(center.deliveries.first?.lastError == MeetingWebhookCenter.removedReason)
      #expect(transport.requests.count == 1)
      #expect(surfaced == nil)
    }
  }

  @MainActor
  @Test func disablingAnEndpointFromTheEditorStopsFurtherRequests() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport,
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
      try store.upsert(endpoint, signingSecret: "topsecret", headers: ["Authorization": "B"])
      center.reloadEndpoints()

      #expect(center.send(Self.finishedSession(), event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)

      var disabled = endpoint
      disabled.isEnabled = false
      #expect(center.saveEndpoint(disabled, signingSecret: nil, headers: nil) == nil)
      let ended = await Self.waitUntil { center.deliveries.first?.state == .failed }
      #expect(ended)
      #expect(center.deliveries.first?.lastError == MeetingWebhookCenter.disabledReason)
      #expect(transport.requests.count == 1)
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func changingAnEndpointURLStopsRetriesToTheOldURL() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport,
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let endpoint = MeetingWebhookEndpoint(name: "Grok Bot", url: "https://example.com/hook")
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()

      #expect(center.send(Self.finishedSession(), event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)

      var moved = endpoint
      moved.url = "https://example.org/new-hook"
      #expect(center.saveEndpoint(moved, signingSecret: nil, headers: nil) == nil)
      let ended = await Self.waitUntil { center.deliveries.first?.state == .failed }
      #expect(ended)
      #expect(center.deliveries.first?.lastError == MeetingWebhookCenter.editedReason)
      #expect(transport.requests.count == 1)
      center.deleteEndpoint(endpoint.id)
    }
  }

  // MARK: - Split sends

  private static func longFinishedSession() -> MeetingSession {
    MeetingSession(
      title: "Planning",
      endedAt: Date(),
      recordedDuration: 60,
      status: .completed,
      notesMarkdown: (0..<40)
        .map { "## Topic \($0)\n\n" + String(repeating: "Detail. ", count: 30) }
        .joined(separator: "\n\n")
    )
  }

  private static func bodyJSON(_ request: URLRequest) -> [String: Any]? {
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  @MainActor
  @Test func splitSendDeliversAllPartsAndResendUsesNewIDs() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([])
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport
      )
      let endpoint = MeetingWebhookEndpoint(
        name: "Grok Bot",
        url: "https://example.com/hook",
        splitIntoParts: true,
        maxBodyCharacters: 3_800,
        content: .summary
      )
      try store.upsert(endpoint, signingSecret: "topsecret", headers: [:])
      center.reloadEndpoints()
      let session = Self.longFinishedSession()

      #expect(center.send(session, event: .noteCompleted) == 1)
      let firstDone = await Self.waitUntil {
        let records = center.deliveries.filter { $0.noteID == session.id }
        return !records.isEmpty && records.allSatisfy { $0.state == .delivered }
          && records.count == records.first?.partTotal
      }
      #expect(firstDone)
      let firstRequests = transport.requests
      #expect(firstRequests.count > 1)
      #expect(firstRequests.allSatisfy { ($0.httpBody?.count ?? .max) <= 3_800 })
      let firstBodies = firstRequests.compactMap(Self.bodyJSON)
      let firstSendIDs = Set(firstBodies.compactMap { $0["sendId"] as? String })
      #expect(firstSendIDs.count == 1)
      let indexes = firstBodies.compactMap { ($0["part"] as? [String: Any])?["index"] as? Int }
      #expect(indexes == Array(1...firstRequests.count))
      let summary = try #require(center.latestRecords(forNote: session.id).first)
      #expect(summary.partIndex == summary.partTotal)
      #expect(MeetingWebhookStatusFormatter.text(for: summary).hasPrefix(
        "Sent to Grok Bot (\(firstRequests.count) parts)"
      ))

      // Resend: every part again, with a new sendId and new deliveryIds.
      #expect(center.send(session, event: .noteResent, endpointIDs: [endpoint.id]) == 1)
      let secondDone = await Self.waitUntil {
        transport.requests.count == firstRequests.count * 2
          && center.deliveries.filter { $0.event == .noteResent }
            .allSatisfy { $0.state == .delivered }
      }
      #expect(secondDone)
      let secondBodies = transport.requests.dropFirst(firstRequests.count)
        .compactMap(Self.bodyJSON)
      let secondSendIDs = Set(secondBodies.compactMap { $0["sendId"] as? String })
      #expect(secondSendIDs.count == 1 && secondSendIDs.isDisjoint(with: firstSendIDs))
      let firstIDs = Set(firstBodies.compactMap { $0["deliveryId"] as? String })
      let secondIDs = Set(secondBodies.compactMap { $0["deliveryId"] as? String })
      #expect(firstIDs.isDisjoint(with: secondIDs))
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func aLimitTooSmallForTheMetadataFailsWithoutSending() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([])
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport
      )
      let endpoint = MeetingWebhookEndpoint(
        name: "Grok Bot",
        url: "https://example.com/hook",
        splitIntoParts: true,
        maxBodyCharacters: 1_000
      )
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      var surfaced: String?
      center.onFinalFailure = { surfaced = $0 }
      var session = Self.longFinishedSession()
      session.title = String(repeating: "Very long title ", count: 100)

      #expect(center.send(session, event: .noteCompleted) == 0)
      let record = try #require(center.deliveries.first)
      #expect(record.state == .failed)
      #expect(record.lastError?.contains("too small") == true)
      #expect(surfaced?.contains("too small") == true)
      try? await Task.sleep(nanoseconds: 50_000_000)
      #expect(transport.requests.isEmpty)
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func anOlderSendResumingAfterANewerFailureDoesNotHideIt() async throws {
    try await Self.withScratchEndpoints {
      // Old send: part 1 gets 500 and waits at the gate. Resend: part 1 gets 400 and fails.
      // Then the old send resumes and delivers every part.
      let transport = FakeMeetingWebhookTransport([.status(500), .status(400)])
      let gate = BackoffGate()
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport,
        sleeper: { _ in try await gate.wait() }
      )
      let endpoint = MeetingWebhookEndpoint(
        name: "Bot",
        url: "https://example.com/hook",
        splitIntoParts: true,
        maxBodyCharacters: 3_800
      )
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      let session = Self.longFinishedSession()

      #expect(center.send(session, event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)
      try? await Task.sleep(nanoseconds: 5_000_000)

      #expect(center.send(session, event: .noteResent, endpointIDs: [endpoint.id]) == 1)
      let resendFailed = await Self.waitUntil {
        let resent = center.deliveries.filter { $0.event == .noteResent }
        return !resent.isEmpty && resent.count == resent.first?.partTotal
          && resent.allSatisfy { $0.state == .failed }
      }
      #expect(resendFailed)

      gate.open()
      let oldDelivered = await Self.waitUntil {
        let old = center.deliveries.filter { $0.event == .noteCompleted }
        return !old.isEmpty && old.count == old.first?.partTotal
          && old.allSatisfy { $0.state == .delivered }
      }
      #expect(oldDelivered)

      let expected = "Bot failed at part 1 of "
      let noteStatus = try #require(center.latestRecords(forNote: session.id).first)
      #expect(noteStatus.event == .noteResent)
      #expect(noteStatus.state == .failed)
      #expect(MeetingWebhookStatusFormatter.text(for: noteStatus).hasPrefix(expected))
      let endpointStatus = try #require(center.latestRecord(forEndpoint: endpoint.id))
      #expect(endpointStatus.id == noteStatus.id)
      #expect(endpointStatus.state == .failed)
      center.deleteEndpoint(endpoint.id)
    }
  }
}

/// In-memory secrets whose reads can be switched to fail, like a locked Keychain.
final class ToggleableSecretStore: MeetingWebhookSecretStoring, @unchecked Sendable {
  private let backing = MeetingWebhookInMemorySecretStore()
  private let lock = NSLock()
  private var unreadable = false

  var isUnreadable: Bool {
    get { lock.lock(); defer { lock.unlock() }; return unreadable }
    set { lock.lock(); unreadable = newValue; lock.unlock() }
  }

  func readSecret(forKey key: String) -> MeetingWebhookSecretRead {
    isUnreadable ? .unreadable("Interaction is not allowed") : backing.readSecret(forKey: key)
  }

  func setSecret(_ value: String, forKey key: String) throws {
    try backing.setSecret(value, forKey: key)
  }

  func deleteSecret(forKey key: String) {
    backing.deleteSecret(forKey: key)
  }
}

/// A backoff sleeper that waits until opened, so a test can hold a delivery in its retry wait.
final class BackoffGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false

  func open() {
    lock.withLock { isOpen = true }
  }

  func wait() async throws {
    while !lock.withLock({ isOpen }) {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
