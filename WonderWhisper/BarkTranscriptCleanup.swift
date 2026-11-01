import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Output clean-up for Bark Clean transcripts (Bark only; Unified and Ultra are left alone).
///
/// Bark Clean's raw text has four defects the other models don't:
/// - `<unk>` where the speaker quoted something (FluidAudio 0.18 drops the token; this strips any
///   that still get through).
/// - About one in three transcripts starts lower-case.
/// - A decimal split by a space, sometimes glued to the word before: "version4 .2", "4 .2".
/// - Mixed number styles: "seventeen percent" next to "$3,450".
///
/// Number style follows the usual writing rule, applied with FluidAudio's NeMo inverse text
/// normalization: digits for numbers 10 and above, multi-word numbers, decimals, money, percent,
/// times and dates ("17%", "2:30 p.m.", "$520", "1.2 million", "the 14th"); words for a standalone
/// zero to nine and first to ninth ("nine of whom", "one of the best", "in a second"), which ITN
/// would otherwise turn into "1 of the best" and "a 2nd".
enum BarkTranscriptCleanup {
  typealias Normalizer = @Sendable (String) -> String

  static func clean(_ raw: String, normalizer: Normalizer = defaultNormalizer) -> String {
    var text = fixNumberSpacing(raw)
    text = stripUnknownTokens(text)
    text = normalizeNumbers(text, normalizer: normalizer)
    text = fixNumberSpacing(text)
    return capitalizingFirstLetter(text)
  }

  /// NeMo sentence ITN (bundled with FluidAudio); identity when the engine isn't linked.
  static let defaultNormalizer: Normalizer = { text in
    #if canImport(FluidAudio)
    return TextNormalizer.shared.normalizeSentence(text)
    #else
    return text
    #endif
  }

  // MARK: - Steps

  /// Removes `<unk>` and the spacing it leaves behind.
  static func stripUnknownTokens(_ text: String) -> String {
    guard text.range(of: "<unk>", options: .caseInsensitive) != nil else { return text }
    var result = text.replacingOccurrences(of: "<unk>", with: " ", options: .caseInsensitive)
    result = replacing(#"[ \t]{2,}"#, in: result, with: " ")
    result = replacing(#" +([.,!?;:])(?!\d)"#, in: result, with: "$1")
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// "version4 .2" -> "version 4.2", "4 .2" -> "4.2", "17 %" -> "17%", "02:30" -> "2:30",
  /// "p.m.." -> "p.m.".
  static func fixNumberSpacing(_ text: String) -> String {
    var result = text
    result = replacing(#"([A-Za-z]{2,})(\d+) +\.(\d)"#, in: result, with: "$1 $2.$3")
    result = replacing(#"(\d) +\.(\d)"#, in: result, with: "$1.$2")
    result = replacing(#"(\d) +%"#, in: result, with: "$1%")
    result = replacing(#"\b0([1-9]):([0-5]\d)\b"#, in: result, with: "$1:$2")
    result = replacing(#"\b([ap])\.m\.\."#, in: result, with: "$1.m.")
    return result
  }

  /// ITN with standalone small numbers protected (see the type comment).
  static func normalizeNumbers(_ text: String, normalizer: Normalizer) -> String {
    let (masked, restore) = maskStandaloneSmallNumbers(in: text)
    var result = normalizer(masked)
    // ITN must never drop a protected word; if it did, keep the unnormalized text.
    guard restore.keys.allSatisfy({ result.contains($0) }) else { return text }
    for (sentinel, word) in restore {
      result = result.replacingOccurrences(of: sentinel, with: word)
    }
    return result
  }

  /// Uppercases the first letter when the text starts with a word (after any quotes), unless that
  /// word already has a capital ("iPhone"). "42 is it" stays as it is.
  static func capitalizingFirstLetter(_ text: String) -> String {
    guard let first = text.firstIndex(where: { $0.isLetter || $0.isNumber }),
          text[first].isLetter, text[first].isLowercase else { return text }
    let wordEnd = text[first...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    guard !text[first..<wordEnd].contains(where: \.isUppercase) else { return text }
    return text.replacingCharacters(in: first...first, with: text[first].uppercased())
  }

  // MARK: - Masking

  private static let smallNumbers: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"
  ]

  /// Words that make an adjacent small number part of a larger expression ITN should write.
  private static let numberContext: Set<String> = smallNumbers.union([
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
    "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty",
    "ninety", "hundred", "thousand", "million", "billion", "trillion", "point", "oh",
    "percent", "dollar", "dollars", "cent", "cents", "pound", "pounds", "euro", "euros",
    "am", "pm", "a.m", "p.m", "o'clock",
    "january", "february", "march", "april", "june", "july", "august", "september",
    "october", "november", "december"
  ])

  /// Replaces each standalone small number word with a Supplementary Private Use Area sentinel
  /// (FluidAudio's own masks use the BMP Private Use Area, so the two never collide).
  private static func maskStandaloneSmallNumbers(in text: String) -> (String, [String: String]) {
    let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    let cores = tokens.map(core)
    var restore: [String: String] = [:]
    var output = tokens
    var nextSentinel: UInt32 = 0xF0000
    for index in tokens.indices where smallNumbers.contains(cores[index]) {
      let previous = index > 0 ? cores[index - 1] : ""
      let next = index + 1 < cores.count ? cores[index + 1] : ""
      guard !numberContext.contains(previous), !numberContext.contains(next),
            let scalar = UnicodeScalar(nextSentinel),
            let range = tokens[index].range(of: cores[index], options: .caseInsensitive) else { continue }
      nextSentinel += 1
      let sentinel = String(Character(scalar))
      restore[sentinel] = String(tokens[index][range])
      output[index] = tokens[index].replacingCharacters(in: range, with: sentinel)
    }
    return (output.joined(separator: " "), restore)
  }

  /// A token lower-cased without surrounding punctuation ("p.m." -> "p.m", "Nine," -> "nine").
  private static func core(_ token: String) -> String {
    token.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(["'"]))
  }

  private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
    text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
  }
}
