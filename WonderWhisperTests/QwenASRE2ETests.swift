import Foundation
import Testing
@testable import WonderWhisper

/// Uses an explicitly supplied scratch Qwen model, so it is opt-in:
/// `TEST_RUNNER_QWEN_GOOD_MODEL_DIR=/tmp/qwen-ad04/model xcodebuild test`
/// `-only-testing:WonderWhisperTests/QwenASRE2ETests`.
/// The audio is a test-owned fixture synthesized with macOS `say`, never a user recording.
struct QwenASRE2ETests {
  private static let env = ProcessInfo.processInfo.environment

  @Test(.enabled(if: env["QWEN_GOOD_MODEL_DIR"] != nil))
  func qwenDecodesASynthesizedSpeechFixture() async throws {
    let directory = URL(fileURLWithPath: try #require(Self.env["QWEN_GOOD_MODEL_DIR"]))
    let runtime = QwenASRRuntime(modelDirectory: { directory })
    let url = try Self.makeSpeechFixture("Parakeet is working okay.")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let text = try await QwenASRTranscriptionProvider(runtime: runtime).transcribe(
      fileURL: url,
      settings: TranscriptionSettings(
        endpoint: URL(fileURLWithPath: "/unused"),
        model: "qwen-local",
        language: "en",
        vocabularyTerms: [
          "Hapana", "Biso", "Jarron", "Makenzie", "Sonali", "Manish",
          "Ezypay", "Niamh", "Hermes", "WonderWhisper"
        ]
      )
    )
    let samples = try QwenAudioDecoder.decode16kMonoFloat(from: url).count
    print("QWEN_FIXTURE=\(text)")
    #expect(QwenASRManager.degenerateReason(text, sampleCount: samples) == nil)
    let lower = text.lowercased()
    #expect(
      lower.contains("parakeet") || lower.contains("working") || lower.contains("okay"),
      "Qwen produced: \(text.prefix(200))"
    )
    #expect(!lower.contains("hapana"), "Vocabulary list leaked into transcript: \(text)")
    await runtime.resetForReload(reason: "scratch E2E complete")
  }

  /// Synthesizes a 16 kHz mono WAV into a fresh temp folder.
  private static func makeSpeechFixture(_ sentence: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("QwenFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let aiff = folder.appendingPathComponent("speech.aiff")
    let wav = folder.appendingPathComponent("speech.wav")
    try run("/usr/bin/say", ["-o", aiff.path, sentence])
    try run(
      "/usr/bin/afconvert",
      ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
    )
    return wav
  }

  private static func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(tool) failed")
  }
}
