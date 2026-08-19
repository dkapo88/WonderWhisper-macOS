import Foundation
#if canImport(Qwen3ASR)
import Qwen3ASR
#endif

/// On-device Qwen3-ASR-0.6B (MLX 4-bit). File-based / async only.
///
/// Weights come from HuggingFace via speech-swift and land in the default
/// `~/Library/Caches/qwen3-speech/` cache so a CLI `speech transcribe`
/// download is reused. This is not a meeting engine.
enum QwenASRManager {
  static let modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
  static let cacheDirectoryName = "qwen3-speech"

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

  #if canImport(Qwen3ASR)
  /// Download weights if needed, then drop the in-memory model so Settings
  /// does not keep ~1 GB of GPU weights resident.
  static func downloadModel(
    progress: ((Double, String) -> Void)? = nil
  ) async throws {
    guard isAppleSilicon else {
      throw QwenASRError.requiresAppleSilicon
    }
    _ = try await Qwen3ASRModel.fromPretrained(
      modelId: modelId,
      progressHandler: progress
    )
  }
  #endif

  static func weightsExist(in directory: URL) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
      return false
    }
    let config = directory.appendingPathComponent("config.json")
    let vocab = directory.appendingPathComponent("vocab.json")
    guard fm.fileExists(atPath: config.path), fm.fileExists(atPath: vocab.path) else {
      return false
    }
    let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return items.contains { $0.pathExtension.lowercased() == "safetensors" }
  }
}

enum QwenASRError: Error, LocalizedError {
  case requiresAppleSilicon
  case frameworkMissing
  case emptyAudio
  case decodeFailed

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
    }
  }
}
