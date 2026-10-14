import Foundation

/// The status and headers a webhook delivery needs from a response. Bodies are ignored.
struct MeetingWebhookTransportResponse: Equatable, Sendable {
  let statusCode: Int
  let retryAfter: String?

  init(statusCode: Int, retryAfter: String? = nil) {
    self.statusCode = statusCode
    self.retryAfter = retryAfter
  }
}

/// Sends one webhook request. `URLSession` in the app, a fake in tests. Implementations must
/// not follow redirects: a 3xx comes back as the response.
protocol MeetingWebhookTransport: Sendable {
  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse
}
