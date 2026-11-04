import Foundation
import Testing
@testable import WonderWhisper

/// "Only send meetings I select" webhooks: a note leaves through such an endpoint only when the
/// user selected the meeting for it. Uses the scratch `AppConfig.defaults` suite, scratch app
/// support and an in-memory secret store: never the real prefs or Keychain. Every meeting here
/// is synthetic.
@Suite(.serialized)
struct MeetingWebhookSelectionTests {
  private static let regularURL = "https://regular.example.com/hook"
  private static let optInURL = "https://optin.example.com/hook"

  private static func scratchCenter(
    transport: MeetingWebhookTransport,
    sleeper: @escaping MeetingWebhookDeliveryService.Sleeper = { _ in }
  ) -> (MeetingWebhookCenter, MeetingWebhookEndpointStore) {
    let store = MeetingWebhookEndpointStore(
      defaults: { AppConfig.defaults },
      secrets: MeetingWebhookInMemorySecretStore()
    )
    let service = MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: sleeper,
      jitter: { 0 }
    )
    let logURL = AppStoragePaths.appSupportRoot()
      .appendingPathComponent("webhook-selection-log-\(UUID().uuidString).json")
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

  @MainActor
  private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  private static func syntheticSession(
    title: String = "SYNTHETIC meeting",
    selected: [UUID] = []
  ) -> MeetingSession {
    MeetingSession(
      title: title,
      endedAt: Date(),
      recordedDuration: 60,
      status: .completed,
      notesMarkdown: "## Summary\n\nSynthetic test note. No real meeting content.",
      selectedWebhookEndpointIDs: selected
    )
  }

  private static func optInEndpoint() -> MeetingWebhookEndpoint {
    MeetingWebhookEndpoint(name: "Glofox", url: optInURL, onlySelectedMeetings: true)
  }

  private static func bodyJSON(_ request: URLRequest) -> [String: Any]? {
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  // MARK: - Defaults and decoding

  @Test func newEndpointsAndMeetingsDefaultToNotSelected() {
    #expect(!MeetingWebhookEndpoint().onlySelectedMeetings)
    #expect(MeetingSession(title: "Meeting").selectedWebhookEndpointIDs.isEmpty)
  }

  @Test func endpointsSavedByOlderBuildsKeepSendingEveryNote() throws {
    let json = """
    {"id":"11111111-2222-3333-4444-555555555555","name":"Bot","url":"https://example.com/h",
    "isEnabled":true,"headerNames":[],"hasSecret":false}
    """
    let endpoint = try JSONDecoder().decode(MeetingWebhookEndpoint.self, from: Data(json.utf8))
    #expect(!endpoint.onlySelectedMeetings)
    #expect(endpoint.accepts(Self.syntheticSession()))
  }

  @Test func optInFlagAndSelectionRoundTrip() throws {
    let endpoint = Self.optInEndpoint()
    let decodedEndpoint = try JSONDecoder().decode(
      MeetingWebhookEndpoint.self,
      from: JSONEncoder().encode(endpoint)
    )
    #expect(decodedEndpoint.onlySelectedMeetings)

    let session = Self.syntheticSession(selected: [endpoint.id])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedSession = try decoder.decode(MeetingSession.self, from: encoder.encode(session))
    #expect(decodedSession.selectedWebhookEndpointIDs == [endpoint.id])
  }

  @Test func meetingsSavedBeforeSelectionExistedAreNotSelected() throws {
    let session = Self.syntheticSession(selected: [UUID()])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any]
    )
    object.removeValue(forKey: "selectedWebhookEndpointIDs")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let old = try decoder.decode(
      MeetingSession.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(old.selectedWebhookEndpointIDs.isEmpty)
    #expect(!Self.optInEndpoint().accepts(old))
  }

  @Test func onlyTheExactEndpointSelectionCounts() {
    let endpoint = Self.optInEndpoint()
    #expect(!endpoint.accepts(Self.syntheticSession()))
    #expect(!endpoint.accepts(Self.syntheticSession(selected: [UUID()])))
    #expect(endpoint.accepts(Self.syntheticSession(selected: [endpoint.id])))
    // The title is never used to decide.
    #expect(!endpoint.accepts(Self.syntheticSession(title: "Glofox roadmap sync")))
  }

  @Test func completionUsesTheLiveSelection() {
    let endpointID = UUID()
    let stale = Self.syntheticSession(selected: [endpointID])
    var live = stale
    live.selectedWebhookEndpointIDs = []
    #expect(MeetingCoordinator.withLiveWebhookSelection(stale, live: live)
      .selectedWebhookEndpointIDs.isEmpty)
    #expect(MeetingCoordinator.withLiveWebhookSelection(stale, live: nil)
      .selectedWebhookEndpointIDs.isEmpty)
    var selectedLater = Self.syntheticSession()
    let staleUnselected = selectedLater
    selectedLater.selectedWebhookEndpointIDs = [endpointID]
    #expect(MeetingCoordinator.withLiveWebhookSelection(staleUnselected, live: selectedLater)
      .selectedWebhookEndpointIDs == [endpointID])
  }

  // MARK: - Sending

  @MainActor
  @Test func unselectedMeetingsNeverReachAnOptInEndpoint() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([])
      let (center, store) = Self.scratchCenter(transport: transport)
      let regular = MeetingWebhookEndpoint(name: "Regular", url: Self.regularURL)
      let optIn = Self.optInEndpoint()
      try store.upsert(regular, signingSecret: nil, headers: [:])
      try store.upsert(optIn, signingSecret: nil, headers: ["Authorization": "Bearer synthetic"])
      center.reloadEndpoints()

      let personal = Self.syntheticSession(title: "SYNTHETIC personal meeting")
      let otherProject = Self.syntheticSession(title: "SYNTHETIC Glofox-sounding other project")
      #expect(center.send(personal, event: .noteCompleted) == 1)
      #expect(center.send(otherProject, event: .noteCompleted) == 1)
      // A manual send aimed only at the opt-in endpoint starts nothing.
      #expect(center.send(personal, event: .noteResent, endpointIDs: [optIn.id]) == 0)
      // "All Enabled Webhooks" skips it too.
      #expect(center.send(otherProject, event: .noteResent) == 1)

      let done = await Self.waitUntil {
        transport.requests.count == 3
          && center.deliveries.allSatisfy { $0.state == .delivered }
      }
      #expect(done)
      try? await Task.sleep(nanoseconds: 50_000_000)
      #expect(transport.requests.count == 3)
      #expect(transport.requests.allSatisfy { $0.url?.absoluteString == Self.regularURL })
      #expect(!center.deliveries.contains { $0.endpointID == optIn.id })

      // Partial resend refuses without sending.
      let outcome = center.resendParts(personal, endpointID: optIn.id, selection: .missing)
      #expect(outcome == .refused(MeetingWebhookCenter.notSelectedMessage("Glofox")))
      #expect(transport.requests.count == 3)
      center.deleteEndpoint(regular.id)
      center.deleteEndpoint(optIn.id)
    }
  }

  @MainActor
  @Test func aSelectedMeetingIsSentAndRetriesKeepItsIdentity() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(503), .status(500), .status(202)])
      let (center, store) = Self.scratchCenter(transport: transport)
      let optIn = Self.optInEndpoint()
      try store.upsert(optIn, signingSecret: nil, headers: ["Authorization": "Bearer synthetic"])
      center.reloadEndpoints()
      let session = Self.syntheticSession(selected: [optIn.id])

      #expect(center.send(session, event: .noteCompleted) == 1)
      let delivered = await Self.waitUntil {
        center.deliveries.first?.state == .delivered
      }
      #expect(delivered)
      let requests = transport.requests
      #expect(requests.count == 3)
      let bodies = requests.compactMap(Self.bodyJSON)
      let deliveryIDs = Set(bodies.compactMap { $0["deliveryId"] as? String })
      let noteIDs = Set(bodies.compactMap { ($0["note"] as? [String: Any])?["id"] as? String })
      let idempotency = Set(requests.compactMap {
        $0.value(forHTTPHeaderField: MeetingWebhookRequestBuilder.idempotencyHeader)
      })
      #expect(deliveryIDs.count == 1)
      #expect(idempotency == deliveryIDs)
      #expect(noteIDs == [session.id.uuidString])
      #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic"
      })
      center.deleteEndpoint(optIn.id)
    }
  }

  @MainActor
  @Test func deselectingDuringARetryStopsFurtherRequests() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
      let (center, store) = Self.scratchCenter(
        transport: transport,
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let optIn = Self.optInEndpoint()
      try store.upsert(optIn, signingSecret: nil, headers: [:])
      center.reloadEndpoints()
      let session = Self.syntheticSession(selected: [optIn.id])
      let other = Self.syntheticSession(selected: [optIn.id])
      var surfaced: String?
      center.onFinalFailure = { surfaced = $0 }

      #expect(center.send(session, event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)

      // Another note's run is untouched.
      center.cancelDeliveries(noteID: other.id, endpointID: optIn.id)
      #expect(center.deliveries.first?.state == .retrying)

      center.cancelDeliveries(noteID: session.id, endpointID: optIn.id)
      let ended = await Self.waitUntil { center.deliveries.first?.state == .failed }
      #expect(ended)
      #expect(center.deliveries.first?.lastError == MeetingWebhookCenter.deselectedReason)
      #expect(transport.requests.count == 1)
      #expect(surfaced == nil)
      center.deleteEndpoint(optIn.id)
    }
  }

  @MainActor
  @Test func switchingOnOnlySelectedMeetingsStopsPendingSends() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([.status(500), .status(200)])
      let (center, store) = Self.scratchCenter(
        transport: transport,
        sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
      )
      let endpoint = MeetingWebhookEndpoint(name: "Glofox", url: Self.optInURL)
      try store.upsert(endpoint, signingSecret: nil, headers: [:])
      center.reloadEndpoints()

      #expect(center.send(Self.syntheticSession(), event: .noteCompleted) == 1)
      let backingOff = await Self.waitUntil { center.deliveries.first?.state == .retrying }
      #expect(backingOff)

      var restricted = endpoint
      restricted.onlySelectedMeetings = true
      #expect(center.saveEndpoint(restricted, signingSecret: nil, headers: nil) == nil)
      let ended = await Self.waitUntil { center.deliveries.first?.state == .failed }
      #expect(ended)
      #expect(center.deliveries.first?.lastError == MeetingWebhookCenter.editedReason)
      #expect(transport.requests.count == 1)
      #expect(center.endpoint(withID: endpoint.id)?.onlySelectedMeetings == true)
      center.deleteEndpoint(endpoint.id)
    }
  }

  @MainActor
  @Test func sendTestStillReachesAnOptInEndpoint() async throws {
    try await Self.withScratchEndpoints {
      let transport = FakeMeetingWebhookTransport([])
      let (center, store) = Self.scratchCenter(transport: transport)
      let optIn = Self.optInEndpoint()
      try store.upsert(optIn, signingSecret: nil, headers: [:])
      center.reloadEndpoints()

      center.sendTest(to: optIn.id)
      let delivered = await Self.waitUntil { center.deliveries.first?.state == .delivered }
      #expect(delivered)
      #expect(transport.requests.count == 1)
      #expect(transport.requests.first?.value(
        forHTTPHeaderField: MeetingWebhookRequestBuilder.eventHeader
      ) == MeetingWebhookEvent.test.rawValue)
      center.deleteEndpoint(optIn.id)
    }
  }
}
