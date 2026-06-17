import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

enum ScreenContextPreprocessingMethod: String, Codable, Equatable {
  case appleIntelligence = "AppleIntelligenceTerms"
  case localKeywords = "LocalKeywordTerms"
}

struct ScreenContextPreprocessingResult: Equatable {
  let terms: [String]
  let method: ScreenContextPreprocessingMethod

  var contextText: String {
    terms.joined(separator: ", ")
  }
}

final class ScreenContextPreprocessor {
  private let useAppleIntelligence: Bool
  private let maxTerms: Int
  private let correctionHints: [String]
  private let maxInputCharacters = 10_000

  init(useAppleIntelligence: Bool = true,
       maxTerms: Int = 40,
       correctionHints: [String] = ScreenContextPreprocessor.defaultCorrectionHints()) {
    self.useAppleIntelligence = useAppleIntelligence
    self.maxTerms = max(1, maxTerms)
    self.correctionHints = ScreenContextTermExtractor.normalizeCommaSeparated(
      correctionHints.joined(separator: ","),
      limit: 120
    )
  }

  static func defaultCorrectionHints() -> [String] {
    var hints = [
      "HermesWhisper",
      "Hermes Whisper",
      "OpenRouter",
      "OpenRouter Voice",
      "Soniox",
      "Soniox V5",
      "Parakeet",
      "Parakeet V3",
      "Groq",
      "Groq Whisper",
      "Grok STT",
      "xAI",
      "GPT-4o",
      "GPT-4o-mini-transcribe"
    ]

    if let custom = UserDefaults.standard.string(forKey: "vocab.custom"),
       !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      hints.append(contentsOf: ScreenContextTermExtractor.normalizeCommaSeparated(custom, limit: 80))
    }

    return ScreenContextTermExtractor.normalizeCommaSeparated(hints.joined(separator: ","), limit: 120)
  }

  func preprocess(ocrText: String) async -> ScreenContextPreprocessingResult? {
    let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let localTerms = ScreenContextTermExtractor.extract(
      from: trimmed,
      limit: maxTerms,
      correctionHints: correctionHints
    )

    if useAppleIntelligence,
       let appleTerms = await refineWithAppleIntelligence(ocrText: trimmed, localTerms: localTerms),
       !appleTerms.isEmpty {
      return ScreenContextPreprocessingResult(
        terms: merge(primary: appleTerms, fallback: localTerms, limit: maxTerms),
        method: .appleIntelligence
      )
    }

    guard !localTerms.isEmpty else { return nil }
    return ScreenContextPreprocessingResult(terms: localTerms, method: .localKeywords)
  }

  private func merge(primary: [String], fallback: [String], limit: Int) -> [String] {
    var merged: [String] = []
    var seen = Set<String>()

    func append(_ term: String) {
      guard merged.count < limit else { return }
      let normalized = ScreenContextTermExtractor.normalizedTerm(
        term,
        correctionHints: correctionHints
      )
      guard let normalized else { return }
      let key = normalized.lowercased()
      guard seen.insert(key).inserted else { return }
      merged.append(normalized)
    }

    primary.forEach(append)
    fallback.forEach(append)
    return merged
  }

  private func truncatedInput(_ text: String) -> String {
    guard text.count > maxInputCharacters else { return text }

    let headCount = Int(Double(maxInputCharacters) * 0.75)
    let tailCount = maxInputCharacters - headCount
    let head = text.prefix(headCount)
    let tail = text.suffix(tailCount)
    return "\(head)\n...\n\(tail)"
  }

  private func refineWithAppleIntelligence(ocrText: String, localTerms: [String]) async -> [String]? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      return await AppleIntelligenceScreenContextRefiner.refine(
        ocrText: truncatedInput(ocrText),
        localTerms: localTerms,
        correctionHints: correctionHints,
        limit: maxTerms
      )
    }
    #endif

    return nil
  }
}

enum ScreenContextTermExtractor {
  static func extract(from text: String,
                      limit: Int = 40,
                      correctionHints: [String] = []) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, limit > 0 else { return [] }

    var candidates: [String: Candidate] = [:]

    func add(_ rawTerm: String, score: Int, location: Int) {
      guard let term = normalizedTerm(rawTerm, correctionHints: correctionHints) else { return }
      let key = term.lowercased()
      if var existing = candidates[key] {
        existing.score += score
        existing.count += 1
        candidates[key] = existing
      } else {
        candidates[key] = Candidate(text: term, score: score, count: 1, location: location)
      }
    }

    addNamedEntities(from: trimmed, add: add)
    addCapitalizedPhrases(from: trimmed, add: add)
    addRegexTerms(from: trimmed, add: add)

    return candidates.values
      .sorted { lhs, rhs in
        if lhs.score == rhs.score {
          if lhs.count == rhs.count { return lhs.location < rhs.location }
          return lhs.count > rhs.count
        }
        return lhs.score > rhs.score
      }
      .prefix(limit)
      .map(\.text)
  }

  static func normalizeCommaSeparated(_ text: String,
                                      limit: Int,
                                      correctionHints: [String] = []) -> [String] {
    guard limit > 0 else { return [] }

    let unified = text
      .replacingOccurrences(of: "\n", with: ",")
      .replacingOccurrences(of: ";", with: ",")

    var terms: [String] = []
    var seen = Set<String>()

    for piece in unified.split(separator: ",") {
      var raw = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
      let leadingSet = CharacterSet(charactersIn: "-•*0123456789. \t")
      if let firstNonNoisyIndex = raw.firstIndex(where: { char in
        char.unicodeScalars.allSatisfy { !leadingSet.contains($0) }
      }) {
        raw = String(raw[firstNonNoisyIndex...])
      } else {
        raw = ""
      }

      let lower = raw.lowercased()
      for prefix in ["terms:", "keywords:", "screen context terms:", "context terms:"] {
        if lower.hasPrefix(prefix) {
          raw = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
          break
        }
      }

      guard let normalized = normalizedTerm(raw, correctionHints: correctionHints) else { continue }
      let key = normalized.lowercased()
      guard seen.insert(key).inserted else { continue }
      terms.append(normalized)
      if terms.count >= limit { break }
    }

    return terms
  }

  static func normalizedTerm(_ raw: String, correctionHints: [String] = []) -> String? {
    guard var trimmed = basicNormalizedTerm(raw) else { return nil }

    if let corrected = correctedByHint(trimmed, correctionHints: correctionHints) {
      trimmed = corrected
    }

    guard !containsRejectedOCRNoise(in: trimmed) else { return nil }
    guard !isRomanNumeralNoise(trimmed) else { return nil }

    let lower = trimmed.lowercased()
    guard !stopWords.contains(lower) else { return nil }
    guard trimmed.contains(where: { $0.isLetter }) else { return nil }
    guard !trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }

    return trimmed
  }

  private static func basicNormalizedTerm(_ raw: String) -> String? {
    let trimmed = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]{}()<>"))
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
      .collapsingWhitespaceForScreenContext()

    guard trimmed.count >= 2, trimmed.count <= 80 else { return nil }
    return trimmed
  }

  private static func containsRejectedOCRNoise(in term: String) -> Bool {
    let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted
    let tokens = term.components(separatedBy: separators).filter { !$0.isEmpty }
    return tokens.contains(where: isRejectedNoisyToken)
  }

  private static func isRejectedNoisyToken(_ token: String) -> Bool {
    let hasLetter = token.contains(where: { $0.isLetter })
    let hasDigit = token.contains(where: { $0.isNumber })
    guard hasLetter && hasDigit else { return false }

    if token.contains("-") { return false }
    if isVersionToken(token) { return false }
    if isAcronymVersionToken(token) { return false }

    return true
  }

  private static func isVersionToken(_ token: String) -> Bool {
    token.range(
      of: #"^[vV]\d+(?:\.\d+)*$"#,
      options: .regularExpression
    ) != nil
  }

  private static func isAcronymVersionToken(_ token: String) -> Bool {
    token.range(
      of: #"^[A-Z][A-Z0-9]{1,9}$"#,
      options: .regularExpression
    ) != nil
  }

  private static func isRomanNumeralNoise(_ term: String) -> Bool {
    let compact = term.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 2, compact.count <= 7 else { return false }
    return compact.range(
      of: #"^[IVXLCDMivxlcdm]+$"#,
      options: .regularExpression
    ) != nil
  }

  private static func correctedByHint(_ term: String, correctionHints: [String]) -> String? {
    guard term.count >= 4, !correctionHints.isEmpty else { return nil }
    let termKey = fuzzyComparisonKey(term)
    guard termKey.count >= 4 else { return nil }

    var bestMatch: String?
    var bestDistance = Int.max

    for hint in correctionHints {
      guard let normalizedHint = basicNormalizedTerm(hint),
            normalizedHint.count >= 4 else { continue }
      let hintKey = fuzzyComparisonKey(normalizedHint)
      guard hintKey.count >= 4, termKey.first == hintKey.first else { continue }

      let threshold = max(1, min(2, max(termKey.count, hintKey.count) / 5))
      let distance = editDistance(termKey, hintKey, maxDistance: threshold)
      guard distance <= threshold, distance < bestDistance else { continue }
      bestDistance = distance
      bestMatch = normalizedHint
    }

    return bestMatch
  }

  private static func fuzzyComparisonKey(_ text: String) -> String {
    let mapped = text.lowercased().map { character -> Character in
      switch character {
      case "0": return "o"
      case "1", "i": return "l"
      case "3": return "e"
      case "5": return "s"
      case "8": return "b"
      default: return character
      }
    }
    return String(mapped.filter { $0.isLetter || $0.isNumber })
  }

  private static func editDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
    let left = Array(lhs)
    let right = Array(rhs)
    guard abs(left.count - right.count) <= maxDistance else { return maxDistance + 1 }
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }

    var previous = Array(0...right.count)
    var current = Array(repeating: 0, count: right.count + 1)

    for leftIndex in 1...left.count {
      current[0] = leftIndex
      var rowMinimum = current[0]
      for rightIndex in 1...right.count {
        let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
        current[rightIndex] = min(
          previous[rightIndex] + 1,
          current[rightIndex - 1] + 1,
          previous[rightIndex - 1] + substitutionCost
        )
        rowMinimum = min(rowMinimum, current[rightIndex])
      }

      if rowMinimum > maxDistance { return maxDistance + 1 }
      swap(&previous, &current)
    }

    return previous[right.count]
  }

  private static func addNamedEntities(from text: String, add: (String, Int, Int) -> Void) {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]

    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex,
      unit: .word,
      scheme: .nameType,
      options: options
    ) { tag, range in
      guard let tag, tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
      let term = String(text[range])
      add(term, 60, text.distance(from: text.startIndex, to: range.lowerBound))
      return true
    }
  }

  private static func addCapitalizedPhrases(from text: String, add: (String, Int, Int) -> Void) {
    var phrase: [String] = []
    var phraseLocation = 0

    func flush() {
      guard !phrase.isEmpty else { return }
      let term = phrase.joined(separator: " ")
      add(term, phrase.count > 1 ? 45 : 20, phraseLocation)
      phrase.removeAll()
    }

    let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    var searchStart = text.startIndex

    for rawToken in tokens {
      let tokenRange = text.range(of: rawToken, range: searchStart..<text.endIndex)
      let location = tokenRange.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
      if let upper = tokenRange?.upperBound {
        searchStart = upper
      }

      let raw = String(rawToken)
      let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]{}()<>"))
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))

      if isNotableToken(cleaned) {
        if phrase.isEmpty { phraseLocation = location }
        phrase.append(cleaned)
        if phrase.count >= 5 || raw.hasSuffix(",") || raw.hasSuffix(".") || raw.hasSuffix(":") {
          flush()
        }
      } else {
        flush()
      }
    }

    flush()
  }

  private static func addRegexTerms(from text: String, add: (String, Int, Int) -> Void) {
    let patterns = [
      #"\b[A-Z]{2,}-\d+\b"#,
      #"\b[A-Za-z]+(?:-[A-Za-z0-9]+)+\b"#,
      #"\b[A-Z]{2,}[A-Z0-9]*\b"#,
      #"\b[A-Za-z]*\d[A-Za-z0-9-]*\b"#
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
      regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
        guard let match,
              let range = Range(match.range, in: text) else { return }
        add(String(text[range]), 40, match.range.location)
      }
    }
  }

  private static func isNotableToken(_ token: String) -> Bool {
    guard let normalized = normalizedTerm(token) else { return false }
    let lower = normalized.lowercased()
    guard !stopWords.contains(lower) else { return false }

    let letters = normalized.filter(\.isLetter)
    guard !letters.isEmpty else { return false }

    if normalized.contains("-") { return true }
    if normalized.contains(where: \.isNumber) { return true }
    if normalized.count >= 2 && normalized.allSatisfy({ $0.isUppercase || $0.isNumber }) { return true }
    if let first = normalized.first, first.isUppercase, normalized.count >= 3 { return true }

    let upperAfterFirst = normalized.dropFirst().contains { $0.isUppercase }
    return upperAfterFirst
  }

  private struct Candidate {
    let text: String
    var score: Int
    var count: Int
    let location: Int
  }

  private static let stopWords: Set<String> = [
    "a", "all", "am", "an", "and", "are", "as", "at", "back", "be", "by",
    "can", "cancel", "check", "click", "close", "copy", "delete", "did", "do",
    "does", "done", "double", "edit", "for", "from", "go", "going", "got",
    "had", "has", "have", "help", "i", "in", "is", "it", "just", "let", "me",
    "menu", "my", "new", "next", "no", "not", "of", "ok", "on", "open", "or",
    "please", "previous", "save", "search", "send", "settings", "share", "team",
    "thank", "that", "the", "them", "then", "there", "they", "this", "to", "us",
    "view", "we", "with", "yes", "you"
  ]
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum AppleIntelligenceScreenContextRefiner {
  static func refine(ocrText: String,
                     localTerms: [String],
                     correctionHints: [String],
                     limit: Int) async -> [String]? {
    let model = SystemLanguageModel(useCase: .contentTagging)
    switch model.availability {
    case .available:
      break
    case .unavailable(let reason):
      AppLog.screen.log("Apple Intelligence screen context unavailable: \(String(describing: reason), privacy: .public)")
      return nil
    }

    let session = LanguageModelSession(
      model: model,
      instructions: """
      Extract spelling context from OCR text captured locally from the user's screen.
      OCR may contain visual character errors. Correct obvious OCR mistakes before output.
      Return only a comma-delimited list. Do not explain the list.
      """
    )

    let hints = localTerms.prefix(limit).joined(separator: ", ")
    let correctionHintText = correctionHints.prefix(80).joined(separator: ", ")
    let prompt = """
      Build a concise spelling context list for dictation correction.

      Include:
      - people names
      - company, product, project, and app names
      - acronyms, model names, ticket IDs, code identifiers, and filenames
      - unusual terms that affect spelling

      Exclude:
      - generic UI words such as Send, Cancel, Edit, Search, Settings
      - long sentences or paragraph text
      - values that are only plain numbers
      - common words that are not useful spelling hints
      - corrupted OCR tokens unless they can be confidently repaired into a name, product, code term, or acronym

      OCR cleanup rules:
      - Treat digits inside words as possible OCR substitutions: 5 -> s/S, 3 -> e/a, 1/I -> l/i, 0 -> o/O, 8 -> B.
      - If the corrected result is only a generic word, omit it instead of outputting it.
      - Prefer correction hints only when the OCR text is a close visual or spelling match.
      - Do not invent hinted terms that are not supported by the OCR text.

      Maximum \(limit) terms.
      Local extraction hints: \(hints)
      Correction hints: \(correctionHintText)

      OCR text:
      \(ocrText)
      """

    do {
      let response = try await session.respond(
        to: prompt,
        options: GenerationOptions(
          sampling: .greedy,
          temperature: 0,
          maximumResponseTokens: 220
        )
      )
      let terms = ScreenContextTermExtractor.normalizeCommaSeparated(
        response.content,
        limit: limit,
        correctionHints: correctionHints
      )
      return terms.isEmpty ? nil : terms
    } catch {
      AppLog.screen.error("Apple Intelligence screen context failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}
#endif

private extension String {
  func collapsingWhitespaceForScreenContext() -> String {
    components(separatedBy: CharacterSet.whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
