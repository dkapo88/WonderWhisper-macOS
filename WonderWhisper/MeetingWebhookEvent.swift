import Foundation

/// Why a webhook payload was sent. The raw value is the payload `event` field and the
/// `X-WonderWhisper-Event` header.
enum MeetingWebhookEvent: String, Codable, CaseIterable, Sendable {
  case noteCompleted = "meeting.note.completed"
  case noteResent = "meeting.note.resent"
  case test = "webhook.test"
}
