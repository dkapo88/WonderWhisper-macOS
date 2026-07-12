import AVFoundation
import Foundation

actor MeetingTranscriptRecoveryService {
  static let segmentDuration: TimeInterval = 60

  typealias FileTranscriber = @Sendable (URL) async throws -> String

  struct Segment: Equatable, Sendable {
    let filename: String
    let source: MeetingAudioSource
    let index: Int
    let startTime: TimeInterval
    let duration: TimeInterval

    var endTime: TimeInterval { startTime + duration }
  }

  struct RecoveryPlan: Equatable, Sendable {
    let retainedTokens: [MeetingTranscriptToken]
    let segmentsToTranscribe: [Segment]
    let recoverableSources: Set<MeetingAudioSource>
  }

  struct RecoveryResult: Equatable, Sendable {
    let tokens: [MeetingTranscriptToken]
    let recoveredSources: Set<MeetingAudioSource>
  }

  enum RecoveryError: LocalizedError {
    case unreadableAudioFile(String, String)

    var errorDescription: String? {
      switch self {
      case .unreadableAudioFile(let filename, let message):
        return "Could not read meeting audio segment \(filename): \(message)"
      }
    }
  }

  private let transcribeFile: FileTranscriber

  init(transcribeFile: @escaping FileTranscriber) {
    self.transcribeFile = transcribeFile
  }

  /// Production convenience. Recovery is always local and explicitly forces
  /// Parakeet Unified, independent of the user's dictation model selection.
  init() {
    let transcriber = MeetingParakeetUnifiedFileTranscriber()
    self.transcribeFile = { url in
      try await transcriber.transcribe(url)
    }
  }

  func recover(
    sessionDirectory: URL,
    audioFilenames: [String],
    existingTokens: [MeetingTranscriptToken],
    sourcesNeedingRecovery: Set<MeetingAudioSource>,
    fullRecoverySources: Set<MeetingAudioSource> = []
  ) async throws -> RecoveryResult {
    guard !sourcesNeedingRecovery.isEmpty else {
      return RecoveryResult(
        tokens: MeetingTranscriptFormatter.chronologicalTokens(existingTokens),
        recoveredSources: []
      )
    }

    let segments = try readableSegments(
      sessionDirectory: sessionDirectory,
      audioFilenames: audioFilenames,
      sources: sourcesNeedingRecovery
    )
    let plan = Self.recoveryPlan(
      segments: segments,
      existingTokens: existingTokens,
      sourcesNeedingRecovery: sourcesNeedingRecovery,
      fullRecoverySources: fullRecoverySources
    )
    var recoveredTokens: [MeetingTranscriptToken] = []

    for segment in plan.segmentsToTranscribe {
      let url = sessionDirectory.appendingPathComponent(segment.filename)
      let transcript = try await transcribeFile(url)
      if let token = Self.recoveredToken(segment: segment, transcript: transcript) {
        recoveredTokens.append(token)
      }
    }

    return RecoveryResult(
      tokens: MeetingTranscriptFormatter.chronologicalTokens(
        plan.retainedTokens + recoveredTokens
      ),
      recoveredSources: plan.recoverableSources
    )
  }

  nonisolated static func segment(
    filename: String,
    duration: TimeInterval
  ) -> Segment? {
    guard duration.isFinite, duration > 0 else { return nil }
    let url = URL(fileURLWithPath: filename)
    guard url.lastPathComponent == filename,
          url.pathExtension.lowercased() == "caf" else { return nil }
    let stem = url.deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let index = Int(parts[1]),
          index > 0 else { return nil }

    let source: MeetingAudioSource
    switch parts[0] {
    case "microphone": source = .microphone
    case "system": source = .systemAudio
    default: return nil
    }

    return Segment(
      filename: filename,
      source: source,
      index: index,
      startTime: Double(index - 1) * segmentDuration,
      duration: duration
    )
  }

  nonisolated static func recoveryPlan(
    segments: [Segment],
    existingTokens: [MeetingTranscriptToken],
    sourcesNeedingRecovery: Set<MeetingAudioSource>,
    fullRecoverySources: Set<MeetingAudioSource> = []
  ) -> RecoveryPlan {
    var retained = existingTokens
    var selected: [Segment] = []
    var recoverableSources: Set<MeetingAudioSource> = []

    let availableRawSources = Set(segments.map(\.source))
    if sourcesNeedingRecovery.isSuperset(of: MeetingAudioSource.captureSources),
       availableRawSources.isSuperset(of: MeetingAudioSource.captureSources),
       existingTokens.contains(where: { $0.source == .mixed }) {
      let firstRawSegmentStart = segments
        .filter { MeetingAudioSource.captureSources.contains($0.source) }
        .map(\.startTime)
        .min() ?? 0
      retained.removeAll {
        $0.source == .mixed
          && ($0.startTime >= firstRawSegmentStart || $0.endTime > firstRawSegmentStart)
      }
    }

    for source in sourcesNeedingRecovery.sorted(by: { $0.rawValue < $1.rawValue }) {
      let sourceSegments = orderedSegments(segments.filter { $0.source == source })
      guard let firstAvailable = sourceSegments.first else { continue }
      let tailTime = existingTokens
        .filter { $0.source == source }
        .map { max($0.startTime, $0.endTime) }
        .max()

      var firstRecoverySegment = firstAvailable
      if !fullRecoverySources.contains(source), let tailTime {
        firstRecoverySegment = sourceSegments.first {
          tailTime >= $0.startTime && tailTime < $0.endTime
        } ?? sourceSegments.last {
          $0.startTime <= tailTime
        } ?? firstAvailable
      }

      let recoveryStart = firstRecoverySegment.startTime
      retained.removeAll { token in
        guard token.source == source else { return false }
        return token.startTime >= recoveryStart || token.endTime > recoveryStart
      }
      selected.append(contentsOf: sourceSegments.filter {
        $0.index >= firstRecoverySegment.index
      })
      recoverableSources.insert(source)
    }

    return RecoveryPlan(
      retainedTokens: MeetingTranscriptFormatter.chronologicalTokens(retained),
      segmentsToTranscribe: orderedSegments(selected),
      recoverableSources: recoverableSources
    )
  }

  nonisolated static func recoveredToken(
    segment: Segment,
    transcript: String
  ) -> MeetingTranscriptToken? {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return MeetingTranscriptToken(
      source: segment.source,
      startTime: segment.startTime,
      endTime: segment.endTime,
      text: " \(text)"
    )
  }

  private nonisolated static func orderedSegments(
    _ segments: [Segment]
  ) -> [Segment] {
    segments.sorted { lhs, rhs in
      if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
      if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
      if lhs.index != rhs.index { return lhs.index < rhs.index }
      return lhs.filename < rhs.filename
    }
  }

  private func readableSegments(
    sessionDirectory: URL,
    audioFilenames: [String],
    sources: Set<MeetingAudioSource>
  ) throws -> [Segment] {
    var result: [Segment] = []
    var seen: Set<String> = []
    for filename in audioFilenames {
      guard let parsed = Self.segment(filename: filename, duration: 1),
            sources.contains(parsed.source),
            seen.insert(parsed.filename).inserted else { continue }
      let url = sessionDirectory.appendingPathComponent(parsed.filename)
      do {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0,
              let segment = Self.segment(
                filename: parsed.filename,
                duration: Double(file.length) / sampleRate
              ) else { continue }
        result.append(segment)
      } catch {
        throw RecoveryError.unreadableAudioFile(
          parsed.filename,
          error.localizedDescription
        )
      }
    }
    return Self.orderedSegments(result)
  }
}

private actor MeetingParakeetUnifiedFileTranscriber {
  private let provider = ParakeetTranscriptionProvider()
  private let settings = TranscriptionSettings(
    endpoint: URL(fileURLWithPath: "/"),
    model: "parakeet-unified",
    timeout: 600,
    language: "en",
    context: "meeting-tail-recovery"
  )

  func transcribe(_ url: URL) async throws -> String {
    try await provider.transcribe(fileURL: url, settings: settings)
  }
}
