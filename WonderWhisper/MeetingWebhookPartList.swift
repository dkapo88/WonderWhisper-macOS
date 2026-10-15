import Foundation

/// Parses the part numbers typed into "Resend Parts...": numbers and ranges separated by
/// commas or spaces, for example `3`, `2,3` or `2-4`.
enum MeetingWebhookPartList {
  /// The sorted, distinct part numbers, or nil when the text is empty, malformed or names a
  /// part outside `1...total`.
  static func parse(_ text: String, total: Int) -> [Int]? {
    let tokens = text.split { $0 == "," || $0.isWhitespace }
    guard !tokens.isEmpty, total >= 1 else { return nil }
    var parts = Set<Int>()
    for token in tokens {
      let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(bounds.count),
            let low = Int(bounds[0]),
            let high = Int(bounds[bounds.count - 1]),
            low <= high,
            low >= 1,
            high <= total else { return nil }
      parts.formUnion(low...high)
    }
    return parts.sorted()
  }
}
