import Foundation
import FluidAudio

/// After a meeting whose live engine didn't split the call into voices (Parakeet), tells them
/// apart on this Mac and labels the call's transcript to match. Live cloud labels are kept:
/// on a short three-voice test call the on-Mac pass merged two voices that Grok had kept
/// apart. The transcript is left as it was when this fails.
actor MeetingSpeakerPassService {
  typealias Diarizer = @Sendable (MeetingSystemTrackAudioSource) async throws
    -> [MeetingSpeakerRelabeler.Segment]

  static let enabledDefaultsKey = "meeting.speakers.localPass"

  private let diarize: Diarizer

  init(diarize: @escaping Diarizer) {
    self.diarize = diarize
  }

  /// Production: FluidAudio's offline pyannote pipeline. Its models download on first use.
  init() {
    let runner = MeetingOfflineDiarizerRunner()
    diarize = { track in
      try await runner.segments(for: track)
    }
  }

  static func isEnabled(defaults: UserDefaults = AppConfig.defaults) -> Bool {
    defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
  }

  /// Whether the call side has words but no speaker labels yet.
  nonisolated static func needsPass(_ tokens: [MeetingTranscriptToken]) -> Bool {
    let call = tokens.filter { $0.source == .systemAudio }
    return !call.isEmpty && call.allSatisfy { $0.speaker == nil }
  }

  /// The tokens with the call's speakers labelled; nil when the call already has live labels,
  /// or there was no call audio or call transcript to place.
  func relabel(
    sessionDirectory: URL,
    audioFilenames: [String],
    tokens: [MeetingTranscriptToken]
  ) async throws -> [MeetingTranscriptToken]? {
    guard Self.needsPass(tokens),
          let track = MeetingSystemTrackAudioSource(
            sessionDirectory: sessionDirectory,
            audioFilenames: audioFilenames
          ) else { return nil }
    let startedAt = Date()
    let segments = try await diarize(track)
    let speakers = Set(segments.map(\.speaker)).count
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
    AppLog.dictation.log(
      "MeetingSpeakerPass: speakers=\(speakers, privacy: .public) seconds=\(elapsed, privacy: .public)"
    )
    guard !segments.isEmpty else { return nil }
    return MeetingSpeakerRelabeler.relabel(tokens, source: .systemAudio, segments: segments)
  }
}

/// Owns the CoreML diarizer so its models load once per app run.
private actor MeetingOfflineDiarizerRunner {
  private var manager: OfflineDiarizerManager?

  func segments(
    for track: MeetingSystemTrackAudioSource
  ) async throws -> [MeetingSpeakerRelabeler.Segment] {
    let manager = self.manager ?? OfflineDiarizerManager()
    try await manager.prepareModels()
    self.manager = manager
    let result = try await manager.process(audioSource: track, audioLoadingSeconds: 0)
    return result.segments.map {
      MeetingSpeakerRelabeler.Segment(
        speaker: $0.speakerId,
        startTime: track.startTime + Double($0.startTimeSeconds),
        endTime: track.startTime + Double($0.endTimeSeconds)
      )
    }
  }
}
