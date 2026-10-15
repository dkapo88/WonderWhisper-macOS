import Foundation

/// One delivery of one note (or one part of it) to one endpoint, as shown in the meeting
/// detail view and the Settings log. Never holds request bodies, secrets or header values.
struct MeetingWebhookDeliveryRecord: Codable, Identifiable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    /// Waiting its turn: behind earlier sends to the endpoint, the gap between notes, or the
    /// delay between parts.
    case queued
    case sending
    case retrying
    case delivered
    case failed

    var isInFlight: Bool { self == .queued || self == .sending || self == .retrying }
  }

  /// The delivery ID, reused across retries (`X-WonderWhisper-Delivery`).
  let id: UUID
  let endpointID: UUID
  var endpointName: String
  let noteID: UUID
  var noteTitle: String
  let event: MeetingWebhookEvent
  var state: State
  /// Attempts made so far.
  var attempts: Int
  var maximumAttempts: Int
  var lastStatusCode: Int?
  var lastError: String?
  let createdAt: Date
  var updatedAt: Date
  /// The send this part belongs to (nil in records written before split sends existed).
  var sendID: UUID?
  /// When the send was enqueued, stamped once and copied onto every part, so a send that
  /// resumes later never looks newer than a send started after it. Nil in older records.
  var sendCreatedAt: Date?
  /// Orders sends with full precision: issued once per send at enqueue (seconds since the
  /// reference date, strictly increasing within a run) and copied onto every part. Stored as a
  /// number because the log's ISO 8601 dates drop fractional seconds. Nil in older records.
  var sendOrder: Double?
  /// 1-based part index and part count; nil means a single, unsplit delivery.
  var partIndex: Int?
  var partTotal: Int?
  /// Queued records: how many earlier sends to the endpoint are still ahead of this one.
  var queuedBehind: Int?
  /// Queued or retrying records: when the next request is due, if known.
  var nextAttemptAt: Date?
  /// Queued records: true while waiting out the receiver's rate-limit cooldown.
  var isRateLimitWait: Bool?
  /// Split sends: SHA-256 of the whole note Markdown that was split (never the Markdown).
  var contentFingerprint: String?
  /// Split sends: SHA-256 of this part's chunk of the note, without the end marker.
  var partFingerprint: String?
  /// Split sends: the content setting, max body size and chunk budget the note was cut with.
  var content: MeetingWebhookContent?
  var maxBodyCharacters: Int?
  var chunkBudget: Int?

  /// Groups the parts of one send; an older record is its own send.
  var sendKey: UUID { sendID ?? id }

  /// Ranks sends, newest highest: `sendOrder`, else `sendCreatedAt`, else `createdAt` for
  /// records written before those fields existed.
  var sendRank: Double {
    sendOrder ?? (sendCreatedAt ?? createdAt).timeIntervalSinceReferenceDate
  }

  /// True for parts of a send with more than one part.
  var isPartOfSplit: Bool { (partTotal ?? 1) > 1 }

  /// True for a split send's record that carries what a partial resend needs.
  var supportsPartialResend: Bool {
    partIndex != nil && partTotal != nil && contentFingerprint != nil && chunkBudget != nil
      && content != nil && maxBodyCharacters != nil
  }

  static let skippedPrefix = "Skipped: "

  /// A part that was never sent because an earlier part failed.
  var isSkipped: Bool { state == .failed && lastError?.hasPrefix(Self.skippedPrefix) == true }
}

extension MeetingWebhookDeliveryRecord {
  /// A fresh record for `job` in `state`, with the job's send and split details.
  init(
    job: MeetingWebhookDeliveryJob,
    state: State,
    maximumAttempts: Int,
    lastError: String? = nil,
    at date: Date
  ) {
    let partIndex = job.partIndex
    let fingerprints = job.splitInfo?.partFingerprints ?? []
    self.init(
      id: job.deliveryID,
      endpointID: job.endpoint.id,
      endpointName: job.endpoint.displayName,
      noteID: job.noteID,
      noteTitle: job.noteTitle,
      event: job.event,
      state: state,
      attempts: 0,
      maximumAttempts: maximumAttempts,
      lastStatusCode: nil,
      lastError: lastError,
      createdAt: date,
      updatedAt: date,
      sendID: job.sendID,
      sendCreatedAt: job.sendCreatedAt ?? date,
      sendOrder: job.sendOrder,
      partIndex: job.partIndex,
      partTotal: job.partTotal,
      contentFingerprint: job.splitInfo?.contentFingerprint,
      partFingerprint: fingerprints.indices.contains(partIndex - 1)
        ? fingerprints[partIndex - 1]
        : nil,
      content: job.splitInfo?.content,
      maxBodyCharacters: job.splitInfo?.maxBodyCharacters,
      chunkBudget: job.splitInfo?.chunkBudget
    )
  }
}
