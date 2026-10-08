import Foundation
import OSLog

#if canImport(Qwen3ASR)

/// File-based Qwen3-ASR-0.6B. Records finish, then one offline decode.
/// No live streaming. Inference and load verification live on `QwenASRRuntime`.
///
/// Throws `QwenASRError.unhealthy` / `.degenerateTranscript` instead of ever
/// returning garbage; `DictationController` falls back to another engine on
/// those (`QwenASRError.shouldFallBack`).
final class QwenASRTranscriptionProvider: TranscriptionProvider {
  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private let runtime: QwenASRRuntime

  /// `runtime` is injectable so tests can point at a scratch model directory
  /// instead of the user's real Qwen/HuggingFace cache.
  init(runtime: QwenASRRuntime = .shared) {
    self.runtime = runtime
  }

  func warmUp() async {
    do {
      try await runtime.warmUp()
    } catch {
      let ns = error as NSError
      log.notice("[QwenASR] warmUp failed: \(ns.localizedDescription, privacy: .public)")
      AppLog.dictation.error("[QwenASR] warmUp failed: \(ns.localizedDescription)")
    }
  }

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    let samples = try QwenAudioDecoder.decode16kMonoFloat(from: fileURL)
    guard !samples.isEmpty else { return "" }
    let language = QwenASRManager.languageHint(for: settings.language)
    let context = QwenASRManager.decoderContext(from: settings.vocabularyTerms)
    let chunks = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    log.notice(
      "[QwenASR] transcribe file=\(fileURL.lastPathComponent, privacy: .public) samples=\(samples.count, privacy: .public) chunks=\(chunks.count, privacy: .public) context=\(context != nil, privacy: .public)"
    )
    AppLog.dictation.log(
      "[QwenASR] transcribe file=\(fileURL.lastPathComponent) samples=\(samples.count) chunks=\(chunks.count) context=\(context != nil)"
    )
    let text = try await runtime.transcribe(
      samples: samples,
      language: language,
      context: context
    )
    let preview = text.prefix(120)
    log.notice("[QwenASR] result length=\(text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
    AppLog.dictation.log("[QwenASR] result length=\(text.count) preview=\(String(preview))")
    return text
  }
}
#else
final class QwenASRTranscriptionProvider: TranscriptionProvider {
  init(runtime: QwenASRRuntime = .shared) {}
  func warmUp() async {}
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    throw QwenASRError.frameworkMissing
  }
}
#endif
