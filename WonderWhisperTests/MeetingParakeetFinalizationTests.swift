import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Regression for review round 2, finding 1: vocabulary corrections must be
/// mapped only after every source has finished and emitted its final tokens.
struct MeetingParakeetFinalizationTests {
  actor FakeStream: MeetingParakeetStream {
    private let finalText: String
    private var pending: [TokenTiming]

    init(finalText: String, finalTokens: [(String, Double)]) {
      self.finalText = finalText
      self.pending = finalTokens.enumerated().map { index, entry in
        TokenTiming(
          token: entry.0, tokenId: index, startTime: entry.1, endTime: entry.1 + 0.08, confidence: 1
        )
      }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {}
    func processBufferedAudio() async throws {}
    func finish() async throws -> String { finalText }
    func consumeTokenTimings() -> [TokenTiming] {
      defer { pending.removeAll() }
      return pending
    }
    func cleanup() async {}
  }

  /// Mirrors MeetingCoordinator: tokens are appended chronologically and
  /// corrections are applied to the whole session.
  actor Session {
    private(set) var tokens: [MeetingTranscriptToken] = []
    private(set) var events: [String] = []

    func receive(_ incoming: [MeetingTranscriptToken]) {
      events.append("tokens:\(incoming.first?.source.rawValue ?? "")")
      tokens = MeetingTranscriptFormatter.chronologicalTokens(tokens + incoming)
    }

    func receive(corrections: [MeetingTokenCorrection]) {
      events.append("corrections")
      tokens = MeetingVocabularyCorrector.apply(corrections, to: tokens)
    }
  }

  private static let systemTokens: [(String, Double)] = [
    (" We", 0), (" use", 0.2), (" hap", 0.4), (" anna", 2.0), (" for", 2.3), (" bookings", 2.5),
    (" daily", 2.9),
  ]

  private func finalize(micTail: [(String, Double)]) async throws -> Session {
    let session = Session()
    let service = MeetingTranscriptionService(
      engine: .parakeet,
      tokenHandler: { await session.receive($0) },
      correctionHandler: { await session.receive(corrections: $0) }
    )
    await service.installParakeetStreamsForTesting(
      system: FakeStream(finalText: "We use Hapana for bookings daily", finalTokens: Self.systemTokens),
      microphone: FakeStream(finalText: micTail.map(\.0).joined(), finalTokens: micTail),
      boostedSources: [.systemAudio, .microphone]
    )
    try await service.finish()
    return session
  }

  @Test func micTailEmittedDuringFinalizationBlocksACrossingCorrection() async throws {
    let session = try await finalize(micTail: [(" Right", 1.0)])

    // Both sources drained before any correction was mapped.
    #expect(await session.events == ["tokens:systemAudio", "tokens:microphone", "corrections"])
    let tokens = await session.tokens
    // "hap ... anna" spans the mic reply at 1 s, so it must not collapse.
    #expect(!tokens.contains { $0.text == " Hapana" })
    #expect(
      MeetingTranscriptFormatter.plainText(tokens: tokens)
        == "System audio: We use hap\nMicrophone: Right\nSystem audio: anna for bookings daily"
    )
  }

  @Test func correctionAppliesWhenNoOtherSourceSpokeInside() async throws {
    let session = try await finalize(micTail: [(" Thanks", 4.0)])
    let tokens = await session.tokens
    let hapana = try #require(tokens.first { $0.text == " Hapana" })
    #expect(hapana.startTime == 0.4)
    #expect(hapana.source == .systemAudio)
  }
}
