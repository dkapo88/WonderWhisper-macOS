import Foundation

/// One delivery of one note (or one part of it) to one endpoint, as shown in the meeting
/// detail view and the Settings log. Never holds request bodies, secrets or header values.
struct MeetingWebhookDeliveryRecord: Codable, Identifiable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    case sending
    case retrying
    case delivered
    case failed

    var isInFlight: Bool { self == .sending || self == .retrying }
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
  /// 1-based part index and part count; nil means a single, unsplit delivery.
  var partIndex: Int?
  var partTotal: Int?

  /// Groups the parts of one send; an older record is its own send.
  var sendKey: UUID { sendID ?? id }

  /// Orders sends: when the send was enqueued, or the record's creation for older records.
  var sendOrder: Date { sendCreatedAt ?? createdAt }

  /// True for parts of a send with more than one part.
  var isPartOfSplit: Bool { (partTotal ?? 1) > 1 }

  static let skippedPrefix = "Skipped: "

  /// A part that was never sent because an earlier part failed.
  var isSkipped: Bool { state == .failed && lastError?.hasPrefix(Self.skippedPrefix) == true }
}
