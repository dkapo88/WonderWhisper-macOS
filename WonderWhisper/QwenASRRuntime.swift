import Foundation
import OSLog

#if canImport(Qwen3ASR)
import Qwen3ASR
import AudioCommon

/// Single process-wide Qwen3-ASR owner. `Qwen3ASRModel` is not thread-safe and
/// MLX is process-global, so Settings download, warm-up, transcribe, and idle
/// unload all serialize here.
actor QwenASRRuntime {
  static let shared = QwenASRRuntime()

  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private var model: Qwen3ASRModel?
  private var inFlight = 0
  private var idleTask: Task<Void, Never>?
  private let idleSeconds: TimeInterval = 300

  func downloadWeights(progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
    guard QwenASRManager.isAppleSilicon else { throw QwenASRError.requiresAppleSilicon }
    let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: QwenASRManager.modelId)
    AppLog.dictation.log("[QwenASR] downloading weights to \(cacheDir.path)")
    try await HuggingFaceDownloader.downloadWeights(
      modelId: QwenASRManager.modelId,
      to: cacheDir,
      additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
      progressHandler: { fraction in
        progress?(fraction, "Downloading weights...")
      }
    )
    progress?(1.0, "Download complete")
  }

  func warmUp() async throws {
    _ = try await loadModel()
    scheduleIdleUnload()
  }

  func transcribe(
    samples: [Float],
    language: String?,
    context: String?
  ) async throws -> String {
    idleTask?.cancel()
    idleTask = nil
    inFlight += 1
    defer {
      inFlight -= 1
      if inFlight == 0 { scheduleIdleUnload() }
    }
    let loaded = try await loadModel()
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    var parts: [String] = []
    for range in ranges {
      let slice = Array(samples[range])
      let maxTokens = ranges.count == 1
        ? QwenASRManager.oneShotMaxTokens
        : QwenASRManager.chunkMaxTokens
      let options = Qwen3DecodingOptions(
        maxTokens: maxTokens,
        language: language,
        context: context,
        repetitionPenalty: 1.15
      )
      let text = loaded.transcribe(audio: slice, sampleRate: QwenASRManager.sampleRate, options: options)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { parts.append(text) }
    }
    return parts.joined(separator: " ")
  }

  private func loadModel() async throws -> Qwen3ASRModel {
    if let model, model.isLoaded { return model }
    guard QwenASRManager.isAppleSilicon else { throw QwenASRError.requiresAppleSilicon }
    guard QwenASRManager.modelsPresent() else { throw QwenASRError.modelNotDownloaded }
    AppLog.dictation.log("[QwenASR] loading \(QwenASRManager.modelId) offline")
    let loaded = try await Qwen3ASRModel.fromPretrained(
      modelId: QwenASRManager.modelId,
      offlineMode: true
    )
    model = loaded
    return loaded
  }

  private func scheduleIdleUnload() {
    idleTask?.cancel()
    idleTask = Task { [idleSeconds] in
      try? await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
      if Task.isCancelled { return }
      await self.unloadIfIdle()
    }
  }

  private func unloadIfIdle() {
    guard inFlight == 0 else { return }
    if model != nil {
      log.notice("[QwenASR] Idle timeout — unloading model")
      AppLog.dictation.log("[QwenASR] idle unload")
    }
    model?.unload()
    model = nil
  }
}
#endif
