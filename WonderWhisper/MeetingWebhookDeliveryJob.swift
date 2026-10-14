import Foundation

/// Everything one delivery of one part to one endpoint needs. The body is fixed for the whole
/// delivery (the same `deliveryId` across retries); the timestamp and signature are fresh per
/// attempt. An unsplit send is a single part 1 of 1.
struct MeetingWebhookDeliveryJob: Sendable {
  let deliveryID: UUID
  /// Shared by every part of one send.
  let sendID: UUID
  let partIndex: Int
  let partTotal: Int
  let endpoint: MeetingWebhookEndpoint
  let url: URL
  let event: MeetingWebhookEvent
  let noteID: UUID
  let noteTitle: String
  let body: Data
  let signingSecret: String?
  let customHeaders: [String: String]
  let userAgent: String

  init(
    deliveryID: UUID,
    sendID: UUID? = nil,
    partIndex: Int = 1,
    partTotal: Int = 1,
    endpoint: MeetingWebhookEndpoint,
    url: URL,
    event: MeetingWebhookEvent,
    noteID: UUID,
    noteTitle: String,
    body: Data,
    signingSecret: String?,
    customHeaders: [String: String],
    userAgent: String
  ) {
    self.deliveryID = deliveryID
    self.sendID = sendID ?? deliveryID
    self.partIndex = partIndex
    self.partTotal = partTotal
    self.endpoint = endpoint
    self.url = url
    self.event = event
    self.noteID = noteID
    self.noteTitle = noteTitle
    self.body = body
    self.signingSecret = signingSecret
    self.customHeaders = customHeaders
    self.userAgent = userAgent
  }
}
