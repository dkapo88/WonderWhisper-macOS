import Foundation
import OSLog

#if canImport(Qwen3ASR)
import Qwen3ASR
import AudioCommon

/// Single process-wide Qwen3-ASR owner.
///
/// `Qwen3ASRModel` is not thread-safe, and MLX GPU eval must not block the
/// Swift cooperative thread pool. The 2026-08-19 actor path ran
/// `transcribe` on that pool: a 1 s clip decoded into thousands of garbage
/// tokens and unified memory climbed past 10 GB. All GPU work stays on this
/// serial GCD queue, matching the debug path that worked.
final class QwenASRRuntime: @unchecked Sendable {
  static let shared = QwenASRRuntime()

  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private let inferenceQueue = DispatchQueue(label: "com.danekapoor.wonderwhisper.qwen-asr")
  private let stateLock = NSLock()
  private var model: Qwen3ASRModel?
  private var loadTask: Task<Qwen3ASRModel, Error>?
  private var idleUnloadTask: Task<Void, Never>?
  private var inFlight = 0
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
    _ = try await ensureModelLoaded()
    scheduleIdleUnload()
  }

  func transcribe(
    samples: [Float],
    language: String?,
    context: String?
  ) async throws -> String {
    idleUnloadTask?.cancel()
    stateLock.lock(); inFlight += 1; stateLock.unlock()
    defer {
      stateLock.lock(); inFlight -= 1; let idle = inFlight == 0; stateLock.unlock()
      if idle { scheduleIdleUnload() }
    }
    let loaded = try await ensureModelLoaded()
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    let text = try await runOnInferenceQueue {
      var parts: [String] = []
      for range in ranges {
        let slice = Array(samples[range])
        // Legacy greedy overload — same path as `speech transcribe`. Custom
        // Qwen3DecodingOptions (repetitionPenalty 1.15) force generateSlow,
        // which in the Release build emitted mixed-script garbage until EOS
        // never fired.
        let part = loaded.transcribe(
          audio: slice,
          sampleRate: QwenASRManager.sampleRate,
          language: language,
          maxTokens: QwenASRManager.chunkMaxTokens,
          context: context
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !part.isEmpty { parts.append(part) }
      }
      return parts.joined(separator: " ")
    }
    return text
  }

  private func ensureModelLoaded() async throws -> Qwen3ASRModel {
    if let model, model.isLoaded { return model }
    if let loadTask { return try await loadTask.value }
    guard QwenASRManager.isAppleSilicon else { throw QwenASRError.requiresAppleSilicon }
    guard QwenASRManager.modelsPresent() else { throw QwenASRError.modelNotDownloaded }
    let task = Task<Qwen3ASRModel, Error> {
      AppLog.dictation.log("[QwenASR] loading \(QwenASRManager.modelId)")
      return try await Qwen3ASRModel.fromPretrained(modelId: QwenASRManager.modelId)
    }
    loadTask = task
    defer { loadTask = nil }
    let loaded = try await task.value
    model = loaded
    return loaded
  }

  private func scheduleIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(self.idleSeconds * 1_000_000_000))
      if Task.isCancelled { return }
      await self.unloadIfIdle()
    }
  }

  private func unloadIfIdle() async {
    await runOnInferenceQueue {
      self.stateLock.lock()
      let busy = self.inFlight != 0
      self.stateLock.unlock()
      guard !busy, self.model != nil else { return }
      self.log.notice("[QwenASR] Idle timeout — unloading model")
      AppLog.dictation.log("[QwenASR] idle unload")
      self.model?.unload()
      self.model = nil
    }
  }

  private func runOnInferenceQueue(_ work: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
      inferenceQueue.async {
        work()
        continuation.resume()
      }
    }
  }

  private func runOnInferenceQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      inferenceQueue.async {
        do {
          continuation.resume(returning: try work())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
#endif
