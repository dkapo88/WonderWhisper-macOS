import Foundation

/// Puts the on-Mac diarizer's speakers onto a transcript. Each diarizer speaker takes the
/// existing label it shares the most words with, so names already given stay with the same
/// voice; other speakers get new labels after the highest one.
enum MeetingSpeakerRelabeler {
  struct Segment: Equatable, Sendable {
    let speaker: String
    let startTime: TimeInterval
    let endTime: TimeInterval
  }

  /// Tokens longer than this (a recovered minute of text) can't be placed with one voice.
  static let maximumWordDuration: TimeInterval = 8
  /// How far from a diarized segment a word may sit and still belong to it.
  static let nearestSegmentTolerance: TimeInterval = 0.5

  private struct Word {
    var tokenIndices: [Int]
    var startTime: TimeInterval
    var endTime: TimeInterval
  }

  static func relabel(
    _ tokens: [MeetingTranscriptToken],
    source: MeetingAudioSource = .systemAudio,
    segments: [Segment]
  ) -> [MeetingTranscriptToken] {
    let segments = segments
      .filter { $0.endTime > $0.startTime }
      .sorted { $0.startTime < $1.startTime }
    guard !segments.isEmpty else { return tokens }
    let words = words(in: tokens, source: source)

    var assignments: [Int: String] = [:]
    var cooccurrence: [String: [String: Int]] = [:]
    var firstWordIndex: [String: Int] = [:]
    for (wordIndex, word) in words.enumerated() {
      guard word.endTime - word.startTime <= maximumWordDuration,
            let speaker = speaker(for: word, segments: segments) else { continue }
      assignments[wordIndex] = speaker
      if firstWordIndex[speaker] == nil { firstWordIndex[speaker] = wordIndex }
      if let label = liveLabel(of: word, in: tokens) {
        cooccurrence[speaker, default: [:]][label, default: 0] += 1
      }
    }
    guard !assignments.isEmpty else { return tokens }

    let labels = labelMap(
      cooccurrence: cooccurrence,
      speakersInOrder: firstWordIndex.sorted { $0.value < $1.value }.map(\.key),
      existingLabels: Set(tokens.filter { $0.source == source }.compactMap(\.speaker))
    )

    var result = tokens
    for (wordIndex, speaker) in assignments {
      guard let label = labels[speaker] else { continue }
      for index in words[wordIndex].tokenIndices {
        let token = result[index]
        result[index] = MeetingTranscriptToken(
          id: token.id,
          source: token.source,
          startTime: token.startTime,
          endTime: token.endTime,
          text: token.text,
          speaker: label
        )
      }
    }
    return result
  }

  /// Diarizer speaker to transcript label: the strongest pairs first, one to one.
  static func labelMap(
    cooccurrence: [String: [String: Int]],
    speakersInOrder: [String],
    existingLabels: Set<String>
  ) -> [String: String] {
    let pairs = cooccurrence.flatMap { speaker, labels in
      labels.map { (speaker: speaker, label: $0.key, count: $0.value) }
    }.sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      if lhs.speaker != rhs.speaker { return lhs.speaker < rhs.speaker }
      return lhs.label < rhs.label
    }
    var result: [String: String] = [:]
    var usedLabels: Set<String> = []
    for pair in pairs where result[pair.speaker] == nil && !usedLabels.contains(pair.label) {
      result[pair.speaker] = pair.label
      usedLabels.insert(pair.label)
    }
    var nextLabel = (existingLabels.compactMap { Int($0) }.max() ?? 0) + 1
    for speaker in speakersInOrder where result[speaker] == nil {
      while existingLabels.contains(String(nextLabel)) || usedLabels.contains(String(nextLabel)) {
        nextLabel += 1
      }
      result[speaker] = String(nextLabel)
      usedLabels.insert(String(nextLabel))
      nextLabel += 1
    }
    return result
  }

  /// A source's tokens grouped into words, so a word is never split between two voices. A
  /// token starting with whitespace, or after a pause, starts a new word.
  private static func words(
    in tokens: [MeetingTranscriptToken],
    source: MeetingAudioSource
  ) -> [Word] {
    let indices = tokens.indices
      .filter { tokens[$0].source == source && !tokens[$0].text.isEmpty }
      .sorted { lhs, rhs in
        if tokens[lhs].startTime != tokens[rhs].startTime {
          return tokens[lhs].startTime < tokens[rhs].startTime
        }
        return lhs < rhs
      }
    var result: [Word] = []
    for index in indices {
      let token = tokens[index]
      let startsWord = token.text.first?.isWhitespace == true
        || result.last.map { token.startTime - $0.endTime > 0.3 } ?? true
      if startsWord || result.isEmpty {
        result.append(Word(
          tokenIndices: [index],
          startTime: token.startTime,
          endTime: max(token.startTime, token.endTime)
        ))
      } else {
        result[result.count - 1].tokenIndices.append(index)
        result[result.count - 1].endTime = max(result[result.count - 1].endTime, token.endTime)
      }
    }
    return result
  }

  private static func speaker(for word: Word, segments: [Segment]) -> String? {
    let start = word.startTime
    let end = max(word.endTime, start + 0.05)
    var overlaps: [String: TimeInterval] = [:]
    var nearest: (speaker: String, distance: TimeInterval)?
    for segment in segments {
      if segment.startTime > end + nearestSegmentTolerance { break }
      let overlap = min(end, segment.endTime) - max(start, segment.startTime)
      if overlap > 0 {
        overlaps[segment.speaker, default: 0] += overlap
      } else {
        let distance = max(segment.startTime - end, start - segment.endTime)
        if distance <= nearestSegmentTolerance, distance < (nearest?.distance ?? .infinity) {
          nearest = (segment.speaker, distance)
        }
      }
    }
    if let best = overlaps.max(by: { lhs, rhs in
      lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
    }) {
      return best.key
    }
    return nearest?.speaker
  }

  private static func liveLabel(of word: Word, in tokens: [MeetingTranscriptToken]) -> String? {
    var counts: [String: Int] = [:]
    for index in word.tokenIndices {
      if let speaker = tokens[index].speaker { counts[speaker, default: 0] += 1 }
    }
    return counts.max { lhs, rhs in
      lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
    }?.key
  }
}
