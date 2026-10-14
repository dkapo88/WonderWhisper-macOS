import Combine
import Foundation

/// Owns webhook endpoints, sends meeting notes to them in the background, and keeps the
/// delivery log the meeting detail view and Settings show. `MeetingCoordinator` triggers
/// sends; nothing here waits on or delays meeting finalization.
@MainActor
final class MeetingWebhookCenter: ObservableObject {
  @Published private(set) var endpoints: [MeetingWebhookEndpoint] = []
  @Published private(set) var deliveries: [MeetingWebhookDeliveryRecord] = []

  /// Called with a user-facing message when a delivery finally fails.
  var onFinalFailure: ((String) -> Void)?

  private let store: MeetingWebhookEndpointStore
  private let deliveryService: MeetingWebhookDeliveryService
  private let log: MeetingWebhookDeliveryLog
  private let payloadBuilder: MeetingWebhookPayloadBuilder
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var logGeneration = 0

  init(
    store: MeetingWebhookEndpointStore = .live(),
    deliveryService: MeetingWebhookDeliveryService = MeetingWebhookDeliveryService(),
    log: MeetingWebhookDeliveryLog = MeetingWebhookDeliveryLog(),
    payloadBuilder: MeetingWebhookPayloadBuilder = MeetingWebhookPayloadBuilder()
  ) {
    self.store = store
    self.deliveryService = deliveryService
    self.log = log
    self.payloadBuilder = payloadBuilder
    endpoints = store.load()
    Task { [weak self] in
      guard let self else { return }
      let loaded = await log.load()
      // Updates that arrived while loading are newer than the file: keep them.
      var merged = loaded
      for record in deliveries.reversed() {
        merged = MeetingWebhookDeliveryLog.upserting(record, into: merged)
      }
      deliveries = merged
      if merged != loaded { persistLog() }
    }
  }

  deinit {
    tasks.values.forEach { $0.cancel() }
  }

  var enabledEndpoints: [MeetingWebhookEndpoint] {
    endpoints.filter(\.isEnabled)
  }

  func endpoint(withID id: UUID) -> MeetingWebhookEndpoint? {
    endpoints.first { $0.id == id }
  }

  // MARK: - Endpoints

  func reloadEndpoints() {
    endpoints = store.load()
  }

  func headers(for id: UUID) -> [String: String] {
    store.headers(for: id)
  }

  /// Validates and saves an endpoint. Returns an error message, or nil on success.
  func saveEndpoint(
    _ endpoint: MeetingWebhookEndpoint,
    signingSecret: String?,
    headers: [String: String]
  ) -> String? {
    if let message = MeetingWebhookURLValidator.validate(endpoint.url).message {
      return message
    }
    for name in headers.keys {
      guard MeetingWebhookRequestBuilder.isValidHeaderName(name) else {
        return "\"\(name)\" is not a valid header name."
      }
      guard !MeetingWebhookRequestBuilder.isReservedHeader(name) else {
        return "\(name) is set by WonderWhisper and can't be overridden."
      }
    }
    do {
      try store.upsert(endpoint, signingSecret: signingSecret, headers: headers)
    } catch {
      return "Could not save the webhook secrets: \(error.localizedDescription)"
    }
    reloadEndpoints()
    return nil
  }

  func setEnabled(_ isEnabled: Bool, for id: UUID) {
    store.setEnabled(isEnabled, for: id)
    reloadEndpoints()
  }

  func deleteEndpoint(_ id: UUID) {
    store.delete(id)
    reloadEndpoints()
  }

  // MARK: - Sending

  /// Sends a finished note to the given endpoints (all enabled ones when nil). Returns the
  /// number of deliveries started.
  @discardableResult
  func send(
    _ session: MeetingSession,
    event: MeetingWebhookEvent,
    endpointIDs: [UUID]? = nil
  ) -> Int {
    let targets: [MeetingWebhookEndpoint]
    if let endpointIDs {
      targets = endpoints.filter { endpointIDs.contains($0.id) }
    } else {
      targets = enabledEndpoints
    }
    var started = 0
    for endpoint in targets where enqueue(session, event: event, endpoint: endpoint) {
      started += 1
    }
    return started
  }

  func sendTest(to endpointID: UUID) {
    guard let endpoint = endpoint(withID: endpointID) else { return }
    enqueue(MeetingWebhookPayloadBuilder.sampleSession(), event: .test, endpoint: endpoint)
  }

  func latestRecord(forEndpoint id: UUID) -> MeetingWebhookDeliveryRecord? {
    deliveries.first { $0.endpointID == id }
  }

  func latestRecords(forNote noteID: UUID) -> [MeetingWebhookDeliveryRecord] {
    MeetingWebhookStatusFormatter.latestPerEndpoint(deliveries, noteID: noteID)
  }

  @discardableResult
  private func enqueue(
    _ session: MeetingSession,
    event: MeetingWebhookEvent,
    endpoint: MeetingWebhookEndpoint
  ) -> Bool {
    let deliveryID = UUID()
    let now = Date()
    guard let url = MeetingWebhookURLValidator.validate(endpoint.url).url else {
      record(failure: "Invalid URL", deliveryID: deliveryID, endpoint: endpoint,
             session: session, event: event, now: now)
      return false
    }
    let payload = payloadBuilder.payload(
      for: session,
      event: event,
      deliveryID: deliveryID,
      sentAt: now
    )
    let body: Data
    do {
      body = try MeetingWebhookPayloadBuilder.encode(payload)
    } catch {
      record(failure: "Could not encode the payload", deliveryID: deliveryID,
             endpoint: endpoint, session: session, event: event, now: now)
      return false
    }
    let job = MeetingWebhookDeliveryJob(
      deliveryID: deliveryID,
      endpoint: endpoint,
      url: url,
      event: event,
      noteID: session.id,
      noteTitle: session.title,
      body: body,
      signingSecret: store.signingSecret(for: endpoint.id),
      customHeaders: store.headers(for: endpoint.id),
      userAgent: payloadBuilder.appInfo.userAgent
    )
    let service = deliveryService
    tasks[deliveryID] = Task.detached(priority: .utility) { [weak self] in
      let final = await service.deliver(job) { [weak self] record in
        await self?.apply(record)
      }
      await self?.finish(final)
    }
    return true
  }

  private func record(
    failure message: String,
    deliveryID: UUID,
    endpoint: MeetingWebhookEndpoint,
    session: MeetingSession,
    event: MeetingWebhookEvent,
    now: Date
  ) {
    let failed = MeetingWebhookDeliveryRecord(
      id: deliveryID,
      endpointID: endpoint.id,
      endpointName: endpoint.displayName,
      noteID: session.id,
      noteTitle: session.title,
      event: event,
      state: .failed,
      attempts: 0,
      maximumAttempts: MeetingWebhookRetryPolicy.maximumAttempts,
      lastStatusCode: nil,
      lastError: message,
      createdAt: now,
      updatedAt: now
    )
    apply(failed)
    finish(failed)
  }

  private func apply(_ record: MeetingWebhookDeliveryRecord) {
    deliveries = MeetingWebhookDeliveryLog.upserting(record, into: deliveries)
    persistLog()
  }

  private func finish(_ record: MeetingWebhookDeliveryRecord) {
    tasks.removeValue(forKey: record.id)
    guard record.state == .failed, record.event != .test else { return }
    let reason = MeetingWebhookStatusFormatter.failureReason(for: record)
    onFinalFailure?("Webhook \(record.endpointName) failed: \(reason)")
  }

  private func persistLog() {
    logGeneration += 1
    let generation = logGeneration
    let snapshot = deliveries
    let log = log
    Task { await log.save(snapshot, generation: generation) }
  }
}
