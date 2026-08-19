import Foundation
import AVFoundation
import OSLog

#if canImport(Qwen3ASR)

/// File-based Qwen3-ASR-0.6B. Records finish, then one offline decode.
/// No live streaming. Inference lives on `QwenASRRuntime`.
final class QwenASRTranscriptionProvider: TranscriptionProvider {
  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")

  func warmUp() async {
    do {
      try await QwenASRRuntime.shared.warmUp()
    } catch {
      let ns = error as NSError
      log.notice("[QwenASR] warmUp failed: \(ns.localizedDescription, privacy: .public)")
      AppLog.dictation.error("[QwenASR] warmUp failed: \(ns.localizedDescription)")
    }
  }

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    let samples = try Self.decode16kMonoFloat(from: fileURL)
    guard !samples.isEmpty else { return "" }
    let language = QwenASRManager.languageHint(for: settings.language)
    let context = Self.contextPrompt(from: settings.vocabularyTerms)
    let chunks = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    log.notice(
      "[QwenASR] transcribe file=\(fileURL.lastPathComponent, privacy: .public) samples=\(samples.count, privacy: .public) chunks=\(chunks.count, privacy: .public)"
    )
    AppLog.dictation.log(
      "[QwenASR] transcribe file=\(fileURL.lastPathComponent) samples=\(samples.count) chunks=\(chunks.count)"
    )
    let text = try await QwenASRRuntime.shared.transcribe(
      samples: samples,
      language: language,
      context: context
    )
    let preview = text.prefix(120)
    log.notice("[QwenASR] result length=\(text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
    AppLog.dictation.log("[QwenASR] result length=\(text.count) preview=\(String(preview))")
    return text
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
