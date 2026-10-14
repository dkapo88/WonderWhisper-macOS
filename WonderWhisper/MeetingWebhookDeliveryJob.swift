import Foundation

/// Everything one delivery to one endpoint needs. The body is fixed for the whole delivery
/// (the same `deliveryId` across retries); the timestamp and signature are fresh per attempt.
struct MeetingWebhookDeliveryJob: Sendable {
  let deliveryID: UUID
  let endpoint: MeetingWebhookEndpoint
  let url: URL
  let event: MeetingWebhookEvent
  let noteID: UUID
  let noteTitle: String
  let body: Data
  let signingSecret: String?
  let customHeaders: [String: String]
  let userAgent: String
}
