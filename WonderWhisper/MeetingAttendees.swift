import Foundation

/// Parses and formats a meeting's attendees, typed as one comma separated line.
enum MeetingAttendees {
  /// Names split on commas, semicolons and line breaks, trimmed, empty entries dropped, and
  /// later case-insensitive duplicates removed (the first spelling wins).
  static func parse(_ text: String) -> [String] {
    var seen = Set<String>()
    var names: [String] = []
    for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
      let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      let key = name.lowercased()
      guard seen.insert(key).inserted else { continue }
      names.append(name)
    }
    return names
  }

  /// The editable text for a list of names.
  static func text(_ attendees: [String]) -> String {
    attendees.joined(separator: ", ")
  }
}
