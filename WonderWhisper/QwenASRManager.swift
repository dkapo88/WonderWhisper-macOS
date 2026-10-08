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

  /// Greedy MLX decode that has gone off the rails: token-0 `!` runs, one
  /// word looping, mixed-script soup, replacement characters, or far more
  /// text than speech can produce. Checked on every decode and on the
  /// load-time canary, so garbage is never pasted into the user's app.
  ///
  /// Uninitialized weights (a swallowed lazy-load read in mlx-swift 0.31.6)
  /// decode as 448 `!` tokens; the 2026-08 notarized failure was
  /// mixed-script soup. Legit short or punctuation-only output ("OK!",
  /// "...", "Wow!!!") must not trip this.
  static func looksLikeDegenerateTranscript(_ text: String, sampleCount: Int) -> Bool {
    degenerateReason(text, sampleCount: sampleCount) != nil
  }

  /// Why `looksLikeDegenerateTranscript` fired, for logs. Nil when the text looks like speech.
  static func degenerateReason(_ text: String, sampleCount: Int) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if longestRun(of: "!", in: trimmed) >= 8 { return "token-0 '!' run" }
    // Token 0 is "!". Ordinary exclamation marks are a few percent of the
    // text even in an excited 90 s list; a stuck decoder is mostly "!".
    let bangs = trimmed.filter { $0 == "!" }.count
    let visible = trimmed.filter { !$0.isWhitespace }.count
    if bangs >= 20, bangs * 4 > visible { return "'!' is \(bangs) of \(visible) characters" }
    if longestIdenticalSymbolRun(in: trimmed) >= 16 { return "repeated symbol run" }
    if longestRepeatedWordRun(in: trimmed) >= 12 { return "one word looping" }
    if trimmed.unicodeScalars.contains(where: { $0.value == 0xFFFD }) && trimmed.count > 80 {
      return "replacement characters"
    }
    // Several scripts alone is legit multilingual speech. Only call it soup
    // when words are also broken across scripts mid-token.
    if mixedScriptSoup(trimmed), trimmed.count > 80, corruptMixedScriptTokens(in: trimmed) >= 2 {
      return "mixed-script soup"
    }
    let duration = sampleCount > 0 ? Double(sampleCount) / Double(sampleRate) : 0
    // Fast English is ~20–25 chars/s. 100 chars/s is already superhuman;
    // the stuck-kernel path emits ~1000 chars/s up to chunkMaxTokens.
    let maxPlausible = max(400, Int(duration * 100) + 80)
    if trimmed.count > maxPlausible {
      return "\(trimmed.count) chars for \(String(format: "%.1f", duration))s of audio"
    }
    return nil
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

  /// Longest run of one identical non-alphanumeric, non-space character.
  /// "......" and "—" are fine; 16+ of the same symbol is a stuck decoder.
  static func longestIdenticalSymbolRun(in text: String) -> Int {
    var best = 0
    var current = 0
    var previous: Character?
    for ch in text {
      let isSymbol = !ch.isLetter && !ch.isNumber && !ch.isWhitespace
      if isSymbol, ch == previous {
        current += 1
      } else {
        current = isSymbol ? 1 : 0
      }
      previous = ch
      best = max(best, current)
    }
    return best
  }

  /// Longest run of the same word repeated back to back ("the the the ...").
  static func longestRepeatedWordRun(in text: String) -> Int {
    let words = text.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.trimmingCharacters(in: .punctuationCharacters) }
      .filter { !$0.isEmpty }
    var best = 0
    var current = 0
    var previous: String?
    for word in words {
      current = word == previous ? current + 1 : 1
      previous = word
      best = max(best, current)
    }
    return best
  }

  /// Three or more writing systems with a real footprint — Latin + CJK +
  /// Arabic in one "utterance" is the notarized-MLX failure mode, not speech.
  static func mixedScriptSoup(_ text: String) -> Bool {
    var counts: [Script: Int] = [:]
    for scalar in text.unicodeScalars {
      if let script = Script(scalar) { counts[script, default: 0] += 1 }
    }
    return counts.values.filter { $0 >= 8 }.count >= 3
  }

  enum Script: Hashable {
    case latin, cyrillic, arabic, thai, hangul, cjk

    init?(_ scalar: Unicode.Scalar) {
      switch scalar.value {
      case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: self = .latin
      case 0x0400...0x04FF: self = .cyrillic
      case 0x0600...0x06FF, 0x0750...0x077F: self = .arabic
      case 0x0E00...0x0E7F: self = .thai
      case 0x1100...0x11FF, 0xAC00...0xD7AF: self = .hangul
      case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF: self = .cjk
      default: return nil
      }
    }

    /// Scripts written with spaces between words. Two of these inside one
    /// whitespace token ("ещsylvanialide", "ปลายolith") is a broken word.
    var isSpaceDelimited: Bool {
      switch self {
      case .latin, .cyrillic, .arabic: return true
      case .thai, .hangul, .cjk: return false
      }
    }
  }

  /// Whitespace tokens whose letters switch script mid-word in a way speech
  /// never produces: three or more scripts, or two space-delimited scripts.
  /// Chinese/Japanese with embedded Latin ("我用Swift写") and Korean particles
  /// on English names ("WonderWhisper를") are normal and do not count.
  static func corruptMixedScriptTokens(in text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).filter { token in
      let scripts = Set(token.unicodeScalars.compactMap(Script.init))
      if scripts.count >= 3 { return true }
      return scripts.filter(\.isSpaceDelimited).count >= 2
    }.count
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
