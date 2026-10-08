import Foundation

/// Which engine re-transcribes a recording when Qwen is unhealthy or decodes
/// garbage. Parakeet when a model is already downloaded (local, no key, no
/// download at dictation time), otherwise the injected Groq file transcriber.
///
/// Used by `DictationController.fileCapableFallback(for:)` /
/// `fileRecoverySettings(from:)`, so Qwen recovery runs through the same
/// single finalize path as the Soniox/xAI empty-stream safety net.
enum QwenASRFallback {
  enum Choice: Equatable {
    case parakeet(ParakeetModelKind)
    case groq

    var label: String {
      switch self {
      case .parakeet: return "Parakeet"
      case .groq: return "Groq"
      }
    }
  }

  /// Prefers the user's selected Parakeet model, then any other downloaded one,
  /// but only models that can transcribe `language` (the dictation's language
  /// setting). An English-only model never gets non-English speech: if no
  /// downloaded Parakeet model fits, Groq Whisper (multilingual) is used.
  /// Auto-detect preserves the selected downloaded model, even Unified: there
  /// is no explicit language to rule it out. Try another only if it is missing.
  static func choice(
    language: String?,
    selectedParakeet: ParakeetModelKind = ParakeetModelKind.selected,
    parakeetPresent: (ParakeetModelKind) -> Bool = { ParakeetManager.modelsPresent(for: $0) }
  ) -> Choice {
    guard ParakeetManager.isLinked else { return .groq }
    let candidates = [selectedParakeet] + ParakeetModelKind.allCases
    for kind in candidates
    where kind.qwenFallbackSupports(language: language) && parakeetPresent(kind) {
      return .parakeet(kind)
    }
    return .groq
  }

  /// The provider for `choice`. Nil only for `.groq` with no Groq transcriber injected.
  static func provider(
    for choice: Choice,
    groq: TranscriptionProvider?,
    makeParakeet: () -> TranscriptionProvider = { ParakeetTranscriptionProvider() }
  ) -> TranscriptionProvider? {
    switch choice {
    case .parakeet: return makeParakeet()
    case .groq: return groq
    }
  }

  /// Returns usable recovery text or throws a user-facing error. In particular,
  /// missing Groq credentials must never return the failed Qwen transcript.
  static func transcribe(
    fileURL: URL,
    choice: Choice,
    settings: TranscriptionSettings,
    groq: TranscriptionProvider?
  ) async throws -> String {
    guard let fallback = provider(for: choice, groq: groq) else {
      throw QwenFallbackError.unavailable
    }
    if let groq = fallback as? GroqTranscriptionProvider, !groq.hasAPIKey {
      throw QwenFallbackError.unavailable
    }
    do {
      return try await fallback.transcribe(
        fileURL: fileURL, settings: self.settings(for: choice, from: settings)
      )
    } catch let error as ProviderError {
      if choice == .groq, case .missingAPIKey = error {
        throw QwenFallbackError.unavailable
      }
      throw QwenFallbackError.failed(error.localizedDescription)
    } catch {
      throw QwenFallbackError.failed(error.localizedDescription)
    }
  }

  /// Settings the fallback engine accepts for this recording. Language and
  /// vocabulary carry over; endpoint and model are rewritten.
  static func settings(for choice: Choice, from settings: TranscriptionSettings) -> TranscriptionSettings {
    switch choice {
    case .parakeet(let kind):
      return TranscriptionSettings(
        endpoint: settings.endpoint,
        model: "parakeet-\(kind.rawValue)",
        timeout: settings.timeout,
        language: settings.language,
        vocabularyTerms: settings.vocabularyTerms,
        context: settings.context
      )
    case .groq:
      return TranscriptionSettings(
        endpoint: AppConfig.groqAudioTranscriptions,
        model: AppConfig.defaultTranscriptionModel,
        timeout: max(settings.timeout, 30),
        language: QwenASRManager.languageHint(for: settings.language) ?? "auto",
        vocabularyTerms: settings.vocabularyTerms,
        context: settings.context
      )
    }
  }

  /// One-line notice for the dictation error overlay.
  static func userNotice(for error: QwenASRError, choice: Choice) -> String {
    switch error {
    case .degenerateTranscript:
      return "Qwen produced garbage, so this dictation used \(choice.label). Qwen is reloading."
    default:
      return "Qwen failed its load check, so this dictation used \(choice.label)."
    }
  }
}

extension ParakeetModelKind {
  /// Stable across the sibling v3 → Ultra rename; capability lives in this
  /// Qwen-owned file rather than coupling recovery to either case name.
  var isEnglishOnly: Bool { self == .unified }

  /// https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 lists these 25 languages.
  /// FluidInference's Ultra card was unreachable on 2026-10-08; assume the
  /// same v3 language set for Ultra until that card can be verified.
  var qwenFallbackLanguages: Set<String> {
    if isEnglishOnly { return ["en"] }
    return [
      "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
      "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]
  }

  func qwenFallbackSupports(language: String?) -> Bool {
    guard let hint = QwenASRManager.languageHint(for: language) else { return true }
    return qwenFallbackLanguages.contains(hint)
  }
}

/// Recovery errors reach finalize's caller before any insertion can run.
enum QwenFallbackError: Error, LocalizedError, Equatable {
  case unavailable
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Qwen failed. No downloaded Parakeet model supports this language. "
        + "Add a Groq API key in Settings → Transcription to recover this dictation. "
        + "Nothing was pasted."
    case .failed(let reason):
      return "Qwen failed and transcription recovery failed: \(reason). Nothing was pasted."
    }
  }
}
