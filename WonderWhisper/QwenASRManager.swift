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
  static let oneShotMaxDurationSeconds = 15
  static let chunkMaxTokens = 448

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

  /// UserDefaults key. Missing means on: Vocabulary-tab terms go into Qwen
  /// decoder context. Post-decode `VocabularyTextCorrector` still runs either way.
  static let injectVocabularyKey = "qwen.injectVocabulary"

  static var injectVocabularyEnabled: Bool {
    if AppConfig.defaults.object(forKey: injectVocabularyKey) == nil { return true }
    return AppConfig.defaults.bool(forKey: injectVocabularyKey)
  }

  /// Decoder system-prompt context from the Vocabulary tab. Nil when disabled
  /// or empty. Qwen 0.6B can echo this list if an utterance trails off; the
  /// Settings toggle is the escape hatch.
  static func decoderContext(
    from terms: [String],
    enabled: Bool = injectVocabularyEnabled
  ) -> String? {
    guard enabled else { return nil }
    let cleaned = terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    return "Vocabulary: " + cleaned.joined(separator: ", ")
  }

  /// Greedy MLX decode that has gone off the rails: mixed-script soup,
  /// replacement characters, or far more text than speech can produce.
  /// Used to unload/reload once instead of pasting thousands of garbage tokens.
  static func looksLikeDegenerateTranscript(_ text: String, sampleCount: Int) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.filter({ $0 == "!" }).count > 20 { return true }
    if trimmed.unicodeScalars.contains(where: { $0.value == 0xFFFD }) && trimmed.count > 80 {
      return true
    }
    if mixedScriptSoup(trimmed) && trimmed.count > 80 { return true }
    let duration = sampleCount > 0 ? Double(sampleCount) / Double(sampleRate) : 0
    // Fast English is ~20–25 chars/s. 100 chars/s is already superhuman;
    // the stuck-kernel path emits ~1000 chars/s up to chunkMaxTokens.
    let maxPlausible = max(400, Int(duration * 100) + 80)
    return trimmed.count > maxPlausible
  }

  /// Three or more writing systems with a real footprint — Latin + CJK +
  /// Arabic in one "utterance" is the notarized-MLX failure mode, not speech.
  static func mixedScriptSoup(_ text: String) -> Bool {
    var latin = 0, cjk = 0, arabic = 0, cyrillic = 0, hangul = 0, thai = 0
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
        latin += 1
      case 0x0400...0x04FF:
        cyrillic += 1
      case 0x0600...0x06FF, 0x0750...0x077F:
        arabic += 1
      case 0x0E00...0x0E7F:
        thai += 1
      case 0x1100...0x11FF, 0xAC00...0xD7AF:
        hangul += 1
      case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF:
        cjk += 1
      default:
        break
      }
    }
    return [latin, cjk, arabic, cyrillic, hangul, thai].filter { $0 >= 8 }.count >= 3
  }

  /// One range for clips up to `oneShotMaxDurationSeconds`, otherwise 15 s slices
  /// so each decode stays on the greedy fast path (`duration > 15` would
  /// escalate to the slow n-gram decoder).
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
  case helperFailed(String)

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
    case .helperFailed(let message):
      return "Qwen3-ASR helper failed: \(message)"
    }
  }
}
