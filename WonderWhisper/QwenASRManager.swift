import Foundation
#if canImport(Qwen3ASR)
import Qwen3ASR
import AudioCommon
#endif

/// On-device Qwen3-ASR-0.6B (MLX 4-bit). File-based / async only.
///
/// Weights come from HuggingFace via speech-swift and land in the default
/// `~/Library/Caches/qwen3-speech/` cache so a CLI `speech transcribe`
/// download is reused. This is not a meeting engine.
enum QwenASRManager {
  static let modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
  static let cacheDirectoryName = "qwen3-speech"
  static let sampleRate = 16_000
  static let chunkDurationSeconds = 15
  static let oneShotMaxDurationSeconds = 20
  static let chunkMaxTokens = 448
  static let oneShotMaxTokens = 1024

  static var isLinked: Bool {
    #if canImport(Qwen3ASR)
    return true
    #else
    return false
    #endif
  }

  static var isAppleSilicon: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  static var cacheRoot: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches", isDirectory: true)
    return caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
  }

  /// Directories speech-swift may use for this model (legacy flat + Hub layout).
  static var modelCacheCandidates: [URL] {
    let sanitized = modelId.replacingOccurrences(of: "/", with: "_")
    return [
      cacheRoot.appendingPathComponent("models/\(modelId)", isDirectory: true),
      cacheRoot.appendingPathComponent(sanitized, isDirectory: true),
      cacheRoot.appendingPathComponent(modelId, isDirectory: true)
    ]
  }

  static func modelsPresent() -> Bool {
    modelCacheCandidates.contains { weightsExist(in: $0) }
  }

  static func effectiveCacheDirectory() -> URL {
    modelCacheCandidates.first { weightsExist(in: $0) } ?? modelCacheCandidates[0]
  }

  /// ISO-639-1 / BCP-47 from Settings → Qwen language hint. `auto` is nil.
  static func languageHint(for code: String?) -> String? {
    guard let code else { return nil }
    let normalized = code
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard !normalized.isEmpty, normalized != "auto" else { return nil }
    return normalized.split(separator: "-").first.map(String.init)
  }

  static func isQwenModel(_ model: String) -> Bool {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed == SimpleVoiceEngine.qwenLocal.transcriptionModel
      || trimmed == "qwen-local"
      || (trimmed.contains("qwen") && !trimmed.contains("/"))
  }

  static var isRuntimeAvailable: Bool {
    isLinked && isAppleSilicon
  }

  /// Decoder budget for a clip. Speech is a few tokens per second; a fixed 1024
  /// cap on a 1 s file lets a broken decode emit thousands of garbage tokens
  /// and balloon MLX cache. Floor 64 so very short clips still have headroom.
  static func maxTokens(sampleCount: Int, chunked: Bool) -> Int {
    let cap = chunked ? chunkMaxTokens : oneShotMaxTokens
    let duration = Double(max(0, sampleCount)) / Double(sampleRate)
    let adaptive = Int(duration * 16.0) + 48
    return min(cap, max(64, adaptive))
  }

  /// One range for clips up to `oneShotMaxDurationSeconds`, otherwise 15 s slices
  /// so each decode stays under the per-call token cap.
  static func transcriptionChunkRanges(
    sampleCount: Int,
    sampleRate: Int = sampleRate,
    chunkSeconds: Int = chunkDurationSeconds,
    oneShotMaxSeconds: Int = oneShotMaxDurationSeconds
  ) -> [Range<Int>] {
    guard sampleCount > 0, sampleRate > 0 else { return [] }
    let oneShotLimit = oneShotMaxSeconds * sampleRate
    if sampleCount <= oneShotLimit { return [0..<sampleCount] }
    let chunkSize = max(1, chunkSeconds * sampleRate)
    var ranges: [Range<Int>] = []
    var offset = 0
    while offset < sampleCount {
      let end = min(offset + chunkSize, sampleCount)
      ranges.append(offset..<end)
      offset = end
    }
    return ranges
  }

  #if canImport(Qwen3ASR)
  /// Cache weights only. Does not instantiate the GPU model.
  static func downloadModel(
    progress: (@Sendable (Double, String) -> Void)? = nil
  ) async throws {
    try await QwenASRRuntime.shared.downloadWeights(progress: progress)
  }
  #endif

  static func weightsExist(in directory: URL) -> Bool {
    let fm = FileManager.default
    let config = directory.appendingPathComponent("config.json")
    let vocab = directory.appendingPathComponent("vocab.json")
    guard fm.fileExists(atPath: config.path), fm.fileExists(atPath: vocab.path) else {
      return false
    }
    #if canImport(Qwen3ASR)
    return HuggingFaceDownloader.weightsExist(in: directory)
    #else
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
      return false
    }
    let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return items.contains { $0.pathExtension.lowercased() == "safetensors" }
    #endif
  }
}

enum QwenASRError: Error, LocalizedError {
  case requiresAppleSilicon
  case frameworkMissing
  case emptyAudio
  case decodeFailed
  case modelNotDownloaded

  var errorDescription: String? {
    switch self {
    case .requiresAppleSilicon:
      return "Qwen3-ASR requires Apple Silicon."
    case .frameworkMissing:
      return "Qwen3-ASR is not linked in this build."
    case .emptyAudio:
      return "Audio file is empty."
    case .decodeFailed:
      return "Could not decode audio for Qwen3-ASR."
    case .modelNotDownloaded:
      return "Download Qwen3-ASR 0.6B in Settings before dictating."
    }
  }
}
