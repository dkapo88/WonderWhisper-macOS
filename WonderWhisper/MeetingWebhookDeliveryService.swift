import Foundation
import OSLog

/// Delivers webhook jobs with retries and backoff. Each call is independent, so endpoints
/// never wait on each other. Transport, clock, sleeper and jitter are injected for tests.
actor MeetingWebhookDeliveryService {
  typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
  typealias Clock = @Sendable () -> Date
  typealias Jitter = @Sendable () -> Double
  typealias UpdateHandler = @Sendable (MeetingWebhookDeliveryRecord) async -> Void

  private let transport: MeetingWebhookTransport
  private let sleeper: Sleeper
  private let clock: Clock
  private let jitter: Jitter
  private let maximumAttempts: Int
  private let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "Webhooks")

  init(
    transport: MeetingWebhookTransport = MeetingWebhookURLSessionTransport(),
    maximumAttempts: Int = MeetingWebhookRetryPolicy.maximumAttempts,
    sleeper: @escaping Sleeper = { seconds in
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    clock: @escaping Clock = { Date() },
    jitter: @escaping Jitter = { Double.random(in: 0..<1) }
  ) {
    self.transport = transport
    self.maximumAttempts = max(1, maximumAttempts)
    self.sleeper = sleeper
    self.clock = clock
    self.jitter = jitter
  }

  /// Runs one delivery to completion, reporting every state change through `onUpdate`, and
  /// returns the final record (`delivered` or `failed`).
  func deliver(
    _ job: MeetingWebhookDeliveryJob,
    onUpdate: UpdateHandler = { _ in }
  ) async -> MeetingWebhookDeliveryRecord {
    let createdAt = clock()
    var record = MeetingWebhookDeliveryRecord(
      id: job.deliveryID,
      endpointID: job.endpoint.id,
      endpointName: job.endpoint.displayName,
      noteID: job.noteID,
      noteTitle: job.noteTitle,
      event: job.event,
      state: .sending,
      attempts: 0,
      maximumAttempts: maximumAttempts,
      lastStatusCode: nil,
      lastError: nil,
      createdAt: createdAt,
      updatedAt: createdAt,
      sendID: job.sendID,
      sendCreatedAt: job.sendCreatedAt ?? createdAt,
      partIndex: job.partIndex,
      partTotal: job.partTotal
    )
    await onUpdate(record)

    while true {
      if Task.isCancelled {
        return await finish(
          &record, state: .failed, error: Self.cancelledMessage, onUpdate: onUpdate
        )
      }
      record.attempts += 1
      let request = MeetingWebhookRequestBuilder.request(for: job, at: clock())
      var retryAfter: TimeInterval?
      do {
        let response = try await transport.send(request)
        record.lastStatusCode = response.statusCode
        switch MeetingWebhookRetryPolicy.outcome(forStatus: response.statusCode) {
        case .delivered:
          return await finish(&record, state: .delivered, error: nil, onUpdate: onUpdate)
        case .failed:
          return await finish(
            &record,
            state: .failed,
            error: Self.statusMessage(response.statusCode),
            onUpdate: onUpdate
          )
        case .retryable:
          record.lastError = Self.statusMessage(response.statusCode)
          retryAfter = MeetingWebhookRetryPolicy.retryAfterSeconds(
            response.retryAfter,
            now: clock()
          )
        }
      } catch {
        record.lastStatusCode = nil
        if MeetingWebhookRetryPolicy.isCancellation(error) {
          return await finish(
          &record, state: .failed, error: Self.cancelledMessage, onUpdate: onUpdate
        )
        }
        let message = error.localizedDescription
        guard MeetingWebhookRetryPolicy.shouldRetry(error) else {
          return await finish(&record, state: .failed, error: message, onUpdate: onUpdate)
        }
        record.lastError = message
      }

      guard record.attempts < maximumAttempts else {
        return await finish(&record, state: .failed, error: record.lastError, onUpdate: onUpdate)
      }
      let delay = MeetingWebhookRetryPolicy.delay(
        afterAttempt: record.attempts,
        retryAfter: retryAfter,
        jitter: jitter()
      )
      record.state = .retrying
      record.updatedAt = clock()
      let retryNote = "Webhook \(record.id.uuidString) attempt \(record.attempts) failed; "
        + "retrying in \(Int(delay))s"
      logger.log("\(retryNote, privacy: .public)")
      await onUpdate(record)
      do {
        try await sleeper(delay)
      } catch {
        return await finish(
          &record, state: .failed, error: Self.cancelledMessage, onUpdate: onUpdate
        )
      }
    }
  }

  static let cancelledMessage = "Cancelled"

  /// Delivers the parts of one send strictly in order: a part starts only after the previous
  /// one was delivered. Each part retries on its own. When a part fails for good the rest are
  /// not sent and are recorded as failed with "Skipped: part N failed"; when the send is
  /// cancelled they are recorded as cancelled. Returns one record per part, in order.
  func deliverParts(
    _ jobs: [MeetingWebhookDeliveryJob],
    onUpdate: UpdateHandler = { _ in }
  ) async -> [MeetingWebhookDeliveryRecord] {
    var records: [MeetingWebhookDeliveryRecord] = []
    for (offset, job) in jobs.enumerated() {
      if Task.isCancelled {
        let rest = jobs[offset...]
        return records + (await unsent(rest, reason: Self.cancelledMessage, onUpdate: onUpdate))
      }
      let record = await deliver(job, onUpdate: onUpdate)
      records.append(record)
      guard record.state == .delivered else {
        let reason = Task.isCancelled || record.lastError == Self.cancelledMessage
          ? Self.cancelledMessage
          : MeetingWebhookDeliveryRecord.skippedPrefix + "part \(job.partIndex) failed"
        let rest = jobs[(offset + 1)...]
        return records + (await unsent(rest, reason: reason, onUpdate: onUpdate))
      }
    }
    return records
  }

  /// Failed records for parts that were never attempted.
  private func unsent(
    _ jobs: ArraySlice<MeetingWebhookDeliveryJob>,
    reason: String,
    onUpdate: UpdateHandler
  ) async -> [MeetingWebhookDeliveryRecord] {
    var records: [MeetingWebhookDeliveryRecord] = []
    for job in jobs {
      let now = clock()
      let record = MeetingWebhookDeliveryRecord(
        id: job.deliveryID,
        endpointID: job.endpoint.id,
        endpointName: job.endpoint.displayName,
        noteID: job.noteID,
        noteTitle: job.noteTitle,
        event: job.event,
        state: .failed,
        attempts: 0,
        maximumAttempts: maximumAttempts,
        lastStatusCode: nil,
        lastError: reason,
        createdAt: now,
        updatedAt: now,
        sendID: job.sendID,
        sendCreatedAt: job.sendCreatedAt ?? now,
        partIndex: job.partIndex,
        partTotal: job.partTotal
      )
      await onUpdate(record)
      records.append(record)
    }
    return records
  }

  private func finish(
    _ record: inout MeetingWebhookDeliveryRecord,
    state: MeetingWebhookDeliveryRecord.State,
    error: String?,
    onUpdate: UpdateHandler
  ) async -> MeetingWebhookDeliveryRecord {
    record.state = state
    record.lastError = state == .delivered ? nil : (error ?? "Delivery failed")
    record.updatedAt = clock()
    let status = record.lastStatusCode.map(String.init) ?? "none"
    let summary = "Webhook \(record.id.uuidString) \(state.rawValue) after "
      + "\(record.attempts) attempt(s), status \(status)"
    logger.log("\(summary, privacy: .public)")
    let final = record
    await onUpdate(final)
    return final
  }

  static func statusMessage(_ status: Int) -> String {
    if (300...399).contains(status) {
      return "HTTP \(status) (redirects are not followed)"
    }
    return "HTTP \(status)"
  }
}
