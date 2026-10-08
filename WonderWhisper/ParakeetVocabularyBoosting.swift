import Foundation
#if canImport(FluidAudio)
import FluidAudio
import OSLog
#endif

/// Custom-vocabulary boosting for on-device Parakeet Unified.
///
/// FluidAudio rescores the finished transcript against a small CTC model's
/// acoustic evidence and swaps in Vocabulary terms where the audio supports
/// them. Boosting is best-effort: a missing CTC model or a configure failure is
/// logged and transcription carries on unboosted.
enum ParakeetVocabularyBoosting {
  /// UserDefaults key for the Settings → Transcription toggle. Unset means on.
  static let enabledKey = "parakeet.vocabularyBoosting.enabled"

  /// FluidAudio's small CTC keyword-spotting model (`CtcModelVariant.ctc110m`).
  /// Its `Repo.folderName` has an explicit case that KEEPS the `-coreml`
  /// suffix, unlike the ASR model folders. A unit test pins it.
  static let ctcFolderName = "parakeet-ctc-110m-coreml"
  static let ctcApproximateDownloadSize = "About 100 MB"

  static func isEnabled(defaults: UserDefaults = AppConfig.defaults) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? true
  }

  /// The Vocabulary page's terms (custom vocabulary plus spelling-correction
  /// targets), parsed exactly as for the cloud keyterm APIs.
  static func currentTerms(defaults: UserDefaults = AppConfig.defaults) -> [String] {
    VoiceVocabularyKeyterms.terms(
      customVocabulary: defaults.string(forKey: "vocab.custom") ?? "",
      spellingCorrections: defaults.string(forKey: "vocab.spelling") ?? ""
    )
  }

  /// Terms to boost. Empty means boosting is off: either the toggle is off or
  /// the vocabulary has no usable terms.
  static func termsToBoost(enabled: Bool, terms: [String]) -> [String] {
    guard enabled else { return [] }
    return terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func shouldBoost(enabled: Bool, terms: [String]) -> Bool {
    !termsToBoost(enabled: enabled, terms: terms).isEmpty
  }

  /// Terms to boost right now, from the persisted toggle and vocabulary.
  static func currentTermsToBoost(defaults: UserDefaults = AppConfig.defaults) -> [String] {
    termsToBoost(enabled: isEnabled(defaults: defaults), terms: currentTerms(defaults: defaults))
  }

  static var ctcModelDirectory: URL {
    ParakeetManager.modelsDirectory.appendingPathComponent(ctcFolderName, isDirectory: true)
  }

  /// Files the CTC model needs, including the tokenizer FluidAudio uses to
  /// tokenize plain-text terms.
  static var ctcRequiredFiles: [String] {
    #if canImport(FluidAudio)
    return ModelNames.CTC.requiredModels.sorted() + [ModelNames.CTC.vocabularyPath, "tokenizer.json"]
    #else
    return []
    #endif
  }

  static func ctcModelsPresent() -> Bool {
    ParakeetManager.missingFiles(ctcRequiredFiles, in: ctcModelDirectory).isEmpty
  }
}

#if canImport(FluidAudio)
extension ParakeetVocabularyBoosting {
  static func vocabularyContext(for terms: [String]) -> CustomVocabularyContext {
    // Plain-text terms are tokenized with the CTC tokenizer by FluidAudio when
    // the boosting session is created (FluidAudio #851).
    CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
  }
}

/// Shares one loaded copy of the CTC model between dictation and meetings.
actor ParakeetCtcModelStore {
  static let shared = ParakeetCtcModelStore()

  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "ParakeetVocab")
  private var models: CtcModels?
  private var loadTask: Task<CtcModels, Error>?
  private var downloadTask: Task<Void, Error>?

  /// CTC models only if already loaded. Never waits: otherwise it starts the
  /// load (or download) in the background and returns nil. The first CoreML
  /// load of the CTC model measured ~13 s, so dictation must not wait on it.
  func modelsIfLoaded() -> CtcModels? {
    if let models { return models }
    if loadTask == nil {
      Task { _ = await modelsIfAvailable() }
    }
    return nil
  }

  /// Loaded CTC models if they are on disk. Never waits on the network: when
  /// the model is missing this starts a background download for next time and
  /// returns nil, so the caller transcribes without boosting.
  func modelsIfAvailable() async -> CtcModels? {
    if let models { return models }
    guard ParakeetVocabularyBoosting.ctcModelsPresent() else {
      log.notice("[ParakeetVocab] CTC model missing; downloading in background")
      AppLog.dictation.log("[ParakeetVocab] CTC model missing; downloading in background")
      startBackgroundDownload()
      return nil
    }
    let task: Task<CtcModels, Error>
    if let loadTask {
      task = loadTask
    } else {
      task = Task {
        try await CtcModels.load(
          from: ParakeetVocabularyBoosting.ctcModelDirectory,
          variant: .ctc110m
        )
      }
      loadTask = task
    }
    defer { loadTask = nil }
    do {
      let loaded = try await task.value
      models = loaded
      return loaded
    } catch {
      let message = error.localizedDescription
      log.error("[ParakeetVocab] CTC load failed: \(message, privacy: .public)")
      AppLog.dictation.error("[ParakeetVocab] CTC load failed: \(message)")
      return nil
    }
  }

  /// Download the CTC model (Settings button). Coalesces with any background
  /// download already running.
  func download() async throws {
    try await downloadTaskStartingIfNeeded().value
  }

  private func startBackgroundDownload() {
    let task = downloadTaskStartingIfNeeded()
    Task { [log] in
      do {
        try await task.value
      } catch {
        let message = error.localizedDescription
        log.error("[ParakeetVocab] CTC background download failed: \(message, privacy: .public)")
        AppLog.dictation.error("[ParakeetVocab] CTC background download failed: \(message)")
      }
    }
  }

  private func downloadTaskStartingIfNeeded() -> Task<Void, Error> {
    if let downloadTask { return downloadTask }
    let task = Task<Void, Error> {
      try await CtcModels.download(
        to: ParakeetVocabularyBoosting.ctcModelDirectory,
        variant: .ctc110m
      )
    }
    downloadTask = task
    Task { [weak self] in
      _ = try? await task.value
      await self?.clearDownloadTask()
    }
    return task
  }

  private func clearDownloadTask() {
    downloadTask = nil
  }
}
#endif
