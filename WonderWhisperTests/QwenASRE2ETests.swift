import Foundation
import Testing
@testable import WonderWhisper

/// Uses externally installed Qwen weights, so it is explicit opt-in:
/// `TEST_RUNNER_WW_RUN_MODEL_TESTS=1 xcodebuild test`
/// `-only-testing:WonderWhisperTests/QwenASRE2ETests`.
/// The audio is a test-owned fixture synthesized with macOS `say`, never a user recording.
struct QwenASRE2ETests {
  @Test(.enabled(if: AppConfig.runsModelTests, "set WW_RUN_MODEL_TESTS=1 to use installed models"))
  func qwenDecodesASynthesizedSpeechFixture() async throws {
    guard QwenASRManager.modelsPresent() else { return }
    let url = try Self.makeSpeechFixture("Parakeet is working okay.")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let text = try await QwenASRTranscriptionProvider().transcribe(
      fileURL: url,
      settings: TranscriptionSettings(
        endpoint: URL(string: "https://localhost")!,
        model: "qwen-local",
        language: "en",
        vocabularyTerms: [
          "Hapana", "Biso", "Jarron", "Makenzie", "Sonali", "Manish",
          "Ezypay", "Niamh", "Hermes", "WonderWhisper"
        ]
      )
    )
    print("QWEN_FIXTURE=\(text)")
    let lower = text.lowercased()
    #expect(
      lower.contains("parakeet") || lower.contains("working") || lower.contains("okay"),
      "Qwen produced: \(text.prefix(200))"
    )
    #expect(!lower.contains("hapana"), "Vocabulary list leaked into transcript: \(text)")
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
