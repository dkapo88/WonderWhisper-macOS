import Foundation
import AVFoundation
import FluidAudio
import Testing
@testable import WonderWhisper

/// Opt-in end-to-end check of the on-device models. Downloads models on first run.
///
/// Run with:
/// `TEST_RUNNER_WW_PARAKEET_E2E=1 xcodebuild test ...
///   -only-testing:WonderWhisperTests/ParakeetVocabularyE2ETests`
/// Results (text + timings) go to `WW_PARAKEET_E2E_OUT`, default `/tmp/ww-parakeet-e2e.txt`.
@Suite(.serialized)
struct ParakeetVocabularyE2ETests {
  private static let environment = ProcessInfo.processInfo.environment
  private static let isEnabled = environment["WW_PARAKEET_E2E"] == "1"
  private static let outputPath = environment["WW_PARAKEET_E2E_OUT"] ?? "/tmp/ww-parakeet-e2e.txt"
  private static let phrase = "Please forward the Ezypay invoice to Niamh and Jarron at Hapana "
    + "before Friday, and copy Biso on the thread."
  private static let terms = ["Hapana", "Niamh", "Jarron", "Ezypay", "Biso"]

  @Test(.enabled(if: isEnabled))
  func unifiedWithAndWithoutVocabularyAndUltraTranscribeSpeech() async throws {
    let wav = try Self.makeSpeechClip()
    var report = ["phrase: \(Self.phrase)", "terms: \(Self.terms.joined(separator: ", "))",
                  "ctc present before run: \(ParakeetVocabularyBoosting.ctcModelsPresent())"]

    let unified = ParakeetTranscriptionProvider(waitsForVocabularyModel: true)
    let plainCold = try await Self.run(unified, model: "parakeet-unified", terms: [], wav: wav)
    let plainWarm = try await Self.run(unified, model: "parakeet-unified", terms: [], wav: wav)
    let boostedFirst = try await Self.run(unified, model: "parakeet-unified", terms: Self.terms, wav: wav)
    let boostedWarm = try await Self.run(unified, model: "parakeet-unified", terms: Self.terms, wav: wav)
    report.append("unified plain (cold) \(plainCold.ms)ms: \(plainCold.text)")
    report.append("unified plain (warm) \(plainWarm.ms)ms: \(plainWarm.text)")
    report.append("unified boosted (configure) \(boostedFirst.ms)ms: \(boostedFirst.text)")
    report.append("unified boosted (warm) \(boostedWarm.ms)ms: \(boostedWarm.text)")
    report.append("terms hit plain=\(Self.hits(plainWarm.text)) boosted=\(Self.hits(boostedWarm.text))")
    try Self.write(report)

    let ultra = ParakeetTranscriptionProvider(waitsForVocabularyModel: true)
    let ultraCold = try await Self.run(ultra, model: "parakeet-ultra", terms: Self.terms, wav: wav)
    let ultraWarm = try await Self.run(ultra, model: "parakeet-ultra", terms: Self.terms, wav: wav)
    report.append("ultra (cold, includes download/compile) \(ultraCold.ms)ms: \(ultraCold.text)")
    report.append("ultra (warm) \(ultraWarm.ms)ms: \(ultraWarm.text)")
    report.append("terms hit ultra=\(Self.hits(ultraWarm.text))")
    report.append("unified present=\(ParakeetManager.modelsPresent(for: .unified)) "
      + "ultra present=\(ParakeetManager.modelsPresent(for: .ultra)) "
      + "ctc present=\(ParakeetVocabularyBoosting.ctcModelsPresent())")
    try Self.write(report)

    #expect(!plainWarm.text.isEmpty)
    #expect(!boostedWarm.text.isEmpty)
    #expect(!ultraWarm.text.isEmpty)
    #expect(Self.hits(boostedWarm.text) >= Self.hits(plainWarm.text))
  }

  /// Review P1 with real models: disabling boosting after it was configured
  /// must not reload Unified on the transcription path, and the next
  /// transcription is unboosted.
  @Test(.enabled(if: isEnabled))
  func disablingBoostingDoesNotReloadUnified() async throws {
    let wav = try Self.makeSpeechClip()
    final class Flag: @unchecked Sendable { var on = true }
    let flag = Flag()
    let provider = ParakeetTranscriptionProvider(
      waitsForVocabularyModel: true,
      boostingEnabled: { flag.on }
    )
    let plain = try await Self.run(provider, model: "parakeet-unified", terms: [], wav: wav)
    let boosted = try await Self.run(provider, model: "parakeet-unified", terms: Self.terms, wav: wav)
    flag.on = false
    let off = try await Self.run(provider, model: "parakeet-unified", terms: Self.terms, wav: wav)
    try ([
      "p1 plain \(plain.ms)ms: \(plain.text)",
      "p1 boosted \(boosted.ms)ms: \(boosted.text)",
      "p1 disabled (neutralized, no reload) \(off.ms)ms: \(off.text)",
    ].joined(separator: "\n") + "\n").write(toFile: Self.outputPath + ".p1", atomically: true, encoding: .utf8)

    #expect(off.text == plain.text)
    // A reload of Unified takes seconds; neutralizing is a ~10 ms configure.
    #expect(off.ms < 5_000)
  }

  /// The live-meeting path: stream the clip through a boosted
  /// StreamingUnifiedAsrManager, collect tokens as the meeting service does,
  /// then map the rescored final text back onto them.
  @Test(.enabled(if: isEnabled))
  func streamingMeetingCorrectionsMapRescoredTextOntoLiveTokens() async throws {
    let wav = try Self.makeSpeechClip()
    let ctcModels = try #require(await ParakeetCtcModelStore.shared.modelsIfAvailable())
    let manager = StreamingUnifiedAsrManager()
    try await manager.loadModels(to: ParakeetManager.modelsDirectory)
    try await manager.configureVocabularyBoosting(
      vocabulary: ParakeetVocabularyBoosting.vocabularyContext(for: Self.terms),
      ctcModels: ctcModels
    )

    let file = try AVAudioFile(forReading: wav)
    let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 2)
    var tokens: [MeetingTranscriptToken] = []
    func drain() async {
      tokens += await manager.consumeTokenTimings().map {
        MeetingTranscriptToken(source: .microphone, startTime: $0.startTime, endTime: $0.endTime, text: $0.token)
      }
    }
    while file.framePosition < file.length {
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
      )
      try file.read(into: buffer, frameCount: chunkFrames)
      try await manager.appendAudio(buffer)
      try await manager.processBufferedAudio()
      await drain()
    }
    let rescored = try await manager.finish()
    await drain()

    let corrections = MeetingVocabularyCorrector.corrections(rawTokens: tokens, rescoredText: rescored)
    let corrected = MeetingVocabularyCorrector.apply(corrections, to: tokens)
    let raw = tokens.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    let fixed = corrected.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    let report = [
      "meeting raw tokens: \(raw)",
      "meeting rescored:   \(rescored)",
      "meeting corrected:  \(fixed)",
      "meeting corrections=\(corrections.count) hits raw=\(Self.hits(raw)) corrected=\(Self.hits(fixed))",
    ]
    try (report.joined(separator: "\n") + "\n")
      .write(toFile: Self.outputPath + ".meeting", atomically: true, encoding: .utf8)

    #expect(!raw.isEmpty)
    #expect(Self.hits(fixed) >= Self.hits(raw))
    #expect(Self.hits(fixed) == Self.hits(rescored))
  }

  private static func run(
    _ provider: ParakeetTranscriptionProvider,
    model: String,
    terms: [String],
    wav: URL
  ) async throws -> (text: String, ms: Int) {
    let started = Date()
    let text = try await provider.transcribe(
      fileURL: wav,
      settings: TranscriptionSettings(
        endpoint: URL(string: "https://localhost")!,
        model: model,
        language: "en",
        vocabularyTerms: terms
      )
    )
    return (text, Int(Date().timeIntervalSince(started) * 1000))
  }

  private static func hits(_ text: String) -> Int {
    let lower = text.lowercased()
    return terms.filter { lower.contains($0.lowercased()) }.count
  }

  private static func makeSpeechClip() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ww-parakeet-e2e-\(UUID().uuidString).wav")
    try? FileManager.default.removeItem(at: url)
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "--data-format=LEI16@16000", phrase]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)
    return url
  }

  private static func write(_ lines: [String]) throws {
    try (lines.joined(separator: "\n") + "\n")
      .write(toFile: outputPath, atomically: true, encoding: .utf8)
  }
}
