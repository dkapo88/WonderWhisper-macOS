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
  /// Running sends, keyed by send ID (one task delivers all parts of a send in order).
  private var tasks: [UUID: (endpointID: UUID, task: Task<Void, Never>)] = [:]
  /// Why a send was cancelled, keyed by send ID, so its final records say so.
  private var cancellationReasons: [UUID: String] = [:]
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
    tasks.values.forEach { $0.task.cancel() }
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

  /// The stored custom headers. Throws `MeetingWebhookCredentialsError` when the Keychain
  /// can't be read.
  func headers(for id: UUID) throws -> [String: String] {
    try store.headers(for: id)
  }

  /// Validates and saves an endpoint. Returns an error message, or nil on success. A nil
  /// `signingSecret` or `headers` leaves the stored value untouched.
  func saveEndpoint(
    _ endpoint: MeetingWebhookEndpoint,
    signingSecret: String?,
    headers: [String: String]?
  ) -> String? {
    if let message = MeetingWebhookURLValidator.validate(endpoint.url).message {
      return message
    }
    for name in (headers ?? [:]).keys {
      guard MeetingWebhookRequestBuilder.isValidHeaderName(name) else {
        return "\"\(name)\" is not a valid header name."
      }
      guard !MeetingWebhookRequestBuilder.isReservedHeader(name) else {
        return "\(name) is set by WonderWhisper and can't be overridden."
      }
    }
    let previous = endpoints.first { $0.id == endpoint.id }
    do {
      try store.upsert(endpoint, signingSecret: signingSecret, headers: headers)
    } catch {
      return "Could not save the webhook secrets: \(error.localizedDescription)"
    }
    reloadEndpoints()
    // Pending retries carry a copy of the old URL and credentials. Stop them when the endpoint
    // is switched off or pointed somewhere else, or its credentials change.
    if !endpoint.isEnabled {
      cancelDeliveries(for: endpoint.id, reason: Self.disabledReason)
    } else if let previous,
              previous.url != endpoint.url || signingSecret != nil || headers != nil {
      cancelDeliveries(for: endpoint.id, reason: Self.editedReason)
    }
    return nil
  }

  static let removedReason = "Cancelled: endpoint removed"
  static let disabledReason = "Cancelled: endpoint disabled"
  static let editedReason = "Cancelled: endpoint edited"

  /// Disabling cancels this endpoint's pending deliveries (queued or waiting to retry), so
  /// nothing more is sent to it. An attempt already on the wire is aborted too: the delivery
  /// records can't tell an in-flight retry from a waiting one, and stopping is the safe side.
  func setEnabled(_ isEnabled: Bool, for id: UUID) {
    store.setEnabled(isEnabled, for: id)
    reloadEndpoints()
    if !isEnabled {
      cancelDeliveries(for: id, reason: Self.disabledReason)
    }
  }

  /// Deleting cancels every pending delivery to the endpoint, so no further request goes out
  /// with its credentials.
  func deleteEndpoint(_ id: UUID) {
    cancelDeliveries(for: id, reason: Self.removedReason)
    store.delete(id)
    reloadEndpoints()
  }

  private func cancelDeliveries(for endpointID: UUID, reason: String) {
    for (sendID, entry) in tasks where entry.endpointID == endpointID {
      cancellationReasons[sendID] = reason
      entry.task.cancel()
    }
  }

  // MARK: - Sending

  /// Sends a finished note to the given endpoints (all enabled ones when nil). Returns the
  /// number of sends started (one per endpoint, however many parts each has).
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

  /// The record describing the endpoint's newest send (for a split send, its current or
  /// failed part, or the last part once all were delivered).
  func latestRecord(forEndpoint id: UUID) -> MeetingWebhookDeliveryRecord? {
    guard let newest = deliveries.first(where: { $0.endpointID == id }) else { return nil }
    return MeetingWebhookStatusFormatter.representative(
      of: deliveries.filter { $0.endpointID == id && $0.sendKey == newest.sendKey }
    )
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
    let sendID = UUID()
    let now = Date()
    let failure = { (message: String) in
      self.record(failure: message, sendID: sendID, endpoint: endpoint, session: session,
                  event: event, now: now)
    }
    guard let url = MeetingWebhookURLValidator.validate(endpoint.url).url else {
      failure("Invalid URL")
      return false
    }
    let payloads: [MeetingWebhookPayload]
    do {
      payloads = try payloadBuilder.payloads(
        for: session,
        event: event,
        endpoint: endpoint,
        sendID: sendID,
        sentAt: now
      )
    } catch let error as MeetingWebhookPayloadSplitter.SplitError {
      failure(error.message)
      return false
    } catch {
      failure("Could not build the payload")
      return false
    }
    let signingSecret: String?
    let customHeaders: [String: String]
    do {
      signingSecret = try store.signingSecret(for: endpoint.id)
      customHeaders = try store.headers(for: endpoint.id)
    } catch {
      // Never send without the endpoint's auth headers or signature.
      failure(MeetingWebhookCredentialsError.userMessage)
      return false
    }
    let jobs = payloads.enumerated().map { offset, payload in
      MeetingWebhookDeliveryJob(
        deliveryID: payload.deliveryId,
        sendID: sendID,
        partIndex: offset + 1,
        partTotal: payloads.count,
        endpoint: endpoint,
        url: url,
        event: event,
        noteID: session.id,
        noteTitle: session.title,
        body: MeetingWebhookPayloadBuilder.encode(payload),
        signingSecret: signingSecret,
        customHeaders: customHeaders,
        userAgent: payloadBuilder.appInfo.userAgent
      )
    }
    let service = deliveryService
    let task = Task.detached(priority: .utility) { [weak self] in
      let records = await service.deliverParts(jobs) { [weak self] record in
        await self?.apply(record)
      }
      await self?.finish(sendID: sendID, records: records)
    }
    tasks[sendID] = (endpoint.id, task)
    return true
  }

  private func record(
    failure message: String,
    sendID: UUID,
    endpoint: MeetingWebhookEndpoint,
    session: MeetingSession,
    event: MeetingWebhookEvent,
    now: Date
  ) {
    let failed = MeetingWebhookDeliveryRecord(
      id: sendID,
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
      updatedAt: now,
      sendID: sendID
    )
    apply(failed)
    finish(sendID: sendID, records: [failed])
  }

  private func apply(_ incoming: MeetingWebhookDeliveryRecord) {
    var record = incoming
    if record.state == .failed, let reason = cancellationReasons[record.sendKey] {
      record.lastError = reason
    }
    deliveries = MeetingWebhookDeliveryLog.upserting(record, into: deliveries)
    persistLog()
  }

  private func finish(sendID: UUID, records: [MeetingWebhookDeliveryRecord]) {
    tasks.removeValue(forKey: sendID)
    // A send the user cancelled (endpoint removed, disabled or edited) is not an error to
    // surface.
    let wasCancelledByUser = cancellationReasons.removeValue(forKey: sendID) != nil
    guard let failed = records.first(where: { $0.state == .failed }),
          failed.event != .test,
          !wasCancelledByUser else { return }
    let reason = MeetingWebhookStatusFormatter.failureReason(for: failed)
    if failed.isPartOfSplit, let index = failed.partIndex, let total = failed.partTotal {
      onFinalFailure?(
        "Webhook \(failed.endpointName) failed at part \(index) of \(total): \(reason)"
      )
    } else {
      onFinalFailure?("Webhook \(failed.endpointName) failed: \(reason)")
    }
  }

  private func persistLog() {
    logGeneration += 1
    let generation = logGeneration
    let snapshot = deliveries
    let log = log
    Task { await log.save(snapshot, generation: generation) }
  }
}
