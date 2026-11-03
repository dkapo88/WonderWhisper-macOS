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
  @State private var isDownloadingCtc = false
  @State private var ctcDownloadError: String?
  // Read only, so the picker re-renders when `parakeet.version` changes (here or through sync).
  // Stored as a raw optional string so an unset value (new-install or pinned default) and a
  // legacy "v3" resolve exactly as in ParakeetModelKind.resolved(stored:). Never written here.
  @AppStorage(ParakeetModelKind.defaultsKey, store: AppConfig.defaults)
  private var parakeetVersion: String?
  // One-time "new recommended model" note for installs that kept their old model.
  @AppStorage(ParakeetModelDefaults.recommendationPendingKey, store: AppConfig.defaults)
  private var barkRecommendationPending = false
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
    .task(id: choice.localModel) {
      // Qwen's runtime owns its loaded and health state; re-read it while Settings shows Qwen.
      guard choice.localModel == .qwen else { return }
      while !Task.isCancelled {
        vm.modelStatus.apply(await QwenASRRuntime.shared.statusSnapshot())
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
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

  // MARK: - Model

  /// The picker's current choice, read from the stored engine and Parakeet model (never written
  /// by reading).
  private var choice: TranscriptionChoice {
    TranscriptionChoice.current(engine: vm.simpleVoiceEngine, storedParakeetVersion: parakeetVersion)
  }

  private var choiceBinding: Binding<TranscriptionChoice> {
    Binding(
      get: { choice },
      set: { vm.selectTranscriptionChoice($0) }
    )
  }

  private var engineSection: some View {
    Section {
      if barkRecommendationPending, choice != .parakeet(.barkClean) {
        barkRecommendation
      }

      Picker(selection: choiceBinding) {
        Section("On-device") {
          ForEach(TranscriptionChoice.available.filter { $0.localModel != nil }) { option in
            Text(option.displayName).tag(option)
          }
        }
        Section("Cloud") {
          ForEach(TranscriptionChoice.available.filter { $0.localModel == nil }) { option in
            Text(option.displayName).tag(option)
          }
        }
      } label: {
        Text("Model")
        Text(choice.detail)
      }

      if let credit = choice.parakeetModel?.credit {
        ParakeetModelCreditView(credit: credit)
      }

      if let model = choice.localModel {
        LocalModelStatusRow(model: model, status: vm.modelStatus, language: vm.transcriptionLanguage)
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
      Text("Dictation model")
    } footer: {
      Text("Changing the model during a dictation applies from the next one. Meetings always "
        + "use Parakeet Unified.")
        .settingsFootnote()
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
        detail: "Soniox V6 dictation and meetings.",
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

  private var vocabularyTermCount: Int {
    VoiceVocabularyKeyterms.terms(
      customVocabulary: vm.vocabCustom,
      spellingCorrections: vm.vocabSpelling
    ).count
  }

  private var parakeetSection: some View {
    Section {
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
      Text("Parakeet vocabulary (on-device)")
    } footer: {
      Text("Vocabulary boosting applies to English (Bark Clean and Unified) dictation and to "
        + "Parakeet meetings, where corrections land in the final transcript when the meeting "
        + "ends. It adds a short on-device pass. Meetings always use Unified.")
        .settingsFootnote()
    }
  }

  private var barkRecommendation: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
      Text("New recommended model: \(ParakeetModelKind.barkClean.displayName)")
        .font(.headline)
      Text("Bark Clean removes ums, false starts and repeated words as you dictate. "
        + "Your current choice stays selected until you switch.")
        .settingsFootnote()
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        Button("Use Bark Clean") {
          // Selects Bark Clean whatever the engine, including a cloud one.
          vm.selectTranscriptionChoice(.parakeet(.barkClean))
          barkRecommendationPending = false
        }
        Button("Dismiss") {
          // Keeps the current choice.
          barkRecommendationPending = false
        }
      }
    }
    .padding(.vertical, DesignTokens.Spacing.xSmall)
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

  private var qwenSection: some View {
    Section {
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
}
