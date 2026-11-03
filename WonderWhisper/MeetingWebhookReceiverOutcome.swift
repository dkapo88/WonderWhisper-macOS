import Foundation

/// What a receiver said about a request it accepted (2xx), read from at most 4 KB of its reply.
/// MausBot answers `{"ignored": true}` when its event filter skips the event, `{"captured":
/// true}` when its automation is off and it only stored the request as a setup check, and
/// `{"duplicate": true}` for a delivery ID it already has. Only the outcome is kept; the reply
/// body is never stored, logged or shown.
enum MeetingWebhookReceiverOutcome: String, Codable, Equatable, Sendable {
  case ignored
  case captured
  case duplicate

  /// The most reply bytes read; a longer reply counts as no outcome.
  static let maximumReplyBytes = 4_096

  /// The outcome a 2xx reply body reports, or nil for a normal delivery: an empty, overflowing,
  /// non-JSON or non-object body, or one where none of the keys is a literal JSON `true`
  /// (`"true"` strings and numbers don't count).
  static func parse(_ body: Data, overflowed: Bool) -> MeetingWebhookReceiverOutcome? {
    guard !overflowed, !body.isEmpty, body.count <= maximumReplyBytes,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return nil
    }
    if isTrue(object["ignored"]) { return .ignored }
    if isTrue(object["captured"]) { return .captured }
    if isTrue(object["duplicate"]) { return .duplicate }
    return nil
  }

  /// A literal JSON `true`: Foundation decodes booleans as `CFBoolean`, numbers as other
  /// `NSNumber`s, so `1` is not `true`.
  private static func isTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return false
    }
    return number.boolValue
  }
}
