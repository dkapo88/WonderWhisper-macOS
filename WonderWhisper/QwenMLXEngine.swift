import Foundation

#if canImport(Qwen3ASR)
import AudioCommon
import MLX
import MLXNN
import Qwen3ASR

/// `Qwen3ASRModel` behind `QwenASREngine`. Not thread-safe; the runtime only
/// touches it on its serial inference queue.
final class MLXQwenASREngine: QwenASREngine {
  private let model: Qwen3ASRModel

  init(model: Qwen3ASRModel) {
    self.model = model
  }

  func decode(samples: [Float], language: String?, context: String?, maxTokens: Int) -> String {
    // Legacy greedy overload — same path as `speech transcribe`. Custom
    // Qwen3DecodingOptions (repetitionPenalty 1.15) force generateSlow,
    // which in the Release build emitted mixed-script garbage until EOS
    // never fired.
    model.transcribe(
      audio: samples,
      sampleRate: QwenASRManager.sampleRate,
      language: language,
      maxTokens: maxTokens,
      context: context
    )
  }

  func unload() {
    model.unload()
  }
}

/// Loads speech-swift's Qwen3-ASR from a local directory and makes every
/// weight resident before the first decode.
///
/// speech-swift 0.0.26 loads weights lazily (`fromPretrained` never evaluates
/// them), so before this change the first real dictation was also the first
/// disk read. Evaluating here moves that read to load time, inside
/// `withError`, where the canary can check the result before any user audio
/// is decoded.
struct MLXQwenASREngineLoader: QwenASREngineLoader {
  func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine {
    let t0 = Date()
    // offlineMode: the runtime only loads a directory that already holds a
    // complete cache, so a load never touches the network or rewrites files.
    let model = try Self.blockingAwait {
      try await Qwen3ASRModel.fromPretrained(
        modelId: QwenASRManager.modelId,
        cacheDir: directory,
        offlineMode: true
      )
    }
    log("fromPretrained ok in \(QwenASRLoadVerifier.seconds(since: t0))")

    let t1 = Date()
    var arrays = model.audioEncoder.parameters().flattened().map { $0.1 }
    if let decoder = model.textDecoder {
      arrays += decoder.parameters().flattened().map { $0.1 }
    } else {
      model.unload()
      throw QwenASRError.unhealthy("text decoder missing after load")
    }
    do {
      try withError {
        eval(arrays)
      }
    } catch {
      log("eval ERROR after \(QwenASRLoadVerifier.seconds(since: t1)): \(error)")
      model.unload()
      throw error
    }
    let bytes = arrays.reduce(0) { $0 + $1.nbytes }
    log(
      "eval ok \(arrays.count) tensors \(bytes / 1_048_576) MB in "
        + "\(QwenASRLoadVerifier.seconds(since: t1))"
    )
    return MLXQwenASREngine(model: model)
  }

  func clearCache() {
    MLX.Memory.clearCache()
  }

  /// Runs async `fromPretrained` to completion from the inference queue. Blocks
  /// a GCD thread, never a cooperative-pool thread.
  private static func blockingAwait<T>(
    _ operation: @escaping @Sendable () async throws -> T
  ) throws -> T {
    let box = BlockingResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    // Same QoS as the inference queue that waits on it (no priority inversion).
    Task.detached(priority: .userInitiated) {
      do {
        box.result = .success(try await operation())
      } catch {
        box.result = .failure(error)
      }
      done.signal()
    }
    done.wait()
    guard let result = box.result else { throw QwenASRError.unhealthy("load produced no result") }
    return try result.get()
  }
}

private final class BlockingResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
#endif
