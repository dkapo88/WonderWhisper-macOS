import Foundation
import NaturalLanguage

struct ScreenContentKeywordExtractor {
  private struct Token {
    let original: String
    let normalized: String
    let index: Int
  }

  private struct TokenStats {
    var count: Int
    var representative: String
    var firstIndex: Int
  }

  private struct NGramStats {
    var count: Int
    var firstIndex: Int
    var original: String
  }

  private let stopWords: Set<String>

  init(stopWords: Set<String> = ScreenContentKeywordExtractor.defaultStopWords) {
    self.stopWords = stopWords
  }

  func formattedKeywords(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let collapsedWhitespace = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    guard !collapsedWhitespace.isEmpty else { return nil }

    let tokens = tokenize(collapsedWhitespace)
    var ordered: [String] = []
    var seen: Set<String> = []

    func append(_ value: String) {
      let key = value.lowercased()
      guard !key.isEmpty else { return }
      if seen.insert(key).inserted {
        ordered.append(value)
      }
    }

    extractMentions(from: collapsedWhitespace).forEach { append($0) }
    extractNamedEntities(from: collapsedWhitespace).forEach { append($0) }
    extractFrequentNGrams(tokens: tokens).forEach { append($0) }
    extractKeywordUnigrams(tokens: tokens).forEach { append($0) }

    guard !ordered.isEmpty else { return nil }
    let limited = ordered.prefix(20)
    let bulletLines = limited.map { "- \($0)" }
    return (["Key terms and names:"] + bulletLines).joined(separator: "\n")
  }

  // MARK: - Tokenization helpers
  private func tokenize(_ text: String) -> [Token] {
    var results: [Token] = []
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'@-+/&_"))
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let fragment = String(text[range])
      let trimmed = fragment.trimmingCharacters(in: allowedCharacters.inverted)
      guard trimmed.count >= 2 else { return true }
      let normalized = trimmed.lowercased()
      guard !stopWords.contains(normalized) else { return true }
      let isNumeric = normalized.allSatisfy { $0.isNumber }
      if isNumeric { return true }
      results.append(Token(original: trimmed, normalized: normalized, index: results.count))
      return true
    }
    return results
  }

  private func extractMentions(from text: String) -> [String] {
    let pattern = "(?<=^|\\s)@[A-Za-z0-9_]{2,}"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, options: [], range: range).compactMap { match in
      guard let resultRange = Range(match.range, in: text) else { return nil }
      return String(text[resultRange])
    }
  }

  private func extractKeywordUnigrams(tokens: [Token]) -> [String] {
    guard !tokens.isEmpty else { return [] }
    var stats: [String: TokenStats] = [:]
    for token in tokens {
      var entry = stats[token.normalized] ?? TokenStats(count: 0, representative: token.original, firstIndex: token.index)
      entry.count += 1
      if token.original.count > entry.representative.count {
        entry.representative = token.original
      }
      stats[token.normalized] = entry
    }

    return stats
      .map { ($0.key, $0.value) }
      .filter { key, value in
        value.count >= 2 || key.count >= 5
      }
      .sorted { lhs, rhs in
        if lhs.1.count == rhs.1.count {
          return lhs.1.firstIndex < rhs.1.firstIndex
        }
        return lhs.1.count > rhs.1.count
      }
      .map { $0.1.representative }
  }

  private func extractFrequentNGrams(tokens: [Token]) -> [String] {
    guard tokens.count >= 2 else { return [] }
    var bigramStats: [String: NGramStats] = [:]
    for idx in 0..<(tokens.count - 1) {
      let first = tokens[idx]
      let second = tokens[idx + 1]
      if stopWords.contains(first.normalized) || stopWords.contains(second.normalized) { continue }
      let key = "\(first.normalized) \(second.normalized)"
      var entry = bigramStats[key] ?? NGramStats(count: 0, firstIndex: first.index, original: "\(first.original) \(second.original)")
      entry.count += 1
      bigramStats[key] = entry
    }

    return bigramStats
      .map { $0.value }
      .filter { $0.count >= 2 || $0.original.count >= 10 }
      .sorted { lhs, rhs in
        if lhs.count == rhs.count {
          return lhs.firstIndex < rhs.firstIndex
        }
        return lhs.count > rhs.count
      }
      .map { $0.original }
  }

  private func extractNamedEntities(from text: String) -> [String] {
    var results: [String] = []
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
    tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                         unit: .word,
                         scheme: .nameType,
                         options: options) { tag, range in
      guard let tag else { return true }
      switch tag {
      case .personalName, .placeName, .organizationName:
        let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
          results.append(candidate)
        }
      default:
        break
      }
      return true
    }
    return results
  }

  private static let defaultStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
    "had", "has", "have", "if", "in", "into", "is", "it", "its", "of", "on",
    "or", "so", "such", "that", "the", "their", "then", "there", "these",
    "they", "this", "to", "was", "were", "with", "you", "your"
  ]
}
