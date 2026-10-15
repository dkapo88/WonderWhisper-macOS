import Foundation

/// When and how long to wait before retrying a webhook delivery.
enum MeetingWebhookRetryPolicy {
  enum Outcome: Equatable, Sendable {
    case delivered
    case retryable
    case failed
  }

  static let maximumAttempts = 5
  /// Waits after attempts 1 to 4.
  static let backoffSchedule: [TimeInterval] = [2, 10, 30, 120]
  /// Waits after attempts 1 to 4 of a paced (split) send the receiver rate limited (429 or
  /// 503) without saying how long to wait.
  static let rateLimitBackoffSchedule: [TimeInterval] = [30, 60, 120, 240]
  /// Up to this fraction of the base delay is added as jitter.
  static let jitterFraction = 0.2
  static let maximumRetryAfter: TimeInterval = 600
  static let requestTimeout: TimeInterval = 30

  /// 2xx delivers; 408, 425, 429 and 5xx retry; everything else (other 4xx, and 3xx because
  /// redirects are refused) fails immediately.
  static func outcome(forStatus status: Int) -> Outcome {
    switch status {
    case 200...299:
      return .delivered
    case 408, 425, 429, 500...599:
      return .retryable
    default:
      return .failed
    }
  }

  /// 429 and 503: the receiver is limiting requests.
  static func isRateLimit(status: Int) -> Bool {
    status == 429 || status == 503
  }

  static func shouldRetry(_ error: Error) -> Bool {
    if isCancellation(error) { return false }
    guard let urlError = error as? URLError else {
      let nsError = error as NSError
      guard nsError.domain == NSURLErrorDomain else { return false }
      return retryableURLErrorCodes.contains(URLError.Code(rawValue: nsError.code))
    }
    return retryableURLErrorCodes.contains(urlError.code)
  }

  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if (error as? URLError)?.code == .cancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  /// The wait before the attempt after `attempt` (1-based). `jitter` is a unit random value
  /// in `0..<1`. A server `Retry-After` replaces the schedule, capped at ten minutes.
  /// `rateLimited` (a paced send answered with 429 or 503) uses the slower rate-limit schedule.
  static func delay(
    afterAttempt attempt: Int,
    retryAfter: TimeInterval? = nil,
    jitter: Double = 0,
    rateLimited: Bool = false
  ) -> TimeInterval {
    if let retryAfter {
      return min(max(0, retryAfter), maximumRetryAfter)
    }
    let schedule = rateLimited ? rateLimitBackoffSchedule : backoffSchedule
    let index = min(max(0, attempt - 1), schedule.count - 1)
    let base = schedule[index]
    let unit = min(max(0, jitter), 1)
    return base + base * jitterFraction * unit
  }

  /// Parses `Retry-After` as delta seconds or an HTTP date, relative to `now`.
  static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    if let seconds = Int(trimmed) {
      return seconds >= 0 ? min(TimeInterval(seconds), maximumRetryAfter) : nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: trimmed) else { return nil }
    return min(max(0, date.timeIntervalSince(now)), maximumRetryAfter)
  }

  private static let retryableURLErrorCodes: Set<URLError.Code> = [
    .timedOut,
    .networkConnectionLost,
    .cannotFindHost,
    .cannotConnectToHost,
    .dnsLookupFailed,
    .notConnectedToInternet,
    .secureConnectionFailed,
    .badServerResponse,
    .cannotLoadFromNetwork,
    .internationalRoamingOff,
    .callIsActive,
    .dataNotAllowed,
    .resourceUnavailable
  ]
}
