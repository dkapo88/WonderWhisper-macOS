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

  /// The downloaded model directory, or nil when nothing complete is cached.
  /// Default model-directory source for `QwenASRRuntime`; tests inject a scratch dir.
  static func installedModelDirectory() -> URL? {
    modelCacheCandidates.first { weightsExist(in: $0) }
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

  /// High-confidence decode corruption only. Load integrity and the canary are
  /// the primary defence; ordinary emphasis and multilingual speech must survive.
  static func looksLikeDegenerateTranscript(_ text: String, sampleCount: Int) -> Bool {
    degenerateReason(text, sampleCount: sampleCount) != nil
  }

  /// Why the guard fired, for logs. Nil does not guarantee a correct transcription.
  static func degenerateReason(_ text: String, sampleCount: Int) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if longestRun(of: "!", in: trimmed) >= 32 { return "token-0 '!' run" }
    let bangs = trimmed.filter { $0 == "!" }.count
    let visible = trimmed.filter { !$0.isWhitespace }.count
    // A short excited phrase such as "Wait!!!!!!!!" is legitimate emphasis.
    if bangs >= 20, bangs * 2 > visible { return "'!' is \(bangs) of \(visible) characters" }
    if let ratio = repetitiveCompressionRatio(trimmed), ratio > 2.4 {
      return "repetitive compression ratio \(String(format: "%.2f", ratio))"
    }
    if trimmed.unicodeScalars.contains(where: { $0.value == 0xFFFD }), trimmed.count > 80 {
      return "replacement characters"
    }
    // The August field failure needs this signal: 371 chars in 2 s, without
    // repetition or U+FFFD. Script mixing alone is never a corruption signal.
    if sampleCount > 0 {
      let duration = Double(sampleCount) / Double(sampleRate)
      let maxPlausible = max(200, Int(duration * 100) + 80)
      if trimmed.count > maxPlausible {
        return "\(trimmed.count) chars for \(String(format: "%.1f", duration))s of audio"
      }
    }
    return nil
  }

  /// Whisper's UTF-8 bytes / zlib bytes metric, using Foundation's zlib codec.
  /// Compression failure is not evidence against an otherwise healthy model.
  static func compressionRatio(_ text: String) -> Double? {
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty,
          let compressed = try? (bytes as NSData).compressed(using: .zlib),
          compressed.length > 0 else { return nil }
    return Double(bytes.count) / Double(compressed.length)
  }

  /// A global ratio also rises on long legitimate lists and repeated sentences.
  /// Require compression in every 100-character window as well, so the 2.4
  /// cutoff detects low-information loops rather than recurring list structure.
  /// Ignore a short final window (under 40 chars), where the metric is unstable.
  static func repetitiveCompressionRatio(_ text: String) -> Double? {
    guard text.count >= 40, let full = compressionRatio(text), full > 2.4 else { return nil }
    var lowest = full
    var start = text.startIndex
    while start < text.endIndex {
      let end = text.index(start, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
      let window = text[start..<end]
      if window.count >= 40 {
        guard let ratio = compressionRatio(String(window)) else { return nil }
        lowest = min(lowest, ratio)
      }
      start = end
    }
    return lowest
  }

  static func longestRun(of character: Character, in text: String) -> Int {
    var best = 0
    var current = 0
    for ch in text {
      current = ch == character ? current + 1 : 0
      best = max(best, current)
    }
    return best
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

enum QwenASRError: Error, LocalizedError, Equatable {
  case requiresAppleSilicon
  case frameworkMissing
  case emptyAudio
  case decodeFailed
  case modelNotDownloaded
  /// Load-time verification (weight integrity, eval, canary) failed twice.
  case unhealthy(String)
  /// A dictation decode came back as garbage; the model is being reloaded.
  case degenerateTranscript(String)

  /// Errors where another engine should transcribe the recording instead of
  /// failing the dictation. Qwen garbage is never pasted.
  var shouldFallBack: Bool {
    switch self {
    case .unhealthy, .degenerateTranscript: return true
    default: return false
    }
  }

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
      return "Download Qwen3-ASR 0.6B in Settings → Transcription before dictating."
    case .unhealthy(let reason):
      return "Qwen3-ASR failed its load check (\(reason))."
    case .degenerateTranscript(let reason):
      return "Qwen3-ASR produced garbage (\(reason)); reloading the model."
    }
  }
}
