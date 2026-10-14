import Foundation

/// `URLSession` transport that refuses redirects, so secret headers never follow a redirect
/// to another host, and never stores cookies or cached responses.
final class MeetingWebhookURLSessionTransport: NSObject, MeetingWebhookTransport,
  URLSessionTaskDelegate, @unchecked Sendable {
  private let session: URLSession

  override init() {
    session = URLSession(
      configuration: NetworkConfiguration.createConfiguration(
        timeout: MeetingWebhookRetryPolicy.requestTimeout
      )
    )
    super.init()
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse {
    let (_, response) = try await session.data(for: request, delegate: self)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return MeetingWebhookTransportResponse(
      statusCode: http.statusCode,
      retryAfter: http.value(forHTTPHeaderField: "Retry-After")
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
