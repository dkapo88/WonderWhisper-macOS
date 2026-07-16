import Foundation

enum MeetingAudioSource: String, Codable, CaseIterable, Hashable, Sendable {
  case microphone
  case systemAudio
  case mixed

  static let captureSources: Set<Self> = [.microphone, .systemAudio]

  var displayName: String {
    switch self {
    case .microphone: return "Microphone"
    case .systemAudio: return "System audio"
    case .mixed: return "Meeting"
    }
  }

  var filenamePrefix: String {
    switch self {
    case .microphone: return "microphone"
    case .systemAudio: return "system"
    case .mixed: return "mixed"
    }
  }
}

enum MeetingTranscriptionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
  case parakeet
  case soniox
  case sonioxSeparate = "soniox-separate"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .parakeet: return "Parakeet Unified (On-device)"
    case .soniox: return "Soniox V5 (Single stream beta)"
    case .sonioxSeparate: return "Soniox V5 (Separate streams)"
    }
  }

  var recordingLabel: String {
    switch self {
    case .parakeet: return "local Parakeet"
    case .soniox: return "single-stream Soniox V5 beta"
    case .sonioxSeparate: return "separate-stream Soniox V5"
    }
  }

  var detail: String {
    switch self {
    case .parakeet:
      return "Private and free. Best when cloud audio must stay off."
    case .soniox:
      return "Locally aligns and echo-reduces both sources before one cloud stream."
    case .sonioxSeparate:
      return "Fallback with independent microphone and system-audio cloud streams."
    }
  }

  var usesSoniox: Bool {
    self == .soniox || self == .sonioxSeparate
  }

  static func selected(defaults: UserDefaults = .standard) -> Self {
    guard let stored = defaults.string(forKey: "meeting.transcription.engine"),
          let value = Self(rawValue: stored) else {
      return .parakeet
    }
    return value
  }
}

struct MeetingTranscriptToken: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let source: MeetingAudioSource
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let speaker: String?

  init(id: UUID = UUID(),
       source: MeetingAudioSource,
       startTime: TimeInterval,
       endTime: TimeInterval,
       text: String,
       speaker: String? = nil) {
    self.id = id
    self.source = source
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.speaker = speaker
  }
}

enum MeetingStatus: String, Codable, Sendable {
  case recording
  case processing
  case completed
  case interrupted
  case failed

  var isTerminal: Bool {
    switch self {
    case .completed, .interrupted, .failed:
      return true
    case .recording, .processing:
      return false
    }
  }
}

struct MeetingSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var title: String
  let startedAt: Date
  var endedAt: Date?
  var detectedApp: String?
  var automaticallyStarted: Bool
  var transcriptionEngine: MeetingTranscriptionEngine?
  var status: MeetingStatus
  var transcriptTokens: [MeetingTranscriptToken]
  var manualNotesMarkdown: String?
  var notesMarkdown: String?
  var audioFiles: [String]
  var exportedMarkdownPath: String?
  var errorMessage: String?

  init(id: UUID = UUID(),
       title: String,
       startedAt: Date = Date(),
       endedAt: Date? = nil,
       detectedApp: String? = nil,
       automaticallyStarted: Bool = false,
       transcriptionEngine: MeetingTranscriptionEngine? = nil,
       status: MeetingStatus = .recording,
       transcriptTokens: [MeetingTranscriptToken] = [],
       manualNotesMarkdown: String? = nil,
       notesMarkdown: String? = nil,
       audioFiles: [String] = [],
       exportedMarkdownPath: String? = nil,
       errorMessage: String? = nil) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.detectedApp = detectedApp
    self.automaticallyStarted = automaticallyStarted
    self.transcriptionEngine = transcriptionEngine
    self.status = status
    self.transcriptTokens = transcriptTokens
    self.manualNotesMarkdown = manualNotesMarkdown
    self.notesMarkdown = notesMarkdown
    self.audioFiles = audioFiles
    self.exportedMarkdownPath = exportedMarkdownPath
    self.errorMessage = errorMessage
  }

  var duration: TimeInterval {
    max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
  }

  var transcriptMarkdown: String {
    MeetingTranscriptFormatter.markdown(tokens: transcriptTokens)
  }
}

struct MeetingTranscriptBlock: Identifiable, Equatable, Sendable {
  let id: UUID
  let source: MeetingAudioSource
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let speaker: String?

  var displayName: String {
    if source != .microphone, let speaker, !speaker.isEmpty {
      return "Speaker \(speaker)"
    }
    return source.displayName
  }
}

enum MeetingTranscriptFormatter {
  private struct BlockKey: Hashable {
    let source: MeetingAudioSource
    let speaker: String?
  }

  static func chronologicalTokens(
    _ tokens: [MeetingTranscriptToken]
  ) -> [MeetingTranscriptToken] {
    if zip(tokens, tokens.dropFirst()).allSatisfy({
      $0.startTime <= $1.startTime
    }) {
      return tokens
    }
    return tokens.enumerated().sorted { lhs, rhs in
      if lhs.element.startTime != rhs.element.startTime {
        return lhs.element.startTime < rhs.element.startTime
      }
      // RNNT subword pieces commonly share a frame timestamp. Preserve their
      // emission order instead of using UUIDs, which scrambles words at ties.
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  static func recentTokens(
    _ tokens: [MeetingTranscriptToken],
    duration: TimeInterval
  ) -> [MeetingTranscriptToken] {
    guard let latestEndTime = tokens.map(\.endTime).max() else { return [] }
    let cutoff = latestEndTime - max(0, duration)
    return chronologicalTokens(tokens.filter { $0.endTime >= cutoff })
  }

  static func blocks(tokens: [MeetingTranscriptToken]) -> [MeetingTranscriptBlock] {
    let sorted = chronologicalTokens(MeetingEchoSuppressor.filteredTokens(tokens))
    var result: [MeetingTranscriptBlock] = []
    var latestBlockIndex: [BlockKey: Int] = [:]

    for token in sorted where !token.text.isEmpty {
      let key = BlockKey(source: token.source, speaker: token.speaker)
      if let index = latestBlockIndex[key],
         token.startTime - result[index].endTime < 2.5,
         index == result.count - 1 || token.startTime < result[result.count - 1].endTime {
        let last = result[index]
        result[index] = MeetingTranscriptBlock(
          id: last.id,
          source: last.source,
          startTime: last.startTime,
          endTime: max(last.endTime, token.endTime),
          text: last.text + token.text,
          speaker: last.speaker
        )
      } else {
        latestBlockIndex[key] = result.count
        result.append(
          MeetingTranscriptBlock(
            id: token.id,
            source: token.source,
            startTime: token.startTime,
            endTime: token.endTime,
            text: token.text,
            speaker: token.speaker
          )
        )
      }
    }

    return result.sorted { lhs, rhs in
      lhs.startTime < rhs.startTime
    }.map {
      MeetingTranscriptBlock(
        id: $0.id,
        source: $0.source,
        startTime: $0.startTime,
        endTime: $0.endTime,
        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
        speaker: $0.speaker
      )
    }.filter { !$0.text.isEmpty }
  }

  static func markdown(tokens: [MeetingTranscriptToken]) -> String {
    blocks(tokens: tokens).map { block in
      "**\(block.displayName) [\(timestamp(block.startTime))]:** \(block.text)"
    }.joined(separator: "\n\n")
  }

  static func plainText(tokens: [MeetingTranscriptToken]) -> String {
    blocks(tokens: tokens).map { block in
      "\(block.displayName): \(block.text)"
    }.joined(separator: "\n")
  }

  static func timestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}

enum MeetingEchoSuppressor {
  private static let minimumEchoLag: TimeInterval = -0.25
  private static let maximumEchoLag: TimeInterval = 2
  private static let maximumLagVariation: TimeInterval = 0.75

  private struct Word {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let tokenIDs: Set<UUID>
  }

  private struct Match {
    let microphoneWordCount: Int
    let exactWordCount: Int
    let minimumLag: TimeInterval
  }

  private struct WordBucket: Hashable {
    let text: String
    let bucket: Int
  }

  static func filteredTokens(_ tokens: [MeetingTranscriptToken]) -> [MeetingTranscriptToken] {
    let microphoneWords = words(in: tokens, source: .microphone)
    let systemWords = words(in: tokens, source: .systemAudio)
    guard microphoneWords.count >= 4, systemWords.count >= 4 else { return tokens }

    let systemPositions = Dictionary(grouping: systemWords.indices) {
      WordBucket(
        text: systemWords[$0].text,
        bucket: Int((systemWords[$0].startTime / 2).rounded(.down))
      )
    }
    var suppressedTokenIDs: Set<UUID> = []
    var suppressedPunctuationRanges: [ClosedRange<TimeInterval>] = []
    var microphoneIndex = 0

    while microphoneIndex < microphoneWords.count {
      let microphoneWord = microphoneWords[microphoneIndex]
      var bestMatch = Match(
        microphoneWordCount: 0,
        exactWordCount: 0,
        minimumLag: 0
      )

      let microphoneBucket = Int((microphoneWord.startTime / 2).rounded(.down))
      let candidateIndices = (-2...2).flatMap {
        systemPositions[
          WordBucket(text: microphoneWord.text, bucket: microphoneBucket + $0)
        ] ?? []
      }
      for systemIndex in candidateIndices {
        let initialLag = microphoneWord.startTime - systemWords[systemIndex].startTime
        guard minimumEchoLag...maximumEchoLag ~= initialLag else { continue }

        let match = matchLength(
          microphoneWords: microphoneWords,
          microphoneIndex: microphoneIndex,
          systemWords: systemWords,
          systemIndex: systemIndex,
          initialLag: initialLag
        )
        if match.exactWordCount > bestMatch.exactWordCount
          || (match.exactWordCount == bestMatch.exactWordCount
            && match.microphoneWordCount > bestMatch.microphoneWordCount) {
          bestMatch = match
        }
      }

      let characterCount = microphoneWords[
        microphoneIndex..<min(
          microphoneIndex + bestMatch.microphoneWordCount,
          microphoneWords.count
        )
      ].reduce(0) { $0 + $1.text.count }
      let hasStrongMatch = bestMatch.exactWordCount >= 4
        && bestMatch.exactWordCount * 5 >= bestMatch.microphoneWordCount * 4
        && characterCount >= 18
      let negativeLagIsHighConfidence = bestMatch.minimumLag >= 0
        || (bestMatch.exactWordCount == bestMatch.microphoneWordCount
          && bestMatch.exactWordCount >= 6
          && characterCount >= 30)
      if hasStrongMatch, negativeLagIsHighConfidence {
        let matchedWords = microphoneWords[
          microphoneIndex..<(microphoneIndex + bestMatch.microphoneWordCount)
        ]
        for word in matchedWords {
          suppressedTokenIDs.formUnion(word.tokenIDs)
        }
        if let firstWord = matchedWords.first, let lastWord = matchedWords.last {
          suppressedPunctuationRanges.append(firstWord.startTime...lastWord.endTime)
        }
        microphoneIndex += bestMatch.microphoneWordCount
      } else {
        microphoneIndex += 1
      }
    }

    guard !suppressedTokenIDs.isEmpty else { return tokens }
    return tokens.filter { token in
      guard token.source == .microphone else { return true }
      if suppressedTokenIDs.contains(token.id) { return false }
      let containsWordCharacter = token.text.contains {
        $0.isLetter || $0.isNumber
      }
      guard !containsWordCharacter else { return true }
      return !suppressedPunctuationRanges.contains {
        $0.overlaps(token.startTime...token.endTime)
      }
    }
  }

  private static func matchLength(
    microphoneWords: [Word],
    microphoneIndex: Int,
    systemWords: [Word],
    systemIndex: Int,
    initialLag: TimeInterval
  ) -> Match {
    var microphoneOffset = 0
    var systemOffset = 0
    var exactWordCount = 0
    var disagreementCount = 0
    var minimumLag = TimeInterval.greatestFiniteMagnitude

    while microphoneIndex + microphoneOffset < microphoneWords.count,
          systemIndex + systemOffset < systemWords.count {
      let microphoneWord = microphoneWords[microphoneIndex + microphoneOffset]
      let systemWord = systemWords[systemIndex + systemOffset]
      let lag = microphoneWord.startTime - systemWord.startTime
      guard minimumEchoLag...maximumEchoLag ~= lag,
            abs(lag - initialLag) <= maximumLagVariation else { break }
      minimumLag = min(minimumLag, lag)

      if microphoneWord.text == systemWord.text {
        exactWordCount += 1
      } else {
        guard areNearEquivalent(microphoneWord.text, systemWord.text) else { break }
        disagreementCount += 1
        guard disagreementCount <= 1 else { break }
      }
      microphoneOffset += 1
      systemOffset += 1
    }

    return Match(
      microphoneWordCount: microphoneOffset,
      exactWordCount: exactWordCount,
      minimumLag: minimumLag
    )
  }

  private static func areNearEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    guard lhs.allSatisfy(\.isLetter), rhs.allSatisfy(\.isLetter) else {
      return false
    }
    let shorter = lhs.count < rhs.count ? lhs : rhs
    let longer = lhs.count < rhs.count ? rhs : lhs
    return shorter.count >= 5 && longer == shorter + "s"
  }

  private static func words(
    in tokens: [MeetingTranscriptToken],
    source: MeetingAudioSource
  ) -> [Word] {
    let sourceTokens = MeetingTranscriptFormatter.chronologicalTokens(
      tokens.filter { $0.source == source }
    )
    var result: [Word] = []
    var text = ""
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var tokenIDs: Set<UUID> = []

    func flush() {
      guard !text.isEmpty else { return }
      result.append(
        Word(
          text: text,
          startTime: startTime,
          endTime: endTime,
          tokenIDs: tokenIDs
        )
      )
      text = ""
      endTime = 0
      tokenIDs.removeAll(keepingCapacity: true)
    }

    for token in sourceTokens {
      for character in token.text {
        if character.isLetter || character.isNumber {
          if text.isEmpty { startTime = token.startTime }
          endTime = max(endTime, token.endTime)
          text.append(contentsOf: character.lowercased())
          tokenIDs.insert(token.id)
        } else if character == "'" || character == "’" {
          continue
        } else {
          flush()
        }
      }
    }
    flush()
    return result
  }
}
