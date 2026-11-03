import Foundation

/// `URLSession` transport that refuses redirects, so secret headers never follow a redirect
/// to another host, and never stores cookies or cached responses.
///
/// The status is taken as soon as the response headers arrive. A non-2xx response is not read
/// further. A 2xx reply is read only up to 4 KB (one byte more marks an overflow) to learn the
/// receiver's outcome; the bytes stay in memory for the parse and are never logged or kept. If
/// reading the body fails after a 2xx status, the request still counts as delivered.
final class MeetingWebhookURLSessionTransport: NSObject, MeetingWebhookTransport,
  @unchecked Sendable {
  private let session: URLSession

  /// `configuration` is for tests (a stub `URLProtocol`); the app uses the shared network
  /// configuration.
  init(configuration: URLSessionConfiguration? = nil) {
    session = URLSession(
      configuration: configuration ?? NetworkConfiguration.createConfiguration(
        timeout: MeetingWebhookRetryPolicy.requestTimeout
      )
    )
    super.init()
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  func send(_ request: URLRequest) async throws -> MeetingWebhookTransportResponse {
    let exchange = Exchange()
    let task = session.dataTask(with: request)
    task.delegate = exchange
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        exchange.start(task, continuation: continuation)
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// One request's delegate: captures the status at the response, reads a capped 2xx body,
  /// and resumes the caller exactly once.
  private final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeetingWebhookTransportResponse, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    /// The outcome once known. Kept so a continuation registered after the task already
    /// finished (cancelled before `start`) still resumes.
    private var result: Result<MeetingWebhookTransportResponse, Error>?

    func start(
      _ task: URLSessionDataTask,
      continuation: CheckedContinuation<MeetingWebhookTransportResponse, Error>
    ) {
      let earlier: Result<MeetingWebhookTransportResponse, Error>? = lock.withLock {
        if let result { return result }
        self.continuation = continuation
        return nil
      }
      if let earlier {
        continuation.resume(with: earlier)
        return
      }
      task.resume()
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest
    ) async -> URLRequest? {
      nil
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        finish(.failure(URLError(.badServerResponse)))
        return
      }
      lock.withLock { self.response = http }
      if (200...299).contains(http.statusCode) {
        completionHandler(.allow)
      } else {
        // Only the status and Retry-After matter; never read the body.
        completionHandler(.cancel)
        finish(.success(Self.result(http, outcome: nil)))
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let limit = MeetingWebhookReceiverOutcome.maximumReplyBytes
      let overflowed: Bool = lock.withLock {
        let room = limit - body.count
        body.append(data.prefix(max(0, room)))
        return data.count > room
      }
      guard overflowed else { return }
      dataTask.cancel()
      finishWithBody(overflowed: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      let hasResponse = lock.withLock { response != nil }
      if let error {
        guard hasResponse else {
          finish(.failure(error))
          return
        }
        // The 2xx status already arrived: delivered, with no outcome.
        finishWithBody(overflowed: true)
        return
      }
      guard hasResponse else {
        finish(.failure(URLError(.badServerResponse)))
        return
      }
      finishWithBody(overflowed: false)
    }

    private func finishWithBody(overflowed: Bool) {
      let (response, body) = lock.withLock { (self.response, self.body) }
      guard let response else {
        finish(.failure(URLError(.badServerResponse)))
        return
      }
      let outcome = MeetingWebhookReceiverOutcome.parse(body, overflowed: overflowed)
      finish(.success(Self.result(response, outcome: outcome)))
    }

    /// Records the outcome once; resumes the caller now if it is already waiting, else when it
    /// registers in `start`.
    private func finish(_ outcome: Result<MeetingWebhookTransportResponse, Error>) {
      let continuation: CheckedContinuation<MeetingWebhookTransportResponse, Error>? =
        lock.withLock {
          guard result == nil else { return nil }
          result = outcome
          body = Data()
          defer { self.continuation = nil }
          return self.continuation
        }
      continuation?.resume(with: outcome)
    }

    private static func result(
      _ response: HTTPURLResponse,
      outcome: MeetingWebhookReceiverOutcome?
    ) -> MeetingWebhookTransportResponse {
      MeetingWebhookTransportResponse(
        statusCode: response.statusCode,
        retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
        receiverOutcome: outcome
      )
    }
  }
}
