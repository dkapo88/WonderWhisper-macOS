import Foundation

enum VocabularyTextCorrector {
  static func apply(to text: String, vocabulary: String) -> String {
    let terms = parseVocabulary(vocabulary)
      .filter { !$0.contains(" ") && !$0.contains("\t") }
    guard !terms.isEmpty, !text.isEmpty else { return text }

    // Pre-normalize the term list once instead of recomputing normalized(term) for every
    // (matched word x term) pair. Terms shorter than 4 normalized chars can never match.
    let normalizedTerms: [(term: String, normalized: String)] = terms.compactMap {
      let n = normalized($0)
      return n.count >= 4 ? (term: $0, normalized: n) : nil
    }
    guard !normalizedTerms.isEmpty else { return text }

    let pattern = #"[A-Za-z][A-Za-z'’-]*"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var corrected = text

    for match in matches.reversed() {
      let word = nsText.substring(with: match.range)
      guard let replacement = bestReplacement(for: word, vocabularyTerms: normalizedTerms) else { continue }
      corrected = (corrected as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    return corrected
  }

  private static func parseVocabulary(_ vocabulary: String) -> [String] {
    let separators = CharacterSet(charactersIn: ",\n\r")
    var result: [String] = []
    var seen: Set<String> = []

    for raw in vocabulary.components(separatedBy: separators) {
      let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty else { continue }
      let key = normalized(term)
      guard seen.insert(key).inserted else { continue }
      result.append(term)
    }

    return result
  }

  private static func bestReplacement(for word: String, vocabularyTerms: [(term: String, normalized: String)]) -> String? {
    let normalizedWord = normalized(word)
    guard normalizedWord.count >= 4 else { return nil }
    guard !commonWords.contains(normalizedWord) else { return nil }

    var best: (term: String, distance: Int)?
    for entry in vocabularyTerms {
      let normalizedTerm = entry.normalized
      guard abs(normalizedWord.count - normalizedTerm.count) <= 2 else { continue }
      guard normalizedWord.first == normalizedTerm.first else { continue }
      guard normalizedWord != normalizedTerm else { continue }

      let distance = levenshtein(normalizedWord, normalizedTerm)
      let limit = maxDistance(forLength: normalizedTerm.count)
      guard distance <= limit else { continue }

      if best == nil || distance < best!.distance {
        best = (entry.term, distance)
      }
    }

    return best?.term
  }

  private static func normalized(_ value: String) -> String {
    value
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func maxDistance(forLength length: Int) -> Int {
    length >= 8 ? 2 : 1
  }

  private static let commonWords: Set<String> = [
    "about", "after", "again", "also", "because", "before", "being", "between", "could",
    "does", "doing", "from", "going", "have", "into", "just", "like", "later", "make",
    "need", "okay", "only", "over", "payment", "ready", "report", "should", "some",
    "talk", "than", "that", "then", "there", "these", "this", "those", "through",
    "want", "were", "what", "when", "where", "which", "will", "with", "would", "your"
  ]

  private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }

    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)

    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        let insertion = current[j - 1] + 1
        let deletion = previous[j] + 1
        current[j] = min(substitution, insertion, deletion)
      }
      swap(&previous, &current)
    }

    return previous[b.count]
  }
}
