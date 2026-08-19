import Foundation
import AVFoundation
import OSLog

#if canImport(Qwen3ASR)
import Qwen3ASR

/// File-based Qwen3-ASR-0.6B. Records finish, then one offline decode.
/// No live streaming.
final class QwenASRTranscriptionProvider: TranscriptionProvider {
  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private let inferenceQueue = DispatchQueue(label: "com.danekapoor.wonderwhisper.qwen-asr")
  private var model: Qwen3ASRModel?
  private var loadTask: Task<Qwen3ASRModel, Error>?
  private var idleUnloadTask: Task<Void, Never>?
  private let idleSeconds: TimeInterval = 300

  func warmUp() async {
    do {
      _ = try await ensureModelLoaded()
      scheduleIdleUnload()
    } catch {
      let ns = error as NSError
      log.notice("[QwenASR] warmUp failed: \(ns.localizedDescription, privacy: .public)")
      AppLog.dictation.error("[QwenASR] warmUp failed: \(ns.localizedDescription)")
    }
  }

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    let samples = try Self.decode16kMonoFloat(from: fileURL)
    guard !samples.isEmpty else { return "" }
    let loaded = try await ensureModelLoaded()
    let language = QwenASRManager.languageHint(for: settings.language)
    let context = Self.contextPrompt(from: settings.vocabularyTerms)
    let options = Qwen3DecodingOptions(
      maxTokens: 1024,
      language: language,
      context: context,
      repetitionPenalty: 1.15
    )
    log.notice(
      "[QwenASR] transcribe file=\(fileURL.lastPathComponent, privacy: .public) samples=\(samples.count, privacy: .public)"
    )
    AppLog.dictation.log("[QwenASR] transcribe file=\(fileURL.lastPathComponent) samples=\(samples.count)")
    let text = try await runOnInferenceQueue {
      loaded.transcribe(audio: samples, sampleRate: 16_000, options: options)
    }
    let preview = text.prefix(120)
    log.notice("[QwenASR] result length=\(text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
    AppLog.dictation.log("[QwenASR] result length=\(text.count) preview=\(String(preview))")
    scheduleIdleUnload()
    return text
  }

  private func ensureModelLoaded() async throws -> Qwen3ASRModel {
    if let model { return model }
    if let loadTask {
      return try await loadTask.value
    }
    guard QwenASRManager.isAppleSilicon else {
      throw QwenASRError.requiresAppleSilicon
    }
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
      if self.model != nil {
        self.log.notice("[QwenASR] Idle timeout — unloading model")
        AppLog.dictation.log("[QwenASR] idle unload")
      }
      self.model = nil
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

  private static func contextPrompt(from terms: [String]) -> String? {
    let cleaned = terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    return "Vocabulary: " + cleaned.joined(separator: ", ")
  }

  private static func decode16kMonoFloat(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    else {
      throw QwenASRError.emptyAudio
    }
    try file.read(into: sourceBuffer)

    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ) else {
      throw QwenASRError.decodeFailed
    }

    if sourceFormat.sampleRate == 16_000,
       sourceFormat.channelCount == 1,
       sourceFormat.commonFormat == .pcmFormatFloat32 {
      return floatSamples(from: sourceBuffer)
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw QwenASRError.decodeFailed
    }
    let ratio = 16_000 / sourceFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 256
    guard let dest = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
      throw QwenASRError.decodeFailed
    }

    var conversionError: NSError?
    var supplied = false
    let status = converter.convert(to: dest, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }
    if let conversionError { throw conversionError }
    if status == .error { throw QwenASRError.decodeFailed }
    return floatSamples(from: dest)
  }

  private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?.pointee else { return [] }
    let count = Int(buffer.frameLength)
    return Array(UnsafeBufferPointer(start: channel, count: count))
  }
}
#else
final class QwenASRTranscriptionProvider: TranscriptionProvider {
  func warmUp() async {}
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    throw QwenASRError.frameworkMissing
  }
}
#endif
