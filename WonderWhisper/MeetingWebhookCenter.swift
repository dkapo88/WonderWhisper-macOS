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
  /// Running or queued sends, keyed by run ID (one task delivers the parts of one send, or of
  /// one partial resend, in order). A partial resend reuses its send's ID, so runs have their
  /// own IDs; a normal send's run ID is its send ID.
  private var tasks: [UUID: (endpointID: UUID, task: Task<Void, Never>)] = [:]
  /// Why a run was cancelled, keyed by run ID, so its final records say so.
  private var cancellationReasons: [UUID: String] = [:]
  /// Paced (split) runs per endpoint, in the order they will send: the first is running.
  private var endpointQueues: [UUID: [UUID]] = [:]
  /// The last paced run enqueued per endpoint; the next one waits for it.
  private var endpointTails: [UUID: Task<Void, Never>] = [:]
  /// Unpaced (unsplit) runs per endpoint that are still running. A paced run waits for them,
  /// so turning splitting on never lets a paced request overlap an unsplit one.
  private var unpacedRuns: [UUID: Set<UUID>] = [:]
  /// The delivery IDs of each waiting run, to keep its queued records' positions current.
  private var runDeliveryIDs: [UUID: [UUID]] = [:]
  /// The runs each waiting run is queued behind ("behind N notes" counts those still running).
  private var runAhead: [UUID: Set<UUID>] = [:]
  private var logGeneration = 0
  /// The last send ordering key issued; see `nextSendOrder(at:)`. Seeded in `init` from the
  /// persisted log, before any send can be enqueued, so a key issued before the async log load
  /// finishes still ranks above every persisted send (even after the clock went backwards).
  private var lastSendOrder: Double

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
    lastSendOrder = log.highestPersistedSendOrder() ?? -Double.greatestFiniteMagnitude
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
      // Keep new sends ordered after any loaded ones, even if the clock went backwards.
      if let loadedMax = merged.compactMap(\.sendOrder).max() {
        lastSendOrder = max(lastSendOrder, loadedMax)
      }
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

  /// Cancels every running and queued run to the endpoint; queued ones end as cancelled
  /// without sending.
  private func cancelDeliveries(for endpointID: UUID, reason: String) {
    for (runID, entry) in tasks where entry.endpointID == endpointID {
      cancellationReasons[runID] = reason
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

  // MARK: - Partial resend

  /// Which parts of the newest split send a partial resend sends again.
  enum PartSelection: Equatable, Sendable {
    /// Every part whose newest record is not delivered (failed, skipped, interrupted).
    case missing
    /// These part numbers, delivered or not.
    case parts([Int])
  }

  enum ResendOutcome: Equatable, Sendable {
    case started(parts: [Int])
    case refused(String)
  }

  /// The newest split send of the note to the endpoint, if any.
  func resumableSend(noteID: UUID, endpointID: UUID) -> MeetingWebhookResumableSend? {
    MeetingWebhookResumableSend.latest(in: deliveries, noteID: noteID, endpointID: endpointID)
  }

  /// Sends some parts of the newest split send of `session` to the endpoint again, reusing its
  /// `sendId`, part numbering and total (each part gets a new `deliveryId`), so the receiver
  /// can complete the original set. Refuses, without sending anything, when the note or the
  /// endpoint's split settings changed since that send, so the parts would not match.
  func resendParts(
    _ session: MeetingSession,
    endpointID: UUID,
    selection: PartSelection
  ) -> ResendOutcome {
    guard let endpoint = endpoint(withID: endpointID) else {
      return .refused("That webhook no longer exists.")
    }
    let name = endpoint.displayName
    guard let send = resumableSend(noteID: session.id, endpointID: endpointID) else {
      return .refused("This note has no split send to \(name) to resume; use Send to Webhook.")
    }
    guard !send.isInFlight else {
      return .refused("The last send to \(name) is still in progress.")
    }
    guard let reference = send.splitRecord,
          let fingerprint = reference.contentFingerprint,
          let content = reference.content,
          let maxBody = reference.maxBodyCharacters,
          let chunkBudget = reference.chunkBudget else {
      return .refused("That send was made by an older version of WonderWhisper; use Send to "
        + "Webhook to send all parts again.")
    }
    let indexes: [Int]
    switch selection {
    case .missing:
      indexes = send.missingIndexes
      guard !indexes.isEmpty else {
        return .refused("Every part reached \(name). Use Resend Parts to send specific parts "
          + "again.")
      }
    case let .parts(requested):
      indexes = Array(Set(requested)).sorted()
      guard !indexes.isEmpty, indexes.allSatisfy({ (1...send.total).contains($0) }) else {
        return .refused("Part numbers must be between 1 and \(send.total).")
      }
    }
    let changed = MeetingWebhookPayloadSplitter.ResendError.noteChanged.message
    guard endpoint.splitIntoParts,
          endpoint.content == content,
          MeetingWebhookEndpoint.clampedMaxBody(endpoint.maxBodyCharacters) == maxBody else {
      return .refused("The webhook's split settings changed since the note was sent; use Send "
        + "to Webhook to send all parts again.")
    }
    guard let url = MeetingWebhookURLValidator.validate(endpoint.url).url else {
      return .refused("Invalid URL")
    }
    let now = Date()
    let base = payloadBuilder.payload(
      for: session,
      event: .noteResent,
      deliveryID: UUID(),
      sentAt: now,
      content: content
    )
    guard MeetingWebhookFingerprint.of(base.note.markdown) == fingerprint else {
      return .refused(changed)
    }
    let rebuilt: (parts: [MeetingWebhookPayload], chunks: [String])
    do {
      rebuilt = try MeetingWebhookPayloadSplitter.resend(
        of: base,
        sendID: send.sendID,
        chunkBudget: chunkBudget,
        total: send.total,
        indexes: indexes,
        maxBytes: maxBody
      )
    } catch let error as MeetingWebhookPayloadSplitter.ResendError {
      return .refused(error.message)
    } catch {
      return .refused(changed)
    }
    let partFingerprints = rebuilt.chunks.map(MeetingWebhookFingerprint.of)
    for (index, record) in send.partRecords {
      guard let stored = record.partFingerprint else { continue }
      guard partFingerprints.indices.contains(index - 1),
            partFingerprints[index - 1] == stored else {
        return .refused(changed)
      }
    }
    guard let credentials = credentials(for: endpoint) else {
      return .refused(MeetingWebhookCredentialsError.userMessage)
    }
    let info = MeetingWebhookSplitInfo(
      contentFingerprint: fingerprint,
      content: content,
      maxBodyCharacters: maxBody,
      chunkBudget: chunkBudget,
      partFingerprints: partFingerprints
    )
    let sendOrder = nextSendOrder(at: now)
    let jobs = rebuilt.parts.map { payload in
      MeetingWebhookDeliveryJob(
        deliveryID: payload.deliveryId,
        sendID: send.sendID,
        sendCreatedAt: now,
        sendOrder: sendOrder,
        partIndex: payload.part?.index ?? 1,
        partTotal: send.total,
        endpoint: endpoint,
        url: url,
        event: .noteResent,
        noteID: session.id,
        noteTitle: session.title,
        body: MeetingWebhookPayloadBuilder.encode(payload),
        signingSecret: credentials.secret,
        customHeaders: credentials.headers,
        userAgent: payloadBuilder.appInfo.userAgent,
        pacing: endpoint.pacing,
        splitInfo: info
      )
    }
    start(jobs, runID: UUID(), endpointID: endpoint.id, at: now)
    return .started(parts: indexes)
  }

  /// The record describing the endpoint's newest send (for a split send, its current or
  /// failed part, or the last part once all were delivered).
  func latestRecord(forEndpoint id: UUID) -> MeetingWebhookDeliveryRecord? {
    MeetingWebhookStatusFormatter.latestSend(in: deliveries.filter { $0.endpointID == id })
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
    let sendOrder = nextSendOrder(at: now)
    let failure = { (message: String) in
      self.record(failure: message, sendID: sendID, sendOrder: sendOrder, endpoint: endpoint,
                  session: session, event: event, now: now)
    }
    guard let url = MeetingWebhookURLValidator.validate(endpoint.url).url else {
      failure("Invalid URL")
      return false
    }
    let plan: MeetingWebhookSendPlan
    do {
      plan = try payloadBuilder.plan(
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
    guard let credentials = credentials(for: endpoint) else {
      // Never send without the endpoint's auth headers or signature.
      failure(MeetingWebhookCredentialsError.userMessage)
      return false
    }
    let total = plan.payloads.count
    let jobs = plan.payloads.enumerated().map { offset, payload in
      MeetingWebhookDeliveryJob(
        deliveryID: payload.deliveryId,
        sendID: sendID,
        sendCreatedAt: now,
        sendOrder: sendOrder,
        partIndex: payload.part?.index ?? offset + 1,
        partTotal: payload.part?.total ?? total,
        endpoint: endpoint,
        url: url,
        event: event,
        noteID: session.id,
        noteTitle: session.title,
        body: MeetingWebhookPayloadBuilder.encode(payload),
        signingSecret: credentials.secret,
        customHeaders: credentials.headers,
        userAgent: payloadBuilder.appInfo.userAgent,
        pacing: endpoint.pacing,
        splitInfo: plan.split
      )
    }
    start(jobs, runID: sendID, endpointID: endpoint.id, at: now)
    return true
  }

  private func credentials(
    for endpoint: MeetingWebhookEndpoint
  ) -> (secret: String?, headers: [String: String])? {
    do {
      return (try store.signingSecret(for: endpoint.id), try store.headers(for: endpoint.id))
    } catch {
      return nil
    }
  }

  /// Runs the jobs of one send (or partial resend) in the background. Paced jobs wait for
  /// every earlier run to the endpoint that is still going (paced or not), so at most one
  /// request is in flight per endpoint, and are shown as queued until their turn. Unpaced
  /// jobs start at once and run alongside each other, as before; they only wait (shown as
  /// queued) when paced work for the endpoint is queued or running, which happens only after
  /// splitting was switched on or off with sends in flight.
  private func start(
    _ jobs: [MeetingWebhookDeliveryJob],
    runID: UUID,
    endpointID: UUID,
    at now: Date
  ) {
    let service = deliveryService
    let isPaced = jobs.first?.pacing != nil
    let pacedQueue = endpointQueues[endpointID] ?? []
    let pacedTail = endpointTails[endpointID]
    let running = unpacedRuns[endpointID] ?? []
    let unpacedTasks = isPaced ? running.compactMap { tasks[$0]?.task } : []
    let ahead = Set(pacedQueue).union(isPaced ? running : [])
    // Paced runs record every part as queued up front (so parts never reached after a quit
    // show up as interrupted); unpaced runs only when they actually have to wait.
    if isPaced || !ahead.isEmpty {
      runAhead[runID] = ahead
      runDeliveryIDs[runID] = jobs.map(\.deliveryID)
      for job in jobs {
        var queued = MeetingWebhookDeliveryRecord(
          job: job,
          state: .queued,
          maximumAttempts: MeetingWebhookRetryPolicy.maximumAttempts,
          at: now
        )
        queued.queuedBehind = ahead.isEmpty ? nil : ahead.count
        apply(queued, runID: runID)
      }
    }
    let task = Task.detached(priority: .utility) { [weak self] in
      // Cancelling an endpoint cancels every run to it, so these waits end promptly too.
      await pacedTail?.value
      for earlier in unpacedTasks {
        await earlier.value
      }
      let records = await service.deliverParts(jobs) { [weak self] record in
        await self?.apply(record, runID: runID)
      }
      await self?.finish(runID: runID, endpointID: endpointID, records: records)
    }
    tasks[runID] = (endpointID, task)
    if isPaced {
      endpointQueues[endpointID, default: []].append(runID)
      endpointTails[endpointID] = task
    } else {
      unpacedRuns[endpointID, default: []].insert(runID)
    }
  }

  /// A send ordering key: the time in seconds since the reference date, bumped so every key
  /// is strictly greater than the last one issued (and than every loaded one).
  private func nextSendOrder(at date: Date) -> Double {
    let order = max(date.timeIntervalSinceReferenceDate, lastSendOrder.nextUp)
    lastSendOrder = order
    return order
  }

  private func record(
    failure message: String,
    sendID: UUID,
    sendOrder: Double,
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
      sendID: sendID,
      sendCreatedAt: now,
      sendOrder: sendOrder
    )
    apply(failed, runID: sendID)
    finish(runID: sendID, endpointID: endpoint.id, records: [failed])
  }

  private func apply(_ incoming: MeetingWebhookDeliveryRecord, runID: UUID) {
    var record = incoming
    if record.state == .failed, let reason = cancellationReasons[runID] {
      record.lastError = reason
    }
    deliveries = MeetingWebhookDeliveryLog.upserting(record, into: deliveries)
    persistLog()
  }

  private func finish(runID: UUID, endpointID: UUID, records: [MeetingWebhookDeliveryRecord]) {
    tasks.removeValue(forKey: runID)
    runDeliveryIDs.removeValue(forKey: runID)
    runAhead.removeValue(forKey: runID)
    if var queue = endpointQueues[endpointID] {
      queue.removeAll { $0 == runID }
      if queue.isEmpty {
        endpointQueues.removeValue(forKey: endpointID)
        endpointTails.removeValue(forKey: endpointID)
      } else {
        endpointQueues[endpointID] = queue
      }
    }
    if var running = unpacedRuns[endpointID] {
      running.remove(runID)
      unpacedRuns[endpointID] = running.isEmpty ? nil : running
    }
    refreshQueuePositions()
    // A send the user cancelled (endpoint removed, disabled or edited) is not an error to
    // surface.
    let wasCancelledByUser = cancellationReasons.removeValue(forKey: runID) != nil
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

  /// Updates "behind N notes" on the queued records of waiting runs: the runs each one waits
  /// for that are still going.
  private func refreshQueuePositions() {
    var changed = false
    for (runID, ahead) in runAhead {
      let remaining = ahead.filter { tasks[$0] != nil }
      runAhead[runID] = remaining
      let behind = remaining.isEmpty ? nil : remaining.count
      for deliveryID in runDeliveryIDs[runID] ?? [] {
        guard let index = deliveries.firstIndex(where: { $0.id == deliveryID }),
              deliveries[index].state == .queued,
              deliveries[index].queuedBehind != behind else { continue }
        deliveries[index].queuedBehind = behind
        changed = true
      }
    }
    if changed { persistLog() }
  }

  private func persistLog() {
    logGeneration += 1
    let generation = logGeneration
    let snapshot = deliveries
    let log = log
    Task { await log.save(snapshot, generation: generation) }
  }
}
