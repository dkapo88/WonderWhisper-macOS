import Foundation

/// How a split send cut its note, stored on every part's delivery record so "Resend Missing
/// Parts" can rebuild exactly the same parts later, or refuse when it can't. Holds SHA-256
/// fingerprints, never the Markdown.
struct MeetingWebhookSplitInfo: Codable, Equatable, Sendable {
  /// SHA-256 of the whole note Markdown that was split.
  let contentFingerprint: String
  let content: MeetingWebhookContent
  /// The endpoint's max body size at the time of the send.
  let maxBodyCharacters: Int
  /// The escaped-byte budget each chunk was cut to.
  let chunkBudget: Int
  /// SHA-256 of each part's chunk (without the end marker), in part order.
  let partFingerprints: [String]
}
