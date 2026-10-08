import Foundation

/// A loaded Qwen3-ASR model as `QwenASRRuntime` sees it.
///
/// Every call runs on the runtime's serial inference queue, never on the Swift
/// cooperative pool (see `QwenASRRuntime`). Tests substitute fakes.
protocol QwenASREngine: AnyObject {
  func decode(samples: [Float], language: String?, context: String?, maxTokens: Int) -> String
  func unload()
}

/// Builds engines for `QwenASRRuntime`. Called on the inference queue; may block.
protocol QwenASREngineLoader {
  /// Cheap pre-flight file check. Returns a one-line summary for the load log.
  func verifyFiles(directory: URL) throws -> String
  /// Constructs the model from `directory` and force-evaluates every weight,
  /// surfacing any error MLX reports. Logs its own stage timings via `log`.
  func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine
  /// Drops MLX's buffer cache between a failed attempt and the retry.
  func clearCache()
}

extension QwenASREngineLoader {
  func verifyFiles(directory: URL) throws -> String {
    let shards = try QwenWeightIntegrity.verify(directory: directory)
    return shards
      .map { "\($0.file) tensors=\($0.tensorCount) bytes=\($0.fileSize)/\($0.dataEnd)" }
      .joined(separator: ", ")
  }
}

/// Serial GCD queue that owns all Qwen MLX work: load, eval, canary, decode, unload.
///
/// The 2026-08-19 actor path ran MLX `transcribe` on the Swift cooperative
/// pool: a 1 s clip decoded into thousands of garbage tokens and unified
/// memory climbed past 10 GB. State lives on the `QwenASRRuntime` actor; GPU
/// work stays here, matching the path that worked.
final class QwenInferenceQueue: @unchecked Sendable {
  private let queue: DispatchQueue

  init(label: String = "com.danekapoor.wonderwhisper.qwen-asr") {
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }

  func run<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try work())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func run(_ work: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
      queue.async {
        work()
        continuation.resume()
      }
    }
  }
}

/// Load → integrity → eval → canary, with one unload/clear-cache/reload retry.
///
/// Runs synchronously on the inference queue. Every stage is logged so the
/// next real failure shows which stage broke.
enum QwenASRLoadVerifier {
  enum StageFailure: Error, CustomStringConvertible {
    case canary(String)

    var description: String {
      switch self {
      case .canary(let reason): return "canary failed: \(reason)"
      }
    }
  }

  static let maxAttempts = 2

  static func loadVerified(
    loader: QwenASREngineLoader,
    directory: URL,
    canary: QwenCanary?,
    generation: Int,
    log: (String) -> Void
  ) throws -> QwenASREngine {
    var lastFailure = "unknown"
    let started = Date()
    for attempt in 1...maxAttempts {
      log("load#\(generation) attempt \(attempt)/\(maxAttempts) dir=\(directory.path)")
      log("load#\(generation) files \(QwenWeightIntegrity.fileSizeSummary(in: directory))")
      var engine: QwenASREngine?
      do {
        let integrity = try loader.verifyFiles(directory: directory)
        log("load#\(generation) integrity ok \(integrity)")
        let loaded = try loader.load(directory: directory) { log("load#\(generation) \($0)") }
        engine = loaded
        try runCanary(canary, on: loaded, generation: generation, log: log)
        log(
          "load#\(generation) verified in \(seconds(since: started)) (attempt \(attempt))"
        )
        return loaded
      } catch {
        lastFailure = describe(error)
        log("load#\(generation) attempt \(attempt) FAILED: \(lastFailure)")
        engine?.unload()
        loader.clearCache()
      }
    }
    log("load#\(generation) unhealthy after \(maxAttempts) attempts: \(lastFailure)")
    throw QwenASRError.unhealthy(lastFailure)
  }

  private static func runCanary(
    _ canary: QwenCanary?,
    on engine: QwenASREngine,
    generation: Int,
    log: (String) -> Void
  ) throws {
    guard let canary else {
      log("load#\(generation) canary skipped (clip not bundled)")
      return
    }
    let t0 = Date()
    let text = engine.decode(
      samples: canary.samples,
      language: "en",
      context: nil,
      maxTokens: QwenCanary.maxTokens
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let result = canary.evaluate(text)
    let similarity = String(format: "%.2f", result.similarity)
    log(
      "load#\(generation) canary \(result.passed ? "passed" : "FAILED") "
        + "similarity=\(similarity) in \(seconds(since: t0)) text=\"\(text.prefix(80))\""
    )
    guard result.passed else { throw StageFailure.canary(result.reason ?? "mismatch") }
  }

  static func describe(_ error: Error) -> String {
    if let failure = error as? QwenWeightIntegrity.Failure { return "integrity: \(failure)" }
    if let failure = error as? StageFailure { return failure.description }
    return "\(error.localizedDescription) [\(String(describing: error))]"
  }

  static func seconds(since start: Date) -> String {
    String(format: "%.2fs", Date().timeIntervalSince(start))
  }
}
