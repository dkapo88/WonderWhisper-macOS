import AppKit
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Settings → Transcription: dictation engine, language, cloud keys, and on-device models.
struct TranscriptionSettingsPane: View {
  @ObservedObject var vm: DictationViewModel
  @State private var openRouterVoiceModels: [OpenRouterModel] = []
  @State private var isLoadingOpenRouterVoiceModels = false
  @State private var openRouterVoiceModelError: String?
  @State private var isDownloadingParakeet = false
  @State private var parakeetDownloadError: String?
  @State private var isDownloadingQwen = false
  @State private var qwenDownloadProgress: Double = 0
  @State private var qwenDownloadStatus = ""
  @State private var qwenDownloadError: String?
  @State private var isDownloadingCtc = false
  @State private var ctcDownloadError: String?
  // Selected on-device Parakeet model, persisted under "parakeet.version". Stored
  // as a raw string so a legacy "v3" reads as Ultra via ParakeetModelKind(storedValue:).
  @AppStorage(ParakeetModelKind.defaultsKey, store: AppConfig.defaults)
  private var parakeetVersion = ParakeetModelKind.unified.rawValue
  @AppStorage(ParakeetVocabularyBoosting.enabledKey, store: AppConfig.defaults)
  private var parakeetVocabularyBoosting = true
  @AppStorage("qwen.injectVocabulary", store: AppConfig.defaults)
  private var injectQwenVocabulary = true

  private let keychain = KeychainService()

  var body: some View {
    SettingsPage {
      engineSection
      if vm.simpleVoiceEngine == .openRouterTranscription {
        openRouterVoiceSection
      }
      cloudKeysSection
      parakeetSection
      qwenSection
    }
    .task {
      guard vm.simpleVoiceEngine == .openRouterTranscription else { return }
      await loadOpenRouterVoiceModelsIfNeeded()
    }
    .onChange(of: vm.simpleVoiceEngine) { _, engine in
      guard engine == .openRouterTranscription else { return }
      Task { await loadOpenRouterVoiceModelsIfNeeded() }
    }
  }

  // MARK: - Engine

  private var engineSection: some View {
    Section {
      Picker(selection: $vm.simpleVoiceEngine) {
        ForEach(SimpleVoiceEngine.availableEngines) { engine in
          Text(engine.displayName).tag(engine)
        }
      } label: {
        Text("Engine")
        Text(vm.simpleVoiceEngine.detail)
      }

      Picker(selection: $vm.transcriptionLanguage) {
        ForEach(TranscriptionLanguageOption.options) { option in
          Text(option.displayName).tag(option.code)
        }
      } label: {
        Text("Language")
        Text("Used by Grok STT and local Qwen3-ASR. Auto-detect sends no language hint.")
      }
    } header: {
      Text("Dictation engine")
    }
  }

  private var openRouterVoiceSection: some View {
    Section {
      if !openRouterVoiceModels.isEmpty {
        Picker("Voice model", selection: $vm.openRouterTranscriptionModel) {
          if !openRouterVoiceModels.contains(where: { $0.id == vm.openRouterTranscriptionModel }) {
            Text(vm.openRouterTranscriptionModel).tag(vm.openRouterTranscriptionModel)
          }
          ForEach(openRouterVoiceModels) { model in
            Text(model.displayName).tag(model.id)
          }
        }
      }

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          TextField(
            "Model ID",
            text: $vm.openRouterTranscriptionModel,
            prompt: Text(AppConfig.defaultOpenRouterTranscriptionModel)
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)

          Button {
            Task { await refreshOpenRouterVoiceModels() }
          } label: {
            if isLoadingOpenRouterVoiceModels {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(.borderless)
          .disabled(isLoadingOpenRouterVoiceModels)
          .help("Reload OpenRouter voice models")
          .accessibilityLabel("Reload OpenRouter voice models")
        }
      } label: {
        Text("Model ID")
        Text("Type any OpenRouter speech-to-text model ID.")
      }
    } header: {
      Text("OpenRouter voice")
    } footer: {
      if let openRouterVoiceModelError {
        StatusBadge(.error, openRouterVoiceModelError)
      }
    }
  }

  // MARK: - Keys

  private var cloudKeysSection: some View {
    Section {
      APIKeyRow(
        title: "Groq",
        alias: AppConfig.groqAPIKeyAlias,
        prompt: "gsk_…",
        detail: "Groq Whisper Turbo.",
        isStoredValueValid: KeychainService.isPlausibleGroqAPIKey,
        onSave: vm.saveGroqApiKey
      )
      APIKeyRow(
        title: "xAI",
        alias: AppConfig.xaiAPIKeyAlias,
        detail: "Grok STT.",
        onSave: vm.saveXaiApiKey
      )
      APIKeyRow(
        title: "Soniox",
        alias: AppConfig.sonioxAPIKeyAlias,
        detail: "Soniox V5 dictation and meetings.",
        onSave: vm.saveSonioxApiKey
      )
    } header: {
      Text("Cloud API keys")
    } footer: {
      Text("Keys are stored in your macOS Keychain. OpenRouter voice uses the OpenRouter key "
        + "in Settings → Models.")
        .settingsFootnote()
    }
  }

  // MARK: - On-device models

  private var parakeetModel: ParakeetModelKind {
    ParakeetModelKind(storedValue: parakeetVersion)
  }

  private var parakeetModelBinding: Binding<ParakeetModelKind> {
    Binding(
      get: { ParakeetModelKind(storedValue: parakeetVersion) },
      set: { parakeetVersion = $0.rawValue }
    )
  }

  private var vocabularyTermCount: Int {
    VoiceVocabularyKeyterms.terms(
      customVocabulary: vm.vocabCustom,
      spellingCorrections: vm.vocabSpelling
    ).count
  }

  private var parakeetSection: some View {
    Section {
      Picker(selection: parakeetModelBinding) {
        ForEach(ParakeetModelKind.allCases) { kind in
          Text(kind.displayName).tag(kind)
        }
      } label: {
        Text("Model")
        Text(parakeetModel.detail)
      }

      LabeledContent("Status") {
        parakeetStatus
      }

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          Button("Show in Finder") {
            NSWorkspace.shared.selectFile(
              ParakeetManager.effectiveModelsDirectory(for: parakeetModel).path,
              inFileViewerRootedAtPath: ""
            )
          }
          Button(isDownloadingParakeet ? "Downloading…" : "Download") {
            downloadParakeet()
          }
          .disabled(isDownloadingParakeet || !ParakeetManager.isLinked)
        }
      } label: {
        Text("Model files")
        Text("\(parakeetModel.approximateDownloadSize). Download ahead of your first "
          + "dictation to avoid a cold start.")
      }

      if let parakeetDownloadError {
        StatusBadge(.error, "Download failed: \(parakeetDownloadError)")
      }

      Toggle(isOn: $parakeetVocabularyBoosting) {
        Text("Boost vocabulary")
        Text(vocabularyBoostingDetail)
      }

      if parakeetVocabularyBoosting {
        LabeledContent("Vocabulary model") {
          ctcStatus
        }

        LabeledContent {
          HStack(spacing: DesignTokens.Spacing.xSmall) {
            Button("Show in Finder") {
              let dir = ParakeetVocabularyBoosting.ctcModelDirectory
              let exists = FileManager.default.fileExists(atPath: dir.path)
              NSWorkspace.shared.selectFile(
                (exists ? dir : ParakeetManager.modelsDirectory).path,
                inFileViewerRootedAtPath: ""
              )
            }
            Button(isDownloadingCtc ? "Downloading…" : "Download") {
              downloadCtc()
            }
            .disabled(isDownloadingCtc || !ParakeetManager.isLinked)
          }
        } label: {
          Text("Vocabulary model files")
          Text("\(ParakeetVocabularyBoosting.ctcApproximateDownloadSize). Parakeet CTC 110M. "
            + "Downloads automatically on first use if missing.")
        }

        if let ctcDownloadError {
          StatusBadge(.error, "Download failed: \(ctcDownloadError)")
        }
      }
    } header: {
      Text("Parakeet (on-device)")
    } footer: {
      Text("Vocabulary boosting applies to English (Unified) dictation and to Parakeet "
        + "meetings, where corrections land in the final transcript when the meeting ends. "
        + "It adds a short on-device pass.")
        .settingsFootnote()
    }
  }

  private var vocabularyBoostingDetail: String {
    let count = vocabularyTermCount
    if count == 0 {
      return "Add names on the Vocabulary page to boost them in Parakeet transcripts."
    }
    return "Rescores Parakeet transcripts toward your \(count) Vocabulary "
      + (count == 1 ? "term." : "terms.")
  }

  @ViewBuilder private var ctcStatus: some View {
    if !ParakeetManager.isLinked {
      StatusBadge(.error, "Framework missing")
    } else {
      StatusBadge.presence(
        ParakeetVocabularyBoosting.ctcModelsPresent(),
        present: "Downloaded",
        missing: "Not downloaded"
      )
    }
  }

  @ViewBuilder private var parakeetStatus: some View {
    if !ParakeetManager.isLinked {
      StatusBadge(.error, "Framework missing")
    } else {
      StatusBadge.presence(
        ParakeetManager.modelsPresent(for: parakeetModel),
        present: "Downloaded",
        missing: "Not downloaded"
      )
    }
  }

  private var qwenSection: some View {
    Section {
      LabeledContent("Status") {
        qwenStatus
      }

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          Button("Show in Finder") {
            NSWorkspace.shared.selectFile(
              QwenASRManager.effectiveCacheDirectory().path,
              inFileViewerRootedAtPath: ""
            )
          }
          Button(isDownloadingQwen ? "Downloading…" : "Download") {
            downloadQwen()
          }
          .disabled(
            isDownloadingQwen || !QwenASRManager.isLinked || !QwenASRManager.isAppleSilicon
          )
        }
      } label: {
        Text("Model files")
        Text("About 1 GB from Hugging Face, then fully offline.")
      }

      if isDownloadingQwen {
        ProgressView(value: qwenDownloadProgress, total: 1) {
          Text(qwenDownloadStatus.isEmpty ? "Downloading…" : qwenDownloadStatus)
            .settingsFootnote()
        }
      }

      if let qwenDownloadError {
        StatusBadge(.error, "Download failed: \(qwenDownloadError)")
      }

      Toggle(isOn: $injectQwenVocabulary) {
        Text("Inject vocabulary into Qwen")
        Text("Sends Vocabulary names into the decoder. Turn off if Qwen appends the list; "
          + "spelling correction still runs.")
      }
    } header: {
      Text("Qwen3-ASR 0.6B (on-device)")
    } footer: {
      Text("Qwen decodes the recording after you stop. Dictation only; not used for meetings.")
        .settingsFootnote()
    }
  }

  @ViewBuilder private var qwenStatus: some View {
    if !QwenASRManager.isLinked {
      StatusBadge(.error, "Framework missing")
    } else if !QwenASRManager.isAppleSilicon {
      StatusBadge(.error, "Requires Apple Silicon")
    } else {
      StatusBadge.presence(
        QwenASRManager.modelsPresent(),
        present: "Downloaded",
        missing: "Not downloaded"
      )
    }
  }

  // MARK: - Actions

  @MainActor
  private func loadOpenRouterVoiceModelsIfNeeded() async {
    guard openRouterVoiceModels.isEmpty else { return }
    await refreshOpenRouterVoiceModels()
  }

  @MainActor
  private func refreshOpenRouterVoiceModels() async {
    guard !isLoadingOpenRouterVoiceModels else { return }
    isLoadingOpenRouterVoiceModels = true
    openRouterVoiceModelError = nil
    defer { isLoadingOpenRouterVoiceModels = false }

    do {
      let client = OpenRouterHTTPClient(
        apiKeyProvider: { keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }
      )
      openRouterVoiceModels = try await client.fetchTranscriptionModels()
    } catch {
      openRouterVoiceModelError =
        "Could not load OpenRouter voice models: \(error.localizedDescription)"
    }
  }

  private func downloadParakeet() {
    #if canImport(FluidAudio)
    isDownloadingParakeet = true
    parakeetDownloadError = nil
    let kind = parakeetModel
    Task {
      defer { isDownloadingParakeet = false }
      do {
        switch kind {
        case .ultra:
          // Download only; the provider loads it on first dictation.
          _ = try await AsrModels.download(version: .ultra)
        case .unified:
          let manager = UnifiedAsrManager()
          try await manager.loadModels(to: ParakeetManager.modelsDirectory)
        }
      } catch {
        // Surface the failure so a silent error can't masquerade as success.
        let message = (error as NSError).localizedDescription
        parakeetDownloadError = message
        AppLog.dictation.error("[Parakeet] \(kind.rawValue) download failed: \(message)")
      }
    }
    #endif
  }

  private func downloadCtc() {
    #if canImport(FluidAudio)
    isDownloadingCtc = true
    ctcDownloadError = nil
    Task {
      defer { isDownloadingCtc = false }
      do {
        try await ParakeetCtcModelStore.shared.download()
      } catch {
        let message = (error as NSError).localizedDescription
        ctcDownloadError = message
        AppLog.dictation.error("[ParakeetVocab] CTC download failed: \(message)")
      }
    }
    #endif
  }

  private func downloadQwen() {
    isDownloadingQwen = true
    qwenDownloadError = nil
    qwenDownloadProgress = 0
    qwenDownloadStatus = "Starting…"
    Task {
      defer { isDownloadingQwen = false }
      do {
        #if canImport(Qwen3ASR)
        try await QwenASRManager.downloadModel { progress, status in
          Task { @MainActor in
            qwenDownloadProgress = progress
            qwenDownloadStatus = status
          }
        }
        #else
        throw QwenASRError.frameworkMissing
        #endif
      } catch {
        let message = (error as NSError).localizedDescription
        qwenDownloadError = message
        AppLog.dictation.error("[QwenASR] download failed: \(message)")
      }
    }
  }
}
