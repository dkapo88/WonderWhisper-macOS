import Foundation

/// What a webhook receives: the full exported note, or the note without its transcript.
enum MeetingWebhookContent: String, Codable, CaseIterable, Sendable {
  /// The exported document without the `## Transcript` section.
  case summary
  /// The same document the Obsidian export writes.
  case full

  var label: String {
    switch self {
    case .summary: return "Summary only"
    case .full: return "Full note (with transcript)"
    }
  }
}
