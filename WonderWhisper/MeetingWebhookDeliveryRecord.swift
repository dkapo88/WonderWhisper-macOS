import Foundation

/// One delivery of one note to one endpoint, as shown in the meeting detail view and the
/// Settings log. Never holds request bodies, secrets or header values.
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
}
