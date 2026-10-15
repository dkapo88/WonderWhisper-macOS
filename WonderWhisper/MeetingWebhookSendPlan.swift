import Foundation

/// What one send POSTs, and for a split send the parameters it was cut with.
struct MeetingWebhookSendPlan: Equatable, Sendable {
  let payloads: [MeetingWebhookPayload]
  /// Nil for an unsplit send.
  let split: MeetingWebhookSplitInfo?
}
