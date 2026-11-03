import Foundation

/// The status and headers a webhook delivery needs from a response, plus the outcome a 2xx
/// reply reported (`MeetingWebhookReceiverOutcome`). The reply body itself is never kept.
struct MeetingWebhookTransportResponse: Equatable, Sendable {
  let statusCode: Int
  let retryAfter: String?
  let receiverOutcome: MeetingWebhookReceiverOutcome?

  init(
    statusCode: Int,
    retryAfter: String? = nil,
    receiverOutcome: MeetingWebhookReceiverOutcome? = nil
  ) {
    self.statusCode = statusCode
    self.retryAfter = retryAfter
    self.receiverOutcome = receiverOutcome
  }
}

/// Sends one webhook request. `URLSession` in the app, a fake in tests. Implementations must
/// not follow redirects: a 3xx comes back as the response. For a 2xx response they read at
/// most `MeetingWebhookReceiverOutcome.maximumReplyBytes` of the body, and a failure while
/// reading it still returns the 2xx status (the request was delivered).
protocol MeetingWebhookTransport: Sendable {
  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse
}
