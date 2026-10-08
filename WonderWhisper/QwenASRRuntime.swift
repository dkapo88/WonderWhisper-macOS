import Foundation
import OSLog

#if canImport(Qwen3ASR)
import AudioCommon
import Qwen3ASR
#endif

enum QwenASRHealth: Equatable {
  case unknown
  case verifying
  case healthy
  case unhealthy(String)
}

/// Single process-wide Qwen3-ASR owner.
///
/// Runtime state (engine, in-progress load, idle-unload timer, in-flight count,
/// health) is confined to this actor. All MLX work — load, eval, canary,
/// decode, unload — runs on one serial GCD queue (`QwenInferenceQueue`), never
/// on the Swift cooperative pool.
///
/// Every load is verified before use (`QwenASRLoadVerifier`): safetensors
/// integrity, eager eval of all weights, then a canary decode of a known clip.
/// One failure unloads, clears the MLX cache and reloads; a second marks Qwen
/// unhealthy and throws so dictation falls back to another engine. Every
/// decode is also checked for garbage; a hit retires the model and kicks off a
/// verified reload for the next dictation.
actor QwenASRRuntime {
  static let shared = QwenASRRuntime()

  /// Engine plus the load generation that produced it.
  final class EngineBox: @unchecked Sendable {
    let engine: QwenASREngine
    let generation: Int
    /// Set and read only on the inference queue, so a decode that was queued
    /// behind an unload sees it and never runs on cleared weights.
    var retired = false

    init(engine: QwenASREngine, generation: Int) {
      self.engine = engine
      self.generation = generation
    }
  }

  private enum InternalError: Error {
    /// A newer load replaced the one this caller awaited; try again.
    case superseded
    /// The engine was unloaded before a queued decode reached the queue.
    case retired
  }

  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private let loader: QwenASREngineLoader
  private let inference: QwenInferenceQueue
  private let modelDirectory: @Sendable () -> URL?
  private let canaryProvider: @Sendable () -> QwenCanary?
  private let idleSeconds: TimeInterval
  private let unhealthyRetryCooldown: TimeInterval

  private var engine: EngineBox?
  private var loadTask: Task<EngineBox, Error>?
  private var loadTaskGeneration = 0
  private var generation = 0
  private var idleUnloadTask: Task<Void, Never>?
  private var idleToken = 0
  private var inFlight = 0
  private var lastFailureAt: Date?
  private var cachedCanary: QwenCanary??
  private(set) var health: QwenASRHealth = .unknown
  /// Number of loads started (for tests and logs).
  private(set) var loadsStarted = 0

  init(
    loader: QwenASREngineLoader = QwenASRRuntime.defaultLoader(),
    modelDirectory: @escaping @Sendable () -> URL? = { QwenASRManager.installedModelDirectory() },
    canary: @escaping @Sendable () -> QwenCanary? = { QwenASRRuntime.bundledCanary() },
    idleSeconds: TimeInterval = 300,
    unhealthyRetryCooldown: TimeInterval = 60,
    inference: QwenInferenceQueue = QwenInferenceQueue()
  ) {
    self.loader = loader
    self.modelDirectory = modelDirectory
    self.canaryProvider = canary
    self.idleSeconds = idleSeconds
    self.unhealthyRetryCooldown = unhealthyRetryCooldown
    self.inference = inference
  }

  // MARK: - Public API

  /// Loads and verifies the model ahead of the first decode (recording start).
  /// Ignores the unhealthy cooldown: it runs while the user is still talking.
  func warmUp() async throws {
    defer { scheduleIdleUnloadIfIdle() }
    _ = try await readyEngine(respectCooldown: false)
  }

  func transcribe(samples: [Float], language: String?, context: String?) async throws -> String {
    cancelIdleUnload()
    inFlight += 1
    defer {
      inFlight -= 1
      scheduleIdleUnloadIfIdle()
    }
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    var retriedRetired = false
    while true {
      let box = try await readyEngine(respectCooldown: true)
      let outcome: ChunkedDecode
      do {
        outcome = try await inference.run { () throws -> ChunkedDecode in
          guard !box.retired else { throw InternalError.retired }
          return Self.decodeChunks(
            samples: samples,
            ranges: ranges,
            engine: box.engine,
            language: language,
            context: context
          )
        }
      } catch InternalError.retired where !retriedRetired {
        retriedRetired = true
        continue
      }
      switch outcome {
      case .text(let text):
        return text
      case .degenerate(let reason, let chunk, let part):
        record(
          "degenerate decode load#\(box.generation) chunk \(chunk + 1)/\(ranges.count) "
            + "(\(reason)) length=\(part.count) preview=\"\(part.prefix(60))\" "
            + "— retiring model, reloading for next time",
          error: true
        )
        await invalidate(box, reason: "degenerate decode: \(reason)")
        Task { try? await self.warmUp() }
        throw QwenASRError.degenerateTranscript(reason)
      }
    }
  }

  enum ChunkedDecode: Equatable {
    case text(String)
    case degenerate(reason: String, chunk: Int, part: String)
  }

  /// Decodes each chunk and validates it against its OWN sample count before
  /// joining. Checking only the joined text against the whole recording let a
  /// 1 s tail that decoded to 1,000+ chars hide inside a 16 s budget.
  /// Runs on the inference queue.
  nonisolated static func decodeChunks(
    samples: [Float],
    ranges: [Range<Int>],
    engine: QwenASREngine,
    language: String?,
    context: String?
  ) -> ChunkedDecode {
    var parts: [String] = []
    for (index, range) in ranges.enumerated() {
      let part = engine.decode(
        samples: Array(samples[range]),
        language: language,
        context: context,
        maxTokens: QwenASRManager.chunkMaxTokens
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if let reason = QwenASRManager.degenerateReason(part, sampleCount: range.count) {
        return .degenerate(reason: reason, chunk: index, part: part)
      }
      if !part.isEmpty { parts.append(part) }
    }
    return .text(parts.joined(separator: " "))
  }

  func currentHealth() -> QwenASRHealth { health }

  var isEngineLoaded: Bool { engine != nil }

  /// Drops the current engine (and supersedes any in-progress load) so the
  /// next caller performs a fresh verified load.
  func resetForReload(reason: String) async {
    generation += 1
    loadTask = nil
    if let box = engine {
      await invalidate(box, reason: reason)
    }
  }

  // MARK: - Load coalescing

  /// The current verified engine, or a fresh verified load. Concurrent callers
  /// share one load. A caller whose load was superseded never clears the newer
  /// load's task (generation check) and simply awaits the newer one.
  private func readyEngine(respectCooldown: Bool) async throws -> EngineBox {
    for _ in 0..<4 {
      if let engine { return engine }
      if let task = loadTask {
        let awaited = loadTaskGeneration
        do {
          let box = try await task.value
          clearLoadTask(ifGeneration: awaited)
          if engine === box { return box }
          continue
        } catch InternalError.superseded {
          clearLoadTask(ifGeneration: awaited)
          continue
        } catch {
          clearLoadTask(ifGeneration: awaited)
          throw error
        }
      }
      if respectCooldown, case .unhealthy(let reason) = health,
         let failedAt = lastFailureAt,
         Date().timeIntervalSince(failedAt) < unhealthyRetryCooldown {
        throw QwenASRError.unhealthy(reason)
      }
      guard let directory = modelDirectory() else { throw QwenASRError.modelNotDownloaded }
      generation += 1
      let loadGeneration = generation
      loadsStarted += 1
      health = .verifying
      let task = Task { try await self.performVerifiedLoad(directory: directory, generation: loadGeneration) }
      loadTask = task
      loadTaskGeneration = loadGeneration
      do {
        let box = try await task.value
        clearLoadTask(ifGeneration: loadGeneration)
        if engine === box { return box }
      } catch InternalError.superseded {
        clearLoadTask(ifGeneration: loadGeneration)
      } catch {
        clearLoadTask(ifGeneration: loadGeneration)
        throw error
      }
    }
    throw QwenASRError.unhealthy("load superseded repeatedly")
  }

  private func clearLoadTask(ifGeneration expected: Int) {
    guard loadTaskGeneration == expected else { return }
    loadTask = nil
  }

  private func performVerifiedLoad(directory: URL, generation loadGeneration: Int) async throws -> EngineBox {
    let loader = self.loader
    let canary = canaryForLoad()
    let logger = log
    do {
      let loaded = try await inference.run { () throws -> QwenASREngine in
        try QwenASRLoadVerifier.loadVerified(
          loader: loader,
          directory: directory,
          canary: canary,
          generation: loadGeneration
        ) { line in
          logger.notice("[QwenASR] \(line, privacy: .public)")
          AppLog.dictation.log("[QwenASR] \(line, privacy: .public)")
        }
      }
      let box = EngineBox(engine: loaded, generation: loadGeneration)
      guard loadGeneration == generation else {
        record("load#\(loadGeneration) finished after being superseded; discarding")
        await retire(box)
        throw InternalError.superseded
      }
      engine = box
      health = .healthy
      lastFailureAt = nil
      return box
    } catch InternalError.superseded {
      throw InternalError.superseded
    } catch {
      guard loadGeneration == generation else { throw InternalError.superseded }
      let reason: String
      if case QwenASRError.unhealthy(let why)? = error as? QwenASRError {
        reason = why
      } else {
        reason = QwenASRLoadVerifier.describe(error)
      }
      health = .unhealthy(reason)
      lastFailureAt = Date()
      record("Qwen marked unhealthy: \(reason)", error: true)
      throw QwenASRError.unhealthy(reason)
    }
  }

  private func canaryForLoad() -> QwenCanary? {
    if let cachedCanary { return cachedCanary }
    let loaded = canaryProvider()
    cachedCanary = .some(loaded)
    return loaded
  }

  // MARK: - Unload

  /// Retires `box` if it is still the current engine. Health goes unhealthy so
  /// a decode right after waits for a fresh verified load.
  private func invalidate(_ box: EngineBox, reason: String) async {
    if engine === box {
      engine = nil
      health = .unhealthy(reason)
    }
    await retire(box)
  }

  /// Unloads on the inference queue, behind any decode already queued.
  private func retire(_ box: EngineBox) async {
    let loader = self.loader
    await inference.run {
      guard !box.retired else { return }
      box.retired = true
      box.engine.unload()
      loader.clearCache()
    }
  }

  private func cancelIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
    idleToken += 1
  }

  private func scheduleIdleUnloadIfIdle() {
    guard inFlight == 0 else { return }
    idleUnloadTask?.cancel()
    idleToken += 1
    let token = idleToken
    let delay = idleSeconds
    idleUnloadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.unloadIfIdle(token: token)
    }
  }

  /// The in-flight check and the engine hand-off happen in one actor turn, so
  /// a decode that has started (inFlight > 0) can never lose its engine here.
  private func unloadIfIdle(token: Int) async {
    guard token == idleToken, inFlight == 0, loadTask == nil, let box = engine else { return }
    engine = nil
    record("idle timeout — unloading load#\(box.generation)")
    await retire(box)
  }

  // MARK: - Logging

  private func record(_ message: String, error: Bool = false) {
    log.notice("[QwenASR] \(message, privacy: .public)")
    if error {
      AppLog.dictation.error("[QwenASR] \(message, privacy: .public)")
    } else {
      AppLog.dictation.log("[QwenASR] \(message, privacy: .public)")
    }
  }

  // MARK: - Defaults

  static func defaultLoader() -> QwenASREngineLoader {
    #if canImport(Qwen3ASR)
    return MLXQwenASREngineLoader()
    #else
    return UnavailableQwenLoader()
    #endif
  }

  static func bundledCanary(bundle: Bundle = .main) -> QwenCanary? {
    guard let url = bundle.url(forResource: QwenCanary.resourceName, withExtension: "wav"),
          let samples = try? QwenAudioDecoder.decode16kMonoFloat(from: url),
          !samples.isEmpty
    else {
      AppLog.dictation.error("[QwenASR] canary clip missing from bundle; load checks skip it")
      return nil
    }
    return QwenCanary(samples: samples)
  }

  #if canImport(Qwen3ASR)
  /// Download weights only. Does not instantiate the GPU model.
  nonisolated func downloadWeights(
    progress: (@Sendable (Double, String) -> Void)? = nil
  ) async throws {
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
  #endif
}

#if !canImport(Qwen3ASR)
private struct UnavailableQwenLoader: QwenASREngineLoader {
  func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine {
    throw QwenASRError.frameworkMissing
  }

  func clearCache() {}
}
#endif
