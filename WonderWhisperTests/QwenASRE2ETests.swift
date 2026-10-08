import Foundation
import Testing
@testable import WonderWhisper

/// Opt-in E2E coverage uses the same scratch model/WAV copies as the load tests.
/// Never resolve a shared runtime or audio under the user's real History.
struct QwenASRE2ETests {
  private static let env = ProcessInfo.processInfo.environment

  @Test(.enabled(if: env["QWEN_GOOD_MODEL_DIR"] != nil && env["QWEN_EXTRA_WAV_DIR"] != nil))
  func qwenDecodesKnownSpeechClipFromScratch() async throws {
    let directory = URL(fileURLWithPath: try #require(Self.env["QWEN_GOOD_MODEL_DIR"]))
    let wavDirectory = URL(fileURLWithPath: try #require(Self.env["QWEN_EXTRA_WAV_DIR"]))
    let files = try FileManager.default.contentsOfDirectory(
      at: wavDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let file = try #require(files.first)
    let runtime = QwenASRRuntime(modelDirectory: { directory })
    let text = try await QwenASRTranscriptionProvider(runtime: runtime).transcribe(
      fileURL: file,
      settings: TranscriptionSettings(
        endpoint: URL(fileURLWithPath: "/unused"), model: "qwen-local", language: "en"
      )
    )
    let samples = try QwenAudioDecoder.decode16kMonoFloat(from: file).count
    print("QWEN_SCRATCH_E2E text=\"\(text)\"")
    #expect(!text.isEmpty)
    #expect(QwenASRManager.degenerateReason(text, sampleCount: samples) == nil)
    await runtime.resetForReload(reason: "scratch E2E complete")
  }
}
