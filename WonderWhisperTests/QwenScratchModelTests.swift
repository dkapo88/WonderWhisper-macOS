import Foundation
import Testing
@testable import WonderWhisper

/// Opt-in real-MLX checks against scratch model copies. Never touches the
/// user's Qwen/HuggingFace cache: every runtime here gets an explicit
/// directory. Enable with (xcodebuild forwards `TEST_RUNNER_`-prefixed vars):
///
///   TEST_RUNNER_QWEN_GOOD_MODEL_DIR=/tmp/qwen-ad04/model
///   TEST_RUNNER_QWEN_TRUNC_MODEL_DIR=/tmp/qwen-ad04/trunc        (truncated shard)
///   TEST_RUNNER_QWEN_ZEROTAIL_MODEL_DIR=/tmp/qwenfix/zerotail    (full size, zeroed tail)
///   TEST_RUNNER_QWEN_EXTRA_WAV_DIR=/tmp/qwen-ad04/wav            (optional, good model)
@Suite(.serialized)
struct QwenScratchModelTests {
  private static let env = ProcessInfo.processInfo.environment

  private static func directory(_ key: String) -> URL? {
    env[key].map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private static var canaryURL: URL? {
    Bundle.main.url(forResource: QwenCanary.resourceName, withExtension: "wav")
  }

  private static let settings = TranscriptionSettings(
    endpoint: URL(string: "https://localhost")!,
    model: "qwen-local",
    language: "en"
  )

  private final class StubFallback: TranscriptionProvider {
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
      "fallback transcript"
    }
  }

  /// Mirrors `DictationController.recoverFromUnusableQwen`: a fallback-eligible
  /// Qwen error routes the same file to the fallback engine.
  private static func dictate(_ provider: QwenASRTranscriptionProvider, file: URL) async throws
    -> (text: String, usedFallback: Bool, error: QwenASRError?)
  {
    do {
      return (try await provider.transcribe(fileURL: file, settings: settings), false, nil)
    } catch let error as QwenASRError where error.shouldFallBack {
      let stub = StubFallback()
      let choice = QwenASRFallback.Choice.groq
      let fallback = QwenASRFallback.provider(for: choice, groq: stub) { stub }
      let text = try await fallback?.transcribe(
        fileURL: file,
        settings: QwenASRFallback.settings(for: choice, from: settings)
      ) ?? ""
      return (text, true, error)
    }
  }

  private static func expectBrokenModelFallsBack(_ dir: URL, label: String) async throws {
    let wav = try #require(canaryURL)
    let runtime = QwenASRRuntime(modelDirectory: { dir })
    let provider = QwenASRTranscriptionProvider(runtime: runtime)
    let t0 = Date()
    let result = try await dictate(provider, file: wav)
    let elapsed = Date().timeIntervalSince(t0)
    print(
      "QWEN_\(label)_RESULT usedFallback=\(result.usedFallback) "
        + "error=\(result.error?.localizedDescription ?? "nil") "
        + "text=\"\(result.text)\" elapsed=\(String(format: "%.2f", elapsed))s"
    )
    #expect(result.usedFallback)
    #expect(result.text == "fallback transcript")
    #expect(!result.text.contains("!!!"))
    let health = await runtime.currentHealth()
    print("QWEN_\(label)_HEALTH \(health)")
    guard case .unhealthy = health else {
      Issue.record("expected unhealthy, got \(health)")
      return
    }
  }

  @Test(.enabled(if: env["QWEN_TRUNC_MODEL_DIR"] != nil))
  func truncatedModelIsDetectedAndFallsBack() async throws {
    let dir = try #require(Self.directory("QWEN_TRUNC_MODEL_DIR"))
    try await Self.expectBrokenModelFallsBack(dir, label: "TRUNC")
  }

  /// MLX-only loader with the safetensors pre-check switched off: proves the
  /// eager eval + canary layer catches the truncated model on its own (the
  /// swallowed read means eval itself reports success).
  private struct NoIntegrityLoader: QwenASREngineLoader {
    let inner = MLXQwenASREngineLoader()
    func verifyFiles(directory: URL) throws -> String { "skipped by test" }
    func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine {
      try inner.load(directory: directory, log: log)
    }
    func clearCache() { inner.clearCache() }
  }

  @Test(.enabled(if: env["QWEN_TRUNC_MODEL_DIR"] != nil))
  func truncatedModelIsCaughtByCanaryEvenWithoutIntegrityCheck() async throws {
    let dir = try #require(Self.directory("QWEN_TRUNC_MODEL_DIR"))
    let wav = try #require(Self.canaryURL)
    let runtime = QwenASRRuntime(loader: NoIntegrityLoader(), modelDirectory: { dir })
    let result = try await Self.dictate(QwenASRTranscriptionProvider(runtime: runtime), file: wav)
    print(
      "QWEN_TRUNC_NOINTEGRITY_RESULT usedFallback=\(result.usedFallback) "
        + "error=\(result.error?.localizedDescription ?? "nil") text=\"\(result.text)\""
    )
    #expect(result.usedFallback)
    #expect(!result.text.contains("!!!"))
  }

  /// Full-size file whose tail is zeros: integrity passes, so only the canary
  /// can catch it.
  @Test(.enabled(if: env["QWEN_ZEROTAIL_MODEL_DIR"] != nil))
  func zeroedWeightsFailCanaryAndFallBack() async throws {
    let dir = try #require(Self.directory("QWEN_ZEROTAIL_MODEL_DIR"))
    _ = try QwenWeightIntegrity.verify(directory: dir)
    try await Self.expectBrokenModelFallsBack(dir, label: "ZEROTAIL")
  }

  /// Cold first dictation after switching Qwen on: no warm-up, so this pays
  /// load + integrity + eval + canary + decode. Run alone in a fresh test
  /// process (`-only-testing:.../coldFirstDictationLatency`) for a real number.
  @Test(.enabled(if: env["QWEN_COLD_MODEL_DIR"] != nil))
  func coldFirstDictationLatency() async throws {
    let dir = try #require(Self.directory("QWEN_COLD_MODEL_DIR"))
    let wav = try Self.env["QWEN_COLD_WAV"].map { URL(fileURLWithPath: $0) } ?? #require(Self.canaryURL)
    let runtime = QwenASRRuntime(modelDirectory: { dir })
    let provider = QwenASRTranscriptionProvider(runtime: runtime)

    let t0 = Date()
    let text = try await provider.transcribe(fileURL: wav, settings: Self.settings)
    let cold = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = try await provider.transcribe(fileURL: wav, settings: Self.settings)
    let warm = Date().timeIntervalSince(t1)
    print(
      "QWEN_COLD_LATENCY first=\(String(format: "%.2f", cold))s "
        + "second=\(String(format: "%.2f", warm))s wav=\(wav.lastPathComponent) text=\"\(text.prefix(80))\""
    )
    #expect(!QwenASRManager.looksLikeDegenerateTranscript(text, sampleCount: 0))
  }

  @Test(.enabled(if: env["QWEN_GOOD_MODEL_DIR"] != nil))
  func goodModelPassesCanaryAndDecodes() async throws {
    let dir = try #require(Self.directory("QWEN_GOOD_MODEL_DIR"))
    let wav = try #require(Self.canaryURL)
    let runtime = QwenASRRuntime(modelDirectory: { dir })
    let t0 = Date()
    try await runtime.warmUp()
    print("QWEN_GOOD_WARMUP \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    #expect(await runtime.currentHealth() == .healthy)

    let provider = QwenASRTranscriptionProvider(runtime: runtime)
    for round in 1...3 {
      let t1 = Date()
      let text = try await provider.transcribe(fileURL: wav, settings: Self.settings)
      let similarity = QwenCanary.similarity(text, QwenCanary.expectedText)
      print(
        "QWEN_GOOD_CANARY_DECODE round=\(round) text=\"\(text)\" "
          + "similarity=\(String(format: "%.2f", similarity)) "
          + "t=\(String(format: "%.2f", Date().timeIntervalSince(t1)))s"
      )
      #expect(similarity >= QwenCanary.minimumSimilarity)
    }

    guard let extra = Self.directory("QWEN_EXTRA_WAV_DIR") else { return }
    let wavs = try FileManager.default.contentsOfDirectory(at: extra, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension.lowercased() == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(wavs.count == 12, "expected the complete scratch WAV corpus")
    for file in wavs {
      let text = try await provider.transcribe(fileURL: file, settings: Self.settings)
      let samples = try QwenAudioDecoder.decode16kMonoFloat(from: file).count
      print("QWEN_GOOD_WAV \(file.lastPathComponent) | \(text.prefix(100))")
      #expect(!text.isEmpty, "empty transcript for \(file.lastPathComponent)")
      #expect(!QwenASRManager.looksLikeDegenerateTranscript(text, sampleCount: samples))
    }
    #expect(await runtime.loadsStarted == 1)
    await runtime.resetForReload(reason: "scratch good model complete")
  }
}
