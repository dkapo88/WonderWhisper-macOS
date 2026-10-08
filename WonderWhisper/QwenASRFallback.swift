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
        language: settings.language,
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
  /// Unified is the only English-only Parakeet model; every other kind (v3
  /// here, Ultra after the FluidAudio 0.17 bump) is multilingual. Keyed off
  /// `.unified`, which exists on both branches, so it merges cleanly.
  var isEnglishOnly: Bool { self == .unified }

  /// Whether this model can transcribe `language` (a Settings language code
  /// such as "en-US", "fr" or "auto"). Auto-detect and English fit every
  /// model; anything else needs a multilingual one.
  func qwenFallbackSupports(language: String?) -> Bool {
    guard isEnglishOnly else { return true }
    guard let hint = QwenASRManager.languageHint(for: language) else { return true }
    return hint == "en"
  }
}
