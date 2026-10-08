import Foundation

/// Replace a run of already-emitted live tokens with one corrected token.
struct MeetingTokenCorrection: Equatable, Sendable {
  let replacedTokenIDs: [UUID]
  let replacement: MeetingTranscriptToken
}

/// Maps Parakeet's vocabulary-rescored transcript back onto the live tokens.
///
/// Live meeting tokens are emitted as soon as Parakeet decodes them, but
/// FluidAudio's streaming vocabulary boosting only rewrites the transcript text
/// (in ~15 s segments), never the emitted token timings. At the end of the
/// meeting we diff the raw words against the rescored words and turn each
/// replaced run into a correction that keeps the original timing, so Me/Them
/// interleaving is untouched.
enum MeetingVocabularyCorrector {
  /// Above this share of changed words the alignment is not trusted and the
  /// raw transcript is kept.
  static let maximumChangedWordFraction = 0.25

  private struct Word {
    var text: String
    var tokens: [MeetingTranscriptToken]
  }

  static func corrections(
    rawTokens: [MeetingTranscriptToken],
    rescoredText: String
  ) -> [MeetingTokenCorrection] {
    let words = groupIntoWords(rawTokens)
    let rawWords = words.map(\.text)
    let newWords = rescoredText.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !rawWords.isEmpty, !newWords.isEmpty, rawWords != newWords else { return [] }

    let difference = newWords.difference(from: rawWords)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }
    let changed = max(removed.count, inserted.count)
    let allowed = max(2, Double(rawWords.count) * maximumChangedWordFraction)
    guard Double(changed) <= allowed else {
      return []
    }

    var corrections: [MeetingTokenCorrection] = []
    var rawIndex = 0
    var newIndex = 0
    while rawIndex < rawWords.count || newIndex < newWords.count {
      var hunkRemoved: [Int] = []
      var hunkInserted: [Int] = []
      while rawIndex < rawWords.count, removed.contains(rawIndex) {
        hunkRemoved.append(rawIndex)
        rawIndex += 1
      }
      while newIndex < newWords.count, inserted.contains(newIndex) {
        hunkInserted.append(newIndex)
        newIndex += 1
      }
      if hunkRemoved.isEmpty, hunkInserted.isEmpty {
        // Unchanged word in both sequences.
        rawIndex += 1
        newIndex += 1
        continue
      }
      // Pure insertions or deletions are not vocabulary swaps; keep the raw
      // words rather than invent or drop timing.
      guard !hunkRemoved.isEmpty, !hunkInserted.isEmpty else { continue }
      let tokens = hunkRemoved.flatMap { words[$0].tokens }
      guard let first = tokens.first, let last = tokens.last else { continue }
      let text = hunkInserted.map { newWords[$0] }.joined(separator: " ")
      corrections.append(MeetingTokenCorrection(
        replacedTokenIDs: tokens.map(\.id),
        replacement: MeetingTranscriptToken(
          source: first.source,
          startTime: first.startTime,
          endTime: max(first.startTime, last.endTime),
          text: " " + text,
          speaker: first.speaker
        )
      ))
    }
    return corrections
  }

  /// Apply corrections to a token list: each replaced run collapses into its
  /// replacement at the position of the run's first token. Corrections whose
  /// tokens are no longer all present are skipped.
  static func apply(
    _ corrections: [MeetingTokenCorrection],
    to tokens: [MeetingTranscriptToken]
  ) -> [MeetingTranscriptToken] {
    guard !corrections.isEmpty else { return tokens }
    let present = Set(tokens.map(\.id))
    var replacementAtFirstID: [UUID: MeetingTranscriptToken] = [:]
    var dropped = Set<UUID>()
    for correction in corrections {
      guard let firstID = correction.replacedTokenIDs.first,
            correction.replacedTokenIDs.allSatisfy({ present.contains($0) }) else { continue }
      replacementAtFirstID[firstID] = correction.replacement
      dropped.formUnion(correction.replacedTokenIDs)
    }
    var result: [MeetingTranscriptToken] = []
    result.reserveCapacity(tokens.count)
    for token in tokens {
      if let replacement = replacementAtFirstID[token.id] {
        result.append(replacement)
      } else if !dropped.contains(token.id) {
        result.append(token)
      }
    }
    return result
  }

  /// Group sub-word tokens into words. A token whose text starts with
  /// whitespace (Parakeet's `▁` marker) begins a new word.
  private static func groupIntoWords(_ tokens: [MeetingTranscriptToken]) -> [Word] {
    var words: [Word] = []
    for token in tokens {
      let startsWord = token.text.first?.isWhitespace ?? false
      let piece = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if startsWord || words.isEmpty {
        words.append(Word(text: piece, tokens: [token]))
      } else {
        words[words.count - 1].text += piece
        words[words.count - 1].tokens.append(token)
      }
    }
    // A bare separator token yields an empty word only if nothing follows it.
    return words.filter { !$0.text.isEmpty }
  }
}
