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
    #expect(store.signingSecret(for: endpoint.id) == "topsecret")
    #expect(store.headers(for: endpoint.id) == ["Authorization": "Bearer abc"])

    // Defaults hold no secret values.
    let raw = String(decoding: AppConfig.defaults.data(forKey: key) ?? Data(), as: UTF8.self)
    #expect(!raw.contains("topsecret") && !raw.contains("Bearer abc"))

    // nil keeps the secret; an empty string clears it.
    try store.upsert(endpoint, signingSecret: nil, headers: ["Authorization": "Bearer abc"])
    #expect(store.signingSecret(for: endpoint.id) == "topsecret")
    try store.upsert(endpoint, signingSecret: "", headers: [:])
    #expect(store.load().first?.hasSecret == false)
    #expect(store.headers(for: endpoint.id).isEmpty)

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
}
