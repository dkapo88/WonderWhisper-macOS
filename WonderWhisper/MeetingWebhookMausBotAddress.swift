import Foundation

/// MausBot (OpenMausBot) webhook automation addresses: `/hooks/wh_<id>` on a host the URL
/// validator accepts, optionally followed by `/<secret>`. MausBot also accepts the secret as
/// `Authorization: Bearer <secret>`, so the editor moves a pasted secret out of the URL.
enum MeetingWebhookMausBotAddress {
  /// A complete address split into the address without its secret and the decoded secret.
  struct Extracted: Equatable, Sendable {
    /// The URL with the `/<secret>` path segment removed.
    let url: String
    let secret: String

    /// The header value MausBot reads the secret from.
    var authorizationValue: String { "Bearer \(secret)" }
  }

  static let authorizationHeader = "Authorization"

  /// MausBot cuts the payload it shows its automation at this many characters (UTF-16 code
  /// units of the JSON re-indented with 2 spaces).
  static let formattedCharacterLimit = 48_000
  /// What WonderWhisper keeps every part under: the limit less a safety margin.
  static let formattedCharacterBudget = 47_000

  /// Delivery settings applied once to a new webhook when a MausBot address is recognised.
  static let defaultMaxBodyBytes = 40_000
  static let defaultPartDelaySeconds = 30
  static let defaultNoteDelaySeconds = 30

  /// True when `string` is a valid webhook URL whose path is a MausBot hook, with or without
  /// its secret segment.
  static func matches(_ string: String) -> Bool {
    hookPath(string) != nil
  }

  /// The address without its secret when `string` is a complete MausBot address: path
  /// `/hooks/wh_<id>/<secret>` with no query or fragment, where the secret, percent-decoded
  /// exactly once, is `whsec_` plus 43 base64url characters. Nil otherwise, including for a
  /// partly typed secret.
  static func extract(from string: String) -> Extracted? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let path = hookPath(trimmed),
          let segment = path.secretSegment,
          let components = URLComponents(string: trimmed),
          components.percentEncodedQuery == nil,
          components.percentEncodedFragment == nil,
          let decoded = segment.removingPercentEncoding,
          isSecret(decoded),
          trimmed.hasSuffix("/" + segment) else {
      return nil
    }
    let url = String(trimmed.dropLast(segment.count + 1))
    guard MeetingWebhookURLValidator.validate(url).url != nil else { return nil }
    return Extracted(url: url, secret: decoded)
  }

  /// `whsec_` plus exactly 43 base64url characters (a 32-byte secret, unpadded).
  static func isSecret(_ value: String) -> Bool {
    let prefix = "whsec_"
    guard value.hasPrefix(prefix) else { return false }
    let rest = value.dropFirst(prefix.count)
    return rest.count == 43 && rest.unicodeScalars.allSatisfy(isBase64URL)
  }

  /// Scheme, host (lowercased), port and path of `string`, so two URLs that differ only in a
  /// trailing secret or letter case of the host compare as different or equal destinations.
  static func destination(of string: String) -> String? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased() else {
      return nil
    }
    let port = components.port.map { ":\($0)" } ?? ""
    let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)\(components.percentEncodedPath)\(query)"
  }

  // MARK: - Reserved headers

  /// Headers WonderWhisper always sets, so custom headers can't use them (any case).
  static let alwaysReservedHeaders: Set<String> = ["content-type", "idempotency-key",
                                                   "x-webhook-event"]
  /// Headers MausBot reads as the event type or delivery id ahead of (or instead of) the ones
  /// WonderWhisper sends, so a custom one would change filtering or duplicate detection.
  static let mausBotReservedHeaders: Set<String> = ["x-github-event", "x-event-type",
                                                    "ce-type", "x-webhook-id", "webhook-id"]

  // MARK: - Private

  private struct HookPath {
    /// The raw (still percent-encoded) segment after `/hooks/wh_<id>`, if any.
    let secretSegment: String?
  }

  private static func hookPath(_ string: String) -> HookPath? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard MeetingWebhookURLValidator.validate(trimmed).url != nil,
          let components = URLComponents(string: trimmed) else {
      return nil
    }
    let segments = components.percentEncodedPath
      .split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    // "/hooks/wh_x" splits into ["", "hooks", "wh_x"]; a secret adds one more segment.
    guard segments.count == 3 || segments.count == 4,
          segments[0].isEmpty,
          segments[1] == "hooks",
          isEndpointID(segments[2]) else {
      return nil
    }
    if segments.count == 4 {
      guard !segments[3].isEmpty else { return nil }
      return HookPath(secretSegment: segments[3])
    }
    return HookPath(secretSegment: nil)
  }

  private static func isEndpointID(_ value: String) -> Bool {
    let prefix = "wh_"
    guard value.hasPrefix(prefix), value.count > prefix.count else { return false }
    return value.dropFirst(prefix.count).unicodeScalars.allSatisfy(isBase64URL)
  }

  private static func isBase64URL(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
      return true
    default:
      return false
    }
  }
}
