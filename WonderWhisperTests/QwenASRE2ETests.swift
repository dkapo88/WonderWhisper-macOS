import Foundation
import Testing
@testable import WonderWhisper

struct QwenASRE2ETests {
  @Test func qwenDecodesKnownSpeechClipIfWeightsExist() async throws {
    guard QwenASRManager.modelsPresent() else { return }
    let url = URL(
      fileURLWithPath: NSHomeDirectory()
        + "/Library/Application Support/HermesWhisper/History/audio/"
        + "469B5C31-14F2-4943-B733-E99BD4FC3CB8.wav"
    )
    guard FileManager.default.fileExists(atPath: url.path) else { return }

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
    print("QWEN_KNOWN_CLIP=\(text)")
    let lower = text.lowercased()
    #expect(
      lower.contains("parakeet") || lower.contains("working") || lower.contains("okay"),
      "Qwen produced: \(text.prefix(200))"
    )
  }
}
