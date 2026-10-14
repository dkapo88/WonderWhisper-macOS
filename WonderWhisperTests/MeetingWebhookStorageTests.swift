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
    transport: MeetingWebhookTransport,
    sleeper: @escaping MeetingWebhookDeliveryService.Sleeper = { _ in },
    logURL: URL = scratchLogURL()
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
      log: MeetingWebhookDeliveryLog(fileURL: logURL),
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
      let oldOrders = Set(center.deliveries.filter { $0.event == .noteCompleted }
        .compactMap(\.sendOrder))
      let newOrders = Set(center.deliveries.filter { $0.event == .noteResent }
        .compactMap(\.sendOrder))
      #expect(oldOrders.count == 1 && newOrders.count == 1)
      #expect((oldOrders.first ?? 0) < (newOrders.first ?? 0))
      center.deleteEndpoint(endpoint.id)
    }
  }

  /// Two sends in the same second, then the older one resumes after the newer one failed:
  /// the parts of one send, built in log order (newest first) like the center does.
  private static func sameSecondOverlapLog(
    withSendOrder: Bool
  ) -> (records: [MeetingWebhookDeliveryRecord], endpointID: UUID, noteID: UUID, newer: UUID) {
    let endpointID = UUID()
    let noteID = UUID()
    let second = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let base = second.timeIntervalSinceReferenceDate
    let older = UUID()
    let newer = UUID()
    func part(
      _ sendID: UUID, order: Double, event: MeetingWebhookEvent, index: Int,
      state: MeetingWebhookDeliveryRecord.State, at offset: Double
    ) -> MeetingWebhookDeliveryRecord {
      let created = second.addingTimeInterval(offset)
      return MeetingWebhookDeliveryRecord(
        id: UUID(), endpointID: endpointID, endpointName: "Bot", noteID: noteID,
        noteTitle: "Planning", event: event, state: state, attempts: 1, maximumAttempts: 5,
        lastStatusCode: state == .failed ? 400 : 200,
        lastError: state == .failed ? (index == 1 ? "HTTP 400" : "Skipped: part 1 failed") : nil,
        createdAt: created, updatedAt: created, sendID: sendID,
        sendCreatedAt: second.addingTimeInterval(order - base),
        sendOrder: withSendOrder ? order : nil, partIndex: index, partTotal: 3
      )
    }
    var records: [MeetingWebhookDeliveryRecord] = []
    let olderOrder = base + 0.1
    let newerOrder = base + 0.2
    var olderFirst = part(older, order: olderOrder, event: .noteCompleted, index: 1,
                          state: .retrying, at: 0.1)
    records = MeetingWebhookDeliveryLog.upserting(olderFirst, into: records)
    for index in 1...3 {
      let failed = part(newer, order: newerOrder, event: .noteResent, index: index,
                        state: .failed, at: 0.2)
      records = MeetingWebhookDeliveryLog.upserting(failed, into: records)
    }
    olderFirst.state = .delivered
    records = MeetingWebhookDeliveryLog.upserting(olderFirst, into: records)
    for index in 2...3 {
      let delivered = part(older, order: olderOrder, event: .noteCompleted, index: index,
                           state: .delivered, at: 0.3)
      records = MeetingWebhookDeliveryLog.upserting(delivered, into: records)
    }
    return (records, endpointID, noteID, newer)
  }

  @Test func sameSecondSendsKeepTheirOrderAcrossALogReload() async throws {
    let scenario = Self.sameSecondOverlapLog(withSendOrder: true)
    let url = Self.scratchLogURL()
    defer { try? FileManager.default.removeItem(at: url) }
    await MeetingWebhookDeliveryLog(fileURL: url).save(scenario.records, generation: 1)
    let loaded = await MeetingWebhookDeliveryLog(fileURL: url).load()
    #expect(loaded.count == scenario.records.count)
    #expect(loaded.map(\.sendOrder) == scenario.records.map(\.sendOrder))

    let noteStatus = try #require(
      MeetingWebhookStatusFormatter.latestPerEndpoint(loaded, noteID: scenario.noteID).first
    )
    #expect(noteStatus.sendID == scenario.newer)
    #expect(noteStatus.state == .failed)
    #expect(MeetingWebhookStatusFormatter.text(for: noteStatus)
      == "Bot failed at part 1 of 3: HTTP 400")
    let endpointStatus = MeetingWebhookStatusFormatter.latestSend(
      in: loaded.filter { $0.endpointID == scenario.endpointID }
    )
    #expect(endpointStatus?.id == noteStatus.id)

    // Without the numeric key the reloaded whole-second dates tie and the older send wins,
    // which is the regression this key prevents.
    let legacy = Self.sameSecondOverlapLog(withSendOrder: false)
    let legacyURL = Self.scratchLogURL()
    defer { try? FileManager.default.removeItem(at: legacyURL) }
    await MeetingWebhookDeliveryLog(fileURL: legacyURL).save(legacy.records, generation: 1)
    let legacyLoaded = await MeetingWebhookDeliveryLog(fileURL: legacyURL).load()
    let legacyStatus = MeetingWebhookStatusFormatter.latestPerEndpoint(
      legacyLoaded,
      noteID: legacy.noteID
    ).first
    #expect(legacyStatus?.sendID != legacy.newer)
  }

  @MainActor
  @Test func sendsStartedBeforeTheLogLoadsRankAboveAPersistedSendFromTheFuture() async throws {
    try await Self.withScratchEndpoints {
      let endpoint = MeetingWebhookEndpoint(
        name: "Bot",
        url: "https://example.com/hook",
        splitIntoParts: true,
        maxBodyCharacters: 3_800
      )
      let session = Self.longFinishedSession()
      // A delivered send persisted with a key an hour ahead: the clock has since gone back.
      let future = Date().addingTimeInterval(3_600)
      let persistedSend = UUID()
      let persisted = (1...3).map { index in
        MeetingWebhookDeliveryRecord(
          id: UUID(), endpointID: endpoint.id, endpointName: "Bot", noteID: session.id,
          noteTitle: session.title, event: .noteCompleted, state: .delivered, attempts: 1,
          maximumAttempts: 5, lastStatusCode: 200, lastError: nil, createdAt: future,
          updatedAt: future, sendID: persistedSend, sendCreatedAt: future,
          sendOrder: future.timeIntervalSinceReferenceDate, partIndex: index, partTotal: 3
        )
      }
      let logURL = Self.scratchLogURL()
      defer { try? FileManager.default.removeItem(at: logURL) }
      await MeetingWebhookDeliveryLog(fileURL: logURL).save(persisted, generation: 1)

      // The first send waits in backoff; the resend fails at part 1.
      let transport = EventScriptedTransport([.noteCompleted: [500], .noteResent: [400]])
      let gate = BackoffGate()
      let (center, store) = Self.scratchCenter(
        secrets: MeetingWebhookInMemorySecretStore(),
        transport: transport,
        sleeper: { _ in try await gate.wait() },
        logURL: logURL
      )
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      // Same main-actor turn as `init`: the async log load has not run yet.
      #expect(center.send(session, event: .noteCompleted) == 1)
      #expect(center.send(session, event: .noteResent, endpointIDs: [endpoint.id]) == 1)

      let resendFailed = await Self.waitUntil {
        let resent = center.deliveries.filter { $0.event == .noteResent }
        let loaded = center.deliveries.contains { $0.sendID == persistedSend }
        return loaded && !resent.isEmpty && resent.count == resent.first?.partTotal
          && resent.allSatisfy { $0.state == .failed }
      }
      #expect(resendFailed)
      gate.open()
      let olderDelivered = await Self.waitUntil {
        let older = center.deliveries.filter {
          $0.event == .noteCompleted && $0.sendID != persistedSend
        }
        return !older.isEmpty && older.count == older.first?.partTotal
          && older.allSatisfy { $0.state == .delivered }
      }
      #expect(olderDelivered)

      let noteStatus = try #require(center.latestRecords(forNote: session.id).first)
      #expect(noteStatus.event == .noteResent)
      #expect(noteStatus.state == .failed)
      let statusText = MeetingWebhookStatusFormatter.text(for: noteStatus)
      #expect(statusText.hasPrefix("Bot failed at part 1 of "))
      #expect(center.latestRecord(forEndpoint: endpoint.id)?.id == noteStatus.id)
      let olderOrder = center.deliveries
        .first { $0.event == .noteCompleted && $0.sendID != persistedSend }?.sendOrder ?? 0
      #expect(olderOrder > future.timeIntervalSinceReferenceDate)
      #expect((noteStatus.sendOrder ?? 0) > olderOrder)
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

/// Answers each request by its `X-WonderWhisper-Event`: the queued statuses for that event in
/// order, then 200. For tests where sends to the same endpoint race.
final class EventScriptedTransport: MeetingWebhookTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var scripts: [String: [Int]]

  init(_ scripts: [MeetingWebhookEvent: [Int]]) {
    self.scripts = Dictionary(uniqueKeysWithValues: scripts.map { ($0.key.rawValue, $0.value) })
  }

  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse {
    let event = request.value(forHTTPHeaderField: MeetingWebhookRequestBuilder.eventHeader) ?? ""
    let status: Int = lock.withLock {
      var queue = scripts[event] ?? []
      let next = queue.isEmpty ? 200 : queue.removeFirst()
      scripts[event] = queue
      return next
    }
    return MeetingWebhookTransportResponse(statusCode: status)
  }
}
