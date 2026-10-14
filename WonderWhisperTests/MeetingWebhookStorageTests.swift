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
