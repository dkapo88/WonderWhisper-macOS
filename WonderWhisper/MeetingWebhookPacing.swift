import Foundation

/// Spacing for split sends, so a receiver with a rate limit is not flooded: one request in
/// flight per endpoint, `partDelay` between parts, `noteDelay` between sends, and a slower
/// backoff when the receiver says it is rate limiting.
struct MeetingWebhookPacing: Equatable, Sendable {
  /// Wait after a delivered part before the next part.
  let partDelay: TimeInterval
  /// Minimum gap between the last request of one send and the first of the next.
  let noteDelay: TimeInterval
}
