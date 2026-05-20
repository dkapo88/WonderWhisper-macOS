import Foundation
import Combine
import Carbon.HIToolbox
import AppKit
import ApplicationServices

struct FavoriteLLMModel: Identifiable, Codable, Hashable {
    var id: UUID
    var provider: String
    var model: String

    init(id: UUID = UUID(), provider: String, model: String) {
        self.id = id
        self.provider = provider
        self.model = model
    }

    var normalizedProvider: String { provider.lowercased() }
    var normalizedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    var key: String { "\(normalizedProvider)::\(normalizedModel.lowercased())" }
}

@MainActor
final class DictationViewModel: ObservableObject {
    @Published var status: String = "Idle"
    @Published var settingsNotice: String?
    @Published var isRecording: Bool = false {
        didSet {
            updateEscapeMonitor(isRecording: isRecording)
            // Play chime sounds for recording start/stop
            if isRecording {
                SoundFeedback.playStart()
            } else if oldValue {
                // Only play stop sound if we were previously recording
                SoundFeedback.playStop()
            }
        }
    }
    @Published var audioLevel: Float = 0
    @Published var sonioxPreviewText: String = ""  // Live transcript preview for Soniox streaming
    @Published var audioInputSelection: AudioInputSelection = AudioInputSelection.load() {
        didSet {
            guard audioInputSelection != oldValue else { return }
            audioInputSelection.persist()
        }
    }

    // Prompts
    @Published var prompts: [PromptConfiguration] = [] {
        didSet {
            Task { @MainActor [weak self] in
                self?.persistPromptLibrary()
                self?.refreshPromptHotkeys()
            }
        }
    }
    @Published var selectedPromptID: UUID? {
        didSet {
            Task { @MainActor [weak self] in
                self?.applySelection()
            }
        }
    }
    @Published var systemPrompt: String = "" {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateActivePrompt(systemText: systemPrompt)
            }
        }
    }
    @Published var userPrompt: String = "" {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateActivePrompt(userText: userPrompt)
            }
        }
    }


    @Published private var simpleDictationSettings: SimplePromptSettings = DictationViewModel.loadSimpleSettings(for: .dictation) {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleSettingsDidChange(kind: .dictation, oldValue: oldValue)
            }
        }
    }
    @Published private var simpleCommandSettings: SimplePromptSettings = DictationViewModel.loadSimpleSettings(for: .command) {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleSettingsDidChange(kind: .command, oldValue: oldValue)
            }
        }
    }
    @Published var simpleSelectedModel: String = DictationViewModel.loadSimpleSelectedModel() {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleModelDidChange(oldValue: oldValue)
            }
        }
    }
    @Published var simpleCustomModels: [String] = DictationViewModel.loadSimpleCustomModels() {
        didSet {
            Task { @MainActor [weak self] in
                self?.persistSimpleCustomModels()
            }
        }
    }
    @Published var customDictationPromptTemplates: [SimplePromptTemplate] = DictationViewModel.loadCustomDictationPromptTemplates() {
        didSet {
            Task { @MainActor [weak self] in
                self?.persistCustomDictationPromptTemplates()
            }
        }
    }
    @Published var selectedDictationPromptTemplateID: UUID?
    @Published var simpleLLMEnabled: Bool = DictationViewModel.loadSimpleLLMEnabled() {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleLLMEnabledDidChange(oldValue: oldValue)
            }
        }
    }
    @Published var simpleVoiceEngine: SimpleVoiceEngine = DictationViewModel.loadSimpleVoiceEngine() {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleVoiceEngineDidChange(oldValue: oldValue)
            }
        }
    }
    @Published var simpleSidebarSelection: SimpleSidebarItem = DictationViewModel.loadSimpleSidebarSelection() {
        didSet {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simpleSidebarSelectionDidChange(oldValue: oldValue)
            }
        }
    }

    var simpleDictation: SimplePromptSettings { simpleDictationSettings }
    var simpleCommand: SimplePromptSettings { simpleCommandSettings }
    var simpleModelOptions: [SimpleModelOption] { SimpleModeDefaults.modelOptions(custom: simpleCustomModels) }
    var dictationPromptTemplates: [SimplePromptTemplate] {
        SimplePromptTemplateLibrary.builtInDictationTemplates + customDictationPromptTemplates
    }

    // Transcription + LLM preferences
    @Published var transcriptionModel: String = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel { didSet { persistAndUpdate() } }
    // Groq Whisper options
    @Published var transcriptionLanguage: String = UserDefaults.standard.string(forKey: "transcription.language") ?? "en" {
        didSet {
            UserDefaults.standard.set(transcriptionLanguage, forKey: "transcription.language")
            updateProviders()
        }
    }
    @Published var openRouterTranscriptionModel: String = DictationViewModel.loadOpenRouterTranscriptionModel() {
        didSet {
            let trimmed = openRouterTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = trimmed.isEmpty ? AppConfig.defaultOpenRouterTranscriptionModel : trimmed
            if final != openRouterTranscriptionModel {
                openRouterTranscriptionModel = final
                return
            }
            UserDefaults.standard.set(final, forKey: "transcription.openrouter.model")
            if simpleVoiceEngine == .openRouterTranscription {
                transcriptionModel = final
                applySimplePrompts()
            }
            transcriptionProviderCache.removeValue(forKey: oldValue)
            transcriptionProviderCache.removeValue(forKey: final)
        }
    }

    @Published var llmEnabled: Bool = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var screenContextEnabled: Bool = UserDefaults.standard.object(forKey: "screenContext.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var screenContextCaptureMode: ScreenContextCaptureMode = {
        if let raw = UserDefaults.standard.string(forKey: "screenContext.captureMode"),
           let mode = ScreenContextCaptureMode(rawValue: raw) {
            return mode
        }
        return .image
    }() { didSet { UserDefaults.standard.set(screenContextCaptureMode.rawValue, forKey: "screenContext.captureMode"); persistAndUpdate() } }
    @Published var clipboardContextEnabled: Bool = UserDefaults.standard.object(forKey: "clipboardContext.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }

    @Published var llmModel: String = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel { didSet { persistAndUpdate() } }
    // LLM provider selection: "groq" (default) or "openrouter"
    let llmProvider: String = "openrouter"
    // OpenRouter routing preference: "latency" or "throughput"
    @Published var openrouterRouting: String = UserDefaults.standard.string(forKey: "llm.openrouter.routing") ?? "auto" { didSet { persistAndUpdate() } }
    @Published var openrouterReasoning: OpenRouterReasoningMode = {
        let raw = UserDefaults.standard.string(forKey: "llm.openrouter.reasoning") ?? OpenRouterReasoningMode.omit.rawValue
        return OpenRouterReasoningMode(rawValue: raw) ?? .omit
    }() { didSet { persistAndUpdate() } }
    @Published var llmStreaming: Bool = UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(llmStreaming, forKey: "llm.streaming")
            updateProviders()
        }
    }
    @Published var llmTemperature: Double = UserDefaults.standard.object(forKey: "llm.temperature") as? Double ?? 0.2 {
        didSet {
            UserDefaults.standard.set(llmTemperature, forKey: "llm.temperature")
            updateProviders()
        }
    }
    @Published var favoriteLLMModels: [FavoriteLLMModel] = DictationViewModel.loadFavoriteLLMModels() {
        didSet { persistFavoriteLLMModels() }
    }
    
    @Published var favoriteOpenRouterModels: [FavoriteOpenRouterModel] = DictationViewModel.loadFavoriteOpenRouterModels() {
        didSet { persistFavoriteOpenRouterModels() }
    }

    @Published var hermesAgentEnabled: Bool = UserDefaults.standard.object(forKey: "hermes.agent.enabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hermesAgentEnabled, forKey: "hermes.agent.enabled")
            refreshPromptHotkeys()
        }
    }
    @Published var hermesBaseURLString: String = UserDefaults.standard.string(forKey: "hermes.api.baseURL") ?? AppConfig.defaultHermesBaseURLString {
        didSet { UserDefaults.standard.set(hermesBaseURLString, forKey: "hermes.api.baseURL") }
    }
    @Published var hermesConversationName: String = UserDefaults.standard.string(forKey: "hermes.conversation.name") ?? AppConfig.defaultHermesConversationName {
        didSet { UserDefaults.standard.set(hermesConversationName, forKey: "hermes.conversation.name") }
    }
    @Published var hermesModel: String = UserDefaults.standard.string(forKey: "hermes.model") ?? AppConfig.defaultHermesModel {
        didSet { UserDefaults.standard.set(hermesModel, forKey: "hermes.model") }
    }
    @Published var hermesProfileName: String = UserDefaults.standard.string(forKey: "hermes.profile.name") ?? "" {
        didSet { UserDefaults.standard.set(hermesProfileName, forKey: "hermes.profile.name") }
    }
    @Published var hermesTimeoutSeconds: Double = {
        let value = UserDefaults.standard.object(forKey: "hermes.timeout") as? Double
            ?? HermesAgentSettings.defaultTimeout
        return HermesAgentSettings.clampedTimeout(value)
    }() {
        didSet {
            UserDefaults.standard.set(
                HermesAgentSettings.clampedTimeout(hermesTimeoutSeconds),
                forKey: "hermes.timeout"
            )
        }
    }
    @Published var hermesSelection: HotkeyManager.Selection? = DictationViewModel.loadHermesSelection() {
        didSet {
            persistHermesSelection()
            refreshPromptHotkeys()
        }
    }
    @Published var hermesScreenContextEnabled: Bool = {
        let key = SimpleDefaultsKey.hermesScreenContextEnabled
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(
                hermesScreenContextEnabled,
                forKey: SimpleDefaultsKey.hermesScreenContextEnabled
            )
        }
    }
    @Published var hermesScreenshotEnabled: Bool = {
        let key = SimpleDefaultsKey.hermesScreenshotEnabled
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(
                hermesScreenshotEnabled,
                forKey: SimpleDefaultsKey.hermesScreenshotEnabled
            )
        }
    }
    @Published var hermesClipboardContextEnabled: Bool = {
        let key = SimpleDefaultsKey.hermesClipboardContextEnabled
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(
                hermesClipboardContextEnabled,
                forKey: SimpleDefaultsKey.hermesClipboardContextEnabled
            )
            let enabled = hermesClipboardContextEnabled
            Task { await hermesClipboardMonitor.setMonitoringEnabled(enabled) }
        }
    }
    @Published var hermesClipboardTimeoutSeconds: Double = {
        let key = SimpleDefaultsKey.hermesClipboardTimeoutSeconds
        let value = UserDefaults.standard.object(forKey: key) as? Double
            ?? HermesClipboardContextPolicy.defaultRetentionWindow
        return HermesClipboardContextPolicy.clampedRetentionWindow(value)
    }() {
        didSet {
            let clamped = HermesClipboardContextPolicy.clampedRetentionWindow(
                hermesClipboardTimeoutSeconds
            )
            UserDefaults.standard.set(clamped, forKey: SimpleDefaultsKey.hermesClipboardTimeoutSeconds)
            if clamped != hermesClipboardTimeoutSeconds {
                hermesClipboardTimeoutSeconds = clamped
            }
        }
    }
    @Published var hermesPostProcessingEnabled: Bool = {
        let key = SimpleDefaultsKey.hermesPostProcessingEnabled
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(
                hermesPostProcessingEnabled,
                forKey: SimpleDefaultsKey.hermesPostProcessingEnabled
            )
        }
    }
    @Published var hermesConnectionStatus: String?
    @Published var hermesConnectionSucceeded: Bool?
    @Published var hermesResponseWindowState: HermesResponseWindowState?
    @Published var hermesResponseWindowStates: [HermesResponseWindowState] = []
    @Published var hermesIsSending: Bool = false
    @Published private(set) var hermesPendingResponseCount: Int = 0
    @Published var hermesChatMessages: [HermesChatMessage] = []
    @Published var hermesSessions: [HermesChatSession] = []
    @Published var selectedHermesSessionID: UUID? {
        didSet { updateHermesChatProjection() }
    }

    @Published var audioStreamEQEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "audio.stream.eq.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "audio.stream.eq.enabled")
    }() { didSet { UserDefaults.standard.set(audioStreamEQEnabled, forKey: "audio.stream.eq.enabled") } }
    @Published var audioStreamDynamicsEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "audio.stream.dynamics.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "audio.stream.dynamics.enabled")
    }() { didSet { UserDefaults.standard.set(audioStreamDynamicsEnabled, forKey: "audio.stream.dynamics.enabled") } }
    @Published var audioStreamChunkMs: Int = {
        let v = UserDefaults.standard.integer(forKey: "audio.stream.chunkMs")
        return v > 0 ? v : 20
    }() { didSet { UserDefaults.standard.set(audioStreamChunkMs, forKey: "audio.stream.chunkMs") } }

    // Networking
    @Published var transcriptionTimeoutSeconds: Double = {
        let v = UserDefaults.standard.object(forKey: "transcription.timeout") as? Double ?? 10
        return max(5, min(120, v))
    }() { didSet { UserDefaults.standard.set(transcriptionTimeoutSeconds, forKey: "transcription.timeout"); updateProviders() } }
    @Published var httpProtocolPreference: HTTPProtocolPreference = AppConfig.httpProtocolPreference {
        didSet {
            UserDefaults.standard.set(httpProtocolPreference.rawValue, forKey: "network.http_protocol_preference")
            // Notify providers to recreate sessions with new preference
            NotificationCenter.default.post(name: .networkProtocolPreferenceChanged, object: nil)
        }
    }

    // Audio
    @Published var audioEnhancementEnabled: Bool = UserDefaults.standard.bool(forKey: "audio.preprocess.enabled") {
        didSet { UserDefaults.standard.set(audioEnhancementEnabled, forKey: "audio.preprocess.enabled") }
    }
    @Published var voiceProcessingEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "audio.voiceProcessing.enabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "audio.voiceProcessing.enabled")
    }() {
        didSet { UserDefaults.standard.set(voiceProcessingEnabled, forKey: "audio.voiceProcessing.enabled") }
    }
    @Published var chimeVolume: Double = Double(SoundFeedback.currentVolumeScale()) {
        didSet {
            // Ensure value is in valid range and update SoundFeedback immediately
            let clamped = max(0.0, min(1.0, chimeVolume))
            // Only clamp if out of range (avoid unnecessary recursion)
            if clamped != chimeVolume {
                chimeVolume = clamped
            } else {
                // Value is already valid, update SoundFeedback
                SoundFeedback.setVolumeScale(clamped)
            }
        }
    }
    @Published var autoMuteEnabled: Bool = UserDefaults.standard.object(forKey: "recording.autoMute.enabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(autoMuteEnabled, forKey: "recording.autoMute.enabled")
        }
    }

    // Vocabulary
    @Published var vocabCustom: String = UserDefaults.standard.string(forKey: "vocab.custom") ?? "" { didSet { persistAndUpdate() } }
    @Published var vocabSpelling: String = UserDefaults.standard.string(forKey: "vocab.spelling") ?? "" { didSet { persistAndUpdate() } }

    private var isApplyingSimplePrompts: Bool = false
    private var isUpdatingSimpleSidebar: Bool = false
    private var suppressSimpleSidebarSync: Bool = false
    private var recordingStartTimestamp: Date? = nil  // Track optimistic recording start to prevent timer race
    private var recordingStartInProgress: Bool = false
    private var recordingStopInProgress: Bool = false
    private var idleSkipCounter: Int = 0
    private var timer: Timer?
    let history = HistoryStore()
    private let hermesSessionStore = HermesSessionStore()
    private let promptHotkeyManager = PromptHotkeyManager()
    private var controller: DictationController!
    private var isApplyingPromptFromSelection = false
    private var providerUpdateTask: Task<Void, Never>?
    private var selectedTextPromptOverride: PromptConfiguration?
    private var selectedTextFallbackTaskID: UUID?
    private lazy var hermesClient = HermesAgentAPIClient(
        apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.hermesAPIKeyAlias) }
    )
    private var activeHermesPromptID: UUID?
    private var activeHermesRecordingSessionID: UUID?
    private var focusedHermesResponseSessionID: UUID?
    private var hermesInFlightSessionIDs: Set<UUID> = []
    private var hermesActiveRequestIDs: [UUID: UUID] = [:]
    private var hermesTitleRequestIDs: [UUID: UUID] = [:]
    private var hermesScreenshotTask: Task<ScreenCaptureSnapshot?, Never>?
    private var hermesClipboardTask: Task<String?, Never>?
    private let hermesClipboardMonitor = ClipboardContextMonitor(
        maximumRetentionWindow: HermesClipboardContextPolicy.maximumRetentionWindow,
        startsEnabled: UserDefaults.standard.object(
            forKey: SimpleDefaultsKey.hermesClipboardContextEnabled
        ) as? Bool ?? true
    )

    // Debouncing for provider updates
    private var providerUpdateTimer: Timer?
    private let providerUpdateDebounceInterval: TimeInterval = 0.5 // 500ms debounce

    // Provider cache to avoid unnecessary recreation
    private var transcriptionProviderCache: [String: TranscriptionProvider] = [:]
    private var llmProviderCache: [String: LLMProvider] = [:]

    // Global Escape key monitor (enabled only while recording)
    private var escapeEventMonitor: Any?
    // Global Escape key interceptor using CGEventTap (can suppress the key)
    private var escapeKeyInterceptor: EscapeKeyInterceptor?

    // Hotkey
    private let hotkeys = HotkeyManager()
    @Published var hotkeySelection: HotkeyManager.Selection = {
        if let raw = UserDefaults.standard.string(forKey: "hotkey.selection"), let sel = HotkeyManager.Selection(rawValue: raw) {
            return sel
        }
        return .fnGlobe
    }() { didSet { updateHotkeys() } }

    // Paste-last shortcut (default: Control + Command + V)
    @Published var pasteShortcut: HotkeyManager.Shortcut = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pasteShortcut.keyCode") != nil,
           defaults.object(forKey: "pasteShortcut.modifiers") != nil {
            let key = UInt32(defaults.integer(forKey: "pasteShortcut.keyCode"))
            let mod = UInt32(defaults.integer(forKey: "pasteShortcut.modifiers"))
            return HotkeyManager.Shortcut(keyCode: key, modifiers: mod)
        }
        return HotkeyManager.Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey))
    }() { didSet { updatePasteShortcut() } }

    // Insertion
    @Published var useAXInsertion: Bool = UserDefaults.standard.object(forKey: "insertion.useAX") as? Bool ?? false { didSet { updateInsertion() } }
    @Published var pasteFormatted: Bool = UserDefaults.standard.object(forKey: "insertion.pasteFormatted") as? Bool ?? false {
        didSet { UserDefaults.standard.set(pasteFormatted, forKey: "insertion.pasteFormatted") }
    }

    init() {
        // Capture persisted settings locally to avoid referencing self before all properties are initialized
        let persistedVocabCustom = UserDefaults.standard.string(forKey: "vocab.custom") ?? ""
        let persistedVocabSpelling = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        let persistedUseAXInsertion = UserDefaults.standard.object(forKey: "insertion.useAX") as? Bool ?? false
        // Legacy long-form prompt that previously seeded the system message
        let legacyBasePrompt = UserDefaults.standard.string(forKey: "llm.userPrompt") ?? AppConfig.defaultDictationPrompt

        let keychain = KeychainService()
        let http = GroqHTTPClient(apiKeyProvider: { keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) })

        let activeTranscriptionModel = Self.voiceModel(
            for: simpleVoiceEngine,
            openRouterModel: openRouterTranscriptionModel
        )
        let activeLLMEnabled = simpleLLMEnabled
        let activeScreenContextEnabled = simpleShouldEnableScreenContext()
        let activeClipboardContextEnabled = simpleShouldEnableClipboard()
        let activeLLMModel = simpleSelectedModel
        let initialVoiceVocabularyTerms = VoiceVocabularyKeyterms.terms(
            customVocabulary: persistedVocabCustom,
            spellingCorrections: persistedVocabSpelling
        )

        let transcriptionTimeout = max(5, min(120, UserDefaults.standard.object(forKey: "transcription.timeout") as? Double ?? 10))
        let transcriber: TranscriptionProvider
        let transcriberSettings: TranscriptionSettings
        if activeTranscriptionModel.lowercased().contains("parakeet") {
            transcriber = ParakeetTranscriptionProvider()
            transcriberSettings = TranscriptionSettings(
                endpoint: URL(string: "https://localhost")!,
                model: activeTranscriptionModel,
                language: transcriptionLanguage,
                vocabularyTerms: initialVoiceVocabularyTerms
            )
        } else if Self.isOpenRouterTranscriptionModel(activeTranscriptionModel) {
            transcriber = OpenRouterTranscriptionProvider(
                client: OpenRouterHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
                })
            )
            transcriberSettings = TranscriptionSettings(
                endpoint: AppConfig.openrouterAudioTranscriptions,
                model: activeTranscriptionModel,
                timeout: transcriptionTimeout,
                language: transcriptionLanguage,
                vocabularyTerms: initialVoiceVocabularyTerms
            )
        } else if activeTranscriptionModel == AppConfig.defaultXAIStreamingTranscriptionModel {
            transcriber = XAIStreamingTranscriptionProvider(
                apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias)
                }
            )
            transcriberSettings = TranscriptionSettings(
                endpoint: AppConfig.xaiSpeechToTextStreaming,
                model: activeTranscriptionModel,
                timeout: transcriptionTimeout,
                language: transcriptionLanguage,
                vocabularyTerms: initialVoiceVocabularyTerms
            )
        } else if activeTranscriptionModel == AppConfig.defaultXAITranscriptionModel {
            transcriber = XAITranscriptionProvider(
                client: XAIHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias)
                })
            )
            transcriberSettings = TranscriptionSettings(
                endpoint: AppConfig.xaiSpeechToText,
                model: activeTranscriptionModel,
                timeout: transcriptionTimeout,
                language: transcriptionLanguage,
                vocabularyTerms: initialVoiceVocabularyTerms
            )
        } else {
            transcriber = GroqTranscriptionProvider(client: http)
            transcriberSettings = TranscriptionSettings(
                endpoint: AppConfig.groqAudioTranscriptions,
                model: activeTranscriptionModel,
                timeout: transcriptionTimeout,
                language: transcriptionLanguage,
                vocabularyTerms: initialVoiceVocabularyTerms
            )
        }

        // Choose initial LLM provider/endpoints based on persisted settings
        let storedSystem = UserDefaults.standard.string(forKey: "llm.systemPrompt") ?? AppConfig.defaultSystemPromptTemplate
        let storedUser = UserDefaults.standard.string(forKey: "llm.userMessage") ?? ""
        let promptBootstrap = DictationViewModel.bootstrapPromptLibrary(initialSystem: storedSystem, initialUser: storedUser, legacyBasePrompt: legacyBasePrompt)

        let renderedInitial = PromptBuilder.renderSystemPrompt(template: promptBootstrap.activeSystem, customVocabulary: persistedVocabCustom)

        let canonicalPersistedModel = Self.canonicalLLMModel(for: activeLLMModel)
        let llm = OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }))
        let llmSettings = LLMSettings(
            endpoint: AppConfig.openrouterChatCompletions,
            model: canonicalPersistedModel,
            systemPrompt: renderedInitial,
            timeout: 60,
            streaming: UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false,
            temperature: UserDefaults.standard.object(forKey: "llm.temperature") as? Double ?? 0.2,
            openRouterReasoning: Self.loadOpenRouterReasoning()
        )
        GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)

        let recorder = AudioRecorder()
        let inserter = InsertionService()
        inserter.useAXInsertion = persistedUseAXInsertion
        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            transcriberSettings: transcriberSettings,
            llm: llm,
            llmSettings: llmSettings,
            inserter: inserter,
            history: history
        )
        isApplyingPromptFromSelection = true
        prompts = promptBootstrap.prompts
        selectedPromptID = promptBootstrap.selectedID
        systemPrompt = promptBootstrap.activeSystem
        userPrompt = promptBootstrap.activeUser
        isApplyingPromptFromSelection = false
        persistPromptLibrary()
        // Now that self is fully initialized, hook up level monitoring
        recorder.onLevel = { [weak self] level in
            guard let self = self else { return }
            Task { @MainActor in self.audioLevel = level }
        }
        Task {
            await hermesClipboardMonitor.start()
            await controller.updateLLMEnabled(activeLLMEnabled)
            await controller.updateScreenContextEnabled(activeScreenContextEnabled)
            await controller.updateScreenContextCaptureMode(screenContextCaptureMode)
            await controller.updateClipboardContextEnabled(activeClipboardContextEnabled)
            await controller.updateActiveTextFieldEnabled(resolvedActiveTextField(for: nil))
        }

        promptHotkeyManager.onPromptEvent = { [weak self] id, phase in
            Task { await self?.handlePromptHotkey(id: id, phase: phase) }
        }
        refreshPromptHotkeys()

        configureSimpleModeState()
        let loadedHermesSessions = hermesSessionStore.loadSessions()
        hermesSessions = HermesSessionRecovery.recoverAfterAppLaunch(loadedHermesSessions)
        if hermesSessions != loadedHermesSessions {
            hermesSessions = hermesSessionStore.save(hermesSessions)
        }
        selectedHermesSessionID = hermesSessions.first?.id
        updateHermesChatProjection()

        // Hotkey callbacks
        hotkeys.onActivate = { [weak self] in self?.toggle() }
        hotkeys.onPaste = { [weak self] in self?.pasteLastTranscription() }

        // Load saved hotkey selection
        updateHotkeys()
        updateProviders()
        updatePasteShortcut()

        // Poll state periodically for a simple UI reflection
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Throttle controller polling when idle to reduce wakeups.
                let isActive = self.isRecording
                    || self.hermesIsSending
                    || self.status == "Transcribing"
                    || self.status == "Processing"
                    || self.status == "Inserting"
                if !isActive {
                    self.idleSkipCounter = (self.idleSkipCounter + 1) % 5 // ~1 Hz when idle
                    if self.idleSkipCounter != 0 { return }
                } else {
                    self.idleSkipCounter = 0
                }
                let s = await self.controllerState()
                if self.hermesIsSending, s != "Recording", s != "Transcribing" {
                    if self.status != "Waiting for Hermes" { self.status = "Waiting for Hermes" }
                    return
                }
                if self.status != s { self.status = s }
                let rec = (s == "Recording")

                // Prevent race condition: Don't reset isRecording to false while startup is still in progress
                if !rec && self.isRecording {
                    if self.recordingStartInProgress {
                        return
                    }
                    if let startTime = self.recordingStartTimestamp,
                       Date().timeIntervalSince(startTime) < 1.5 {
                        // Within grace period after optimistic start - don't reset yet
                        return
                    }
                }
                if rec && !self.isRecording && self.recordingStopInProgress {
                    return
                }
                if !rec {
                    self.recordingStopInProgress = false
                }

                if self.isRecording != rec {
                    self.isRecording = rec
                    if rec {
                        self.recordingStartInProgress = false
                        self.recordingStopInProgress = false
                    } else {
                        self.recordingStartTimestamp = nil
                        self.recordingStartInProgress = false
                        self.recordingStopInProgress = false
                    }
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let m = escapeEventMonitor { NSEvent.removeMonitor(m) }
        escapeEventMonitor = nil
        escapeKeyInterceptor?.stop()
        escapeKeyInterceptor = nil
        providerUpdateTask?.cancel()  // Cancel any pending provider update
        providerUpdateTask = nil
        providerUpdateTimer?.invalidate()  // Clean up debounce timer
        providerUpdateTimer = nil
        // Provider cache will be cleaned up automatically when object is deallocated
    }

    private func controllerState() async -> String {
        let s = await controller.currentState()
        switch s {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .processing: return "Processing"
        case .inserting: return "Inserting"
        case .error(let message): return "Error: \(message)"
        }
    }

    func toggle() {
        Task {
            let currentState = await controller.currentState()
            if case .recording = currentState,
               let hermesPromptID = activeHermesPromptID,
               let sessionID = activeHermesRecordingSessionID {
                await finishHermesRecording(promptID: hermesPromptID, sessionID: sessionID)
                return
            }

            switch currentState {
            case .idle, .error:
                let targetPromptID = await MainActor.run { self.determinePromptIDForCurrentHotkey() }

                // Update UI IMMEDIATELY for instant feedback
                await MainActor.run { 
                    self.isRecording = true
                    self.recordingStartTimestamp = Date()
                    self.recordingStartInProgress = true
                    self.recordingStopInProgress = false
                }

                // Determine which prompt to use based on the hotkey that was pressed,
                // NOT based on the UI tab selection. Don't change the visible UI tab.
                await MainActor.run {
                    if self.selectedPromptID != targetPromptID {
                        // Suppress sidebar sync to prevent UI navigation when using hotkeys
                        self.suppressSimpleSidebarSync = true
                        self.selectedPromptID = targetPromptID
                    }
                }
                
                // Wait briefly for applySelection() to complete, then restore sync
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                await MainActor.run {
                    self.suppressSimpleSidebarSync = false
                }

                // Now perform slower operations after UI is updated
                await MainActor.run { self.persistPromptLibrary() }
                await MainActor.run { self.updateProvidersImmediately() }
                await waitForLatestProviderUpdate()

                // Fast check for selected text (AX only, ~5ms, no pasteboard fallback)
                await checkAndStoreSelectedTextPromptFast()

                let prompt = await MainActor.run { self.userPrompt }
                let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == self.selectedPromptID }) }
                await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)
                await MainActor.run { self.recordingStartInProgress = false }

            case .recording:
                await MainActor.run { 
                    self.recordingStopInProgress = true
                    self.isRecording = false
                    self.recordingStartTimestamp = nil
                    self.recordingStartInProgress = false
                }
                await MainActor.run { self.persistPromptLibrary() }
                let prompt = await MainActor.run { self.userPrompt }
                let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == self.selectedPromptID }) }
                await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)

            default:
                break
            }
        }
    }

    func finish() {
        persistPromptLibrary()
        Task {
            if let hermesPromptID = activeHermesPromptID,
               let sessionID = activeHermesRecordingSessionID {
                await finishHermesRecording(promptID: hermesPromptID, sessionID: sessionID)
                return
            }

            // Optimistically update UI immediately for snappy visual feedback
            await MainActor.run { 
                self.recordingStopInProgress = true
                self.isRecording = false
                self.recordingStartTimestamp = nil
                self.recordingStartInProgress = false
            }

            // If we have a selected text prompt override, ensure providers are updated before LLM processing
            if selectedTextPromptOverride != nil {
                await MainActor.run {
                    // Temporarily apply the selected text prompt to ensure providers use it
                    if let override = self.selectedTextPromptOverride {
                        self.isApplyingPromptFromSelection = true
                        self.systemPrompt = override.systemPrompt
                        self.userPrompt = override.userPrompt
                        self.isApplyingPromptFromSelection = false
                    }
                }
                await updateProvidersWithSelectedTextOverride()
            }

            let prompt = await MainActor.run { self.userPrompt }
            let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == self.selectedPromptID }) }
            await controller.finish(userPrompt: prompt, activePrompt: activePrompt)

            // Restore original prompt if we had a selected text override
            await restoreOriginalPromptIfNeeded()
        }
    }

    func cancel() {
        Task {
            // Optimistically update UI immediately for snappy visual feedback
            await MainActor.run { 
                self.recordingStopInProgress = true
                self.isRecording = false
                self.recordingStartTimestamp = nil
                self.recordingStartInProgress = false
                self.clearActiveHermesRecording(cancelContext: true)
            }
            await controller.cancel()

            // Restore original prompt if we had a selected text override
            await restoreOriginalPromptIfNeeded()
        }
    }

    private func updateEscapeMonitor(isRecording: Bool) {
        // Remove any existing listeners first
        if let m = escapeEventMonitor { NSEvent.removeMonitor(m) }
        escapeEventMonitor = nil
        escapeKeyInterceptor?.stop()
        escapeKeyInterceptor = nil

        guard isRecording else { return }

        // Prefer a CGEventTap so we can swallow Escape globally while recording
        // Ensure we have Accessibility trust (required to intercept/modify events)
        if requestAccessibilityTrustIfNeeded() {
            let interceptor = EscapeKeyInterceptor()
            interceptor.onEscape = { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
            if interceptor.start() {
                escapeKeyInterceptor = interceptor
                return
            }
        }

        // Fallback: monitor (cannot suppress) if tap could not be installed
        escapeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) in
            guard let self = self else { return }
            if event.keyCode == 53 { // kVK_Escape
                self.cancel()
            }
        }
    }

    // Request Accessibility permission (AX) so we can install a non-listen-only event tap.
    // Returns true if trusted (either already or after prompting), false otherwise.
    private func requestAccessibilityTrustIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        return trusted
    }

    // MARK: - Global Escape interceptor (CGEventTap)
    // Lives in the same file to avoid Xcode project changes.
    private final class EscapeKeyInterceptor {
        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        var onEscape: (() -> Void)?

        func start() -> Bool {
            // Create an event tap at the head so we can intercept before delivery
            let mask = (1 << CGEventType.keyDown.rawValue)
            let callback: CGEventTapCallBack = { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EscapeKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if keycode == 53 { // kVK_Escape
                    me.onEscape?()
                    // Swallow Escape so it doesn't reach the focused app
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            // Pass self via refcon so callback can reach our closure
            let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: refcon
            ) else { return false }

            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            guard let source = runLoopSource else { return false }

            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        func stop() {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            eventTap = nil
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            }
            runLoopSource = nil
        }
    }

    func saveGroqApiKey(_ value: String) {
        guard KeychainService.isPlausibleGroqAPIKey(value) else {
            settingsNotice = KeychainServiceError.invalidGroqKey.localizedDescription
            return
        }

        let kc = KeychainService()
        do {
            try kc.setSecret(value, forKey: AppConfig.groqAPIKeyAlias)
            settingsNotice = "Groq API key saved."
            transcriptionProviderCache.removeValue(forKey: "groq-streaming")
            transcriptionProviderCache.removeValue(forKey: AppConfig.defaultTranscriptionModel)
        } catch {
            settingsNotice = "Could not save Groq API key: \(error.localizedDescription)"
        }
    }

    func saveOpenRouterKey(_ value: String) {
        let kc = KeychainService()
        do {
            try kc.setSecret(value, forKey: AppConfig.openrouterAPIKeyAlias)
            settingsNotice = "OpenRouter API key saved."
            llmProviderCache.removeAll()
        } catch {
            settingsNotice = "Could not save OpenRouter API key: \(error.localizedDescription)"
        }
    }

    func saveSonioxApiKey(_ value: String) {
        let kc = KeychainService()
        do {
            try kc.setSecret(value, forKey: AppConfig.sonioxAPIKeyAlias)
            settingsNotice = "Soniox API key saved."
        } catch {
            settingsNotice = "Could not save Soniox API key: \(error.localizedDescription)"
            return
        }
        // Clear the cached provider so it gets recreated with the new key
        transcriptionProviderCache.removeValue(forKey: "soniox-streaming")
    }

    func saveXaiApiKey(_ value: String) {
        let kc = KeychainService()
        do {
            try kc.setSecret(value, forKey: AppConfig.xaiAPIKeyAlias)
            settingsNotice = "xAI API key saved."
            transcriptionProviderCache.removeValue(forKey: AppConfig.defaultXAITranscriptionModel)
            transcriptionProviderCache.removeValue(forKey: AppConfig.defaultXAIStreamingTranscriptionModel)
        } catch {
            settingsNotice = "Could not save xAI API key: \(error.localizedDescription)"
        }
    }

    private func updateHotkeys() {
        // Simple mode registers dictation/command activation through PromptHotkeyManager.
        // Keep this legacy manager available for paste-last only, so stale hotkey.selection
        // values cannot trigger recording behind the visible prompt shortcut settings.
        UserDefaults.standard.removeObject(forKey: "hotkey.selection")
        hotkeys.selection = nil
    }

    private func updatePasteShortcut() {
        UserDefaults.standard.set(pasteShortcut.keyCode, forKey: "pasteShortcut.keyCode")
        UserDefaults.standard.set(pasteShortcut.modifiers, forKey: "pasteShortcut.modifiers")
        hotkeys.pasteShortcut = pasteShortcut
    }

    private func updateInsertion() {
        UserDefaults.standard.set(useAXInsertion, forKey: "insertion.useAX")
        // InsertionService instance is held inside controller; no direct setter. This flag will be refreshed on next controller creation.
    }

    // MARK: - Prompt management

    func addPrompt() {
        let baseName = "Prompt"
        var counter = 1
        var candidate = "\(baseName) \(counter)"
        let existingNames = Set(prompts.map { $0.name.lowercased() })
        while existingNames.contains(candidate.lowercased()) {
            counter += 1
            candidate = "\(baseName) \(counter)"
        }
        let newPrompt = PromptConfiguration(name: candidate, systemPrompt: AppConfig.defaultSystemPromptTemplate, userPrompt: "")
        prompts.append(newPrompt)
        selectedPromptID = newPrompt.id
    }

    func deletePrompt(id: UUID) {
        guard prompts.count > 1 else { return }
        if let idx = prompts.firstIndex(where: { $0.id == id }) {
            prompts.remove(at: idx)
            if selectedPromptID == id {
                selectedPromptID = prompts.first?.id
            }
        }
    }

    func clearConversationHistory(for promptID: UUID) {
        Task {
            await controller.clearConversationHistory(for: promptID)
        }
    }

    func updatePrompt(_ updated: PromptConfiguration) {
        guard let idx = prompts.firstIndex(where: { $0.id == updated.id }) else { return }
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            systemPrompt = updated.systemPrompt
            userPrompt = updated.userPrompt
        }
    }

    func movePrompt(id: UUID, to destinationIndex: Int) {
        guard let currentIndex = prompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = prompts.remove(at: currentIndex)
        let targetIndex = max(0, min(destinationIndex, prompts.count))
        prompts.insert(prompt, at: targetIndex)
    }

    func renamePrompt(id: UUID, to newName: String) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if prompts[idx].name == trimmed { return }
        var updated = prompts[idx]
        updated.name = trimmed
        prompts[idx] = updated
    }

    func updateShortcut(for id: UUID, to shortcut: HotkeyManager.Shortcut?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        updated.shortcut = shortcut
        if shortcut != nil { updated.selection = nil }
        var newPrompts = prompts
        newPrompts[idx] = updated

        if let shortcut {
            for i in newPrompts.indices where i != idx {
                if newPrompts[i].shortcut == shortcut {
                    newPrompts[i].shortcut = nil
                }
            }
        }

        prompts = newPrompts
    }

    func updateSelection(for id: UUID, to selection: HotkeyManager.Selection?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        updated.selection = selection
        if selection != nil { updated.shortcut = nil }
        var newPrompts = prompts
        newPrompts[idx] = updated

        if let selection {
            for i in newPrompts.indices where i != idx {
                if newPrompts[i].selection == selection {
                    newPrompts[i].selection = nil
                }
            }
        }

        prompts = newPrompts
    }

    func updateLLMOverride(for id: UUID, model overrideModel: String?, provider overrideProvider: String?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        let normalizedModel = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = overrideProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelValue = (normalizedModel?.isEmpty ?? true) ? nil : normalizedModel
        let providerValue: String?
        if let provider = normalizedProvider, !provider.isEmpty,
           provider.caseInsensitiveCompare(llmProvider) != .orderedSame {
            providerValue = provider.lowercased()
        } else {
            providerValue = nil
        }
        var updated = prompts[idx]
        let currentProviderValue = updated.llmProviderOverride?.lowercased() ?? ""
        let newProviderValue = providerValue?.lowercased() ?? ""
        if updated.llmModelOverride == modelValue && currentProviderValue == newProviderValue {
            return
        }
        updated.llmModelOverride = modelValue
        updated.llmProviderOverride = providerValue
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func resolvedOpenRouterRouting(for prompt: PromptConfiguration?) -> String {
        if let override = prompt?.openrouterRoutingOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return openrouterRouting
    }

    func updateOpenRouterRoutingOverride(for id: UUID, to routing: String?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        updated.openrouterRoutingOverride = routing
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func resolvedOpenRouterReasoning(for prompt: PromptConfiguration?) -> OpenRouterReasoningMode {
        prompt?.openrouterReasoningOverride ?? openrouterReasoning
    }

    func updateOpenRouterReasoningOverride(for id: UUID, to reasoning: OpenRouterReasoningMode?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        updated.openrouterReasoningOverride = reasoning
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func updateVoiceOverride(for id: UUID, model overrideModel: String?, language overrideLanguage: String?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        let normalizedModel = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = overrideLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelValue = (normalizedModel?.isEmpty ?? true) ? nil : normalizedModel
        let languageValue = (normalizedLanguage?.isEmpty ?? true) ? nil : normalizedLanguage
        var updated = prompts[idx]
        if updated.voiceModelOverride == modelValue && updated.voiceLanguageOverride == languageValue {
            return
        }
        updated.voiceModelOverride = modelValue
        updated.voiceLanguageOverride = languageValue
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func addFavoriteLLMModel(provider: String, model: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        let normalizedProvider = (trimmedProvider.isEmpty ? llmProvider : trimmedProvider).lowercased()
        let candidate = FavoriteLLMModel(provider: normalizedProvider, model: trimmedModel)
        if favoriteLLMModels.contains(where: { $0.key == candidate.key }) {
            return
        }
        favoriteLLMModels.append(candidate)
    }

    func removeFavoriteLLMModel(id: UUID) {
        favoriteLLMModels.removeAll { $0.id == id }
    }

    func updateScreenContextOverride(for id: UUID, to override: Bool?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        if updated.screenContextOverride == override {
            return
        }
        updated.screenContextOverride = override
        if override == false {
            updated.screenContextCaptureOverride = nil
        }
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func updateClipboardContextOverride(for id: UUID, to override: Bool?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        if updated.clipboardContextOverride == override {
            return
        }
        updated.clipboardContextOverride = override
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func updateScreenContextCaptureOverride(for id: UUID, to override: ScreenContextCaptureMode?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        if updated.screenContextCaptureOverride == override {
            return
        }
        updated.screenContextCaptureOverride = override
        prompts[idx] = updated
        if updated.id == selectedPromptID {
            updateProviders()
        }
    }

    func selectPrompt(id: UUID) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        selectedPromptID = id
    }

    func getSelectedTextPrompt() -> PromptConfiguration? {
        return prompts.first(where: { $0.triggerOnSelectedText })
    }

    func updateTriggerOnSelectedText(for id: UUID, to enabled: Bool) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }

        var newPrompts = prompts

        if enabled {
            // First, clear the flag from all other prompts to maintain exclusivity
            for i in newPrompts.indices {
                newPrompts[i].triggerOnSelectedText = false
            }
        }

        // Set the flag for the target prompt
        newPrompts[idx].triggerOnSelectedText = enabled

        prompts = newPrompts
    }

    private func shouldUseSelectedTextPrompt() async -> Bool {
        let screenContext = ScreenContextService()
        let selectedText = screenContext.selectedText()
        let hasSelectedText = !(selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        // Only override if we have both selected text and a designated prompt for it
        return hasSelectedText && getSelectedTextPrompt() != nil
    }

    private func checkAndApplySelectedTextPrompt() async {
        // Import ScreenContextService to check for selected text
        let screenContext = ScreenContextService()

        // Check if there's text currently selected
        let selectedText = screenContext.selectedText()
        let hasSelectedText = !(selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if hasSelectedText {
            // Check if there's a prompt designated for selected text
            if let selectedTextPrompt = getSelectedTextPrompt() {
                // Temporarily switch to this prompt for this dictation session
                selectedTextPromptOverride = selectedTextPrompt
                isApplyingPromptFromSelection = true
                systemPrompt = selectedTextPrompt.systemPrompt
                userPrompt = selectedTextPrompt.userPrompt
                isApplyingPromptFromSelection = false
                updateProviders()
            }
        } else {
            // Clear any override if no text is selected
            selectedTextPromptOverride = nil
        }
    }

    private func restoreOriginalPromptIfNeeded() async {
        if selectedTextPromptOverride != nil {
            selectedTextPromptOverride = nil

            // Restore the originally selected prompt
            await MainActor.run {
                if let originalPrompt = self.prompts.prompt(withID: self.selectedPromptID) ?? self.prompts.first {
                    self.isApplyingPromptFromSelection = true
                    self.systemPrompt = originalPrompt.systemPrompt
                    self.userPrompt = originalPrompt.userPrompt
                    self.isApplyingPromptFromSelection = false
                }
            }
            updateProviders()
        }
    }

    private func applySelectedTextPromptOverride(_ prompt: PromptConfiguration) {
        selectedTextPromptOverride = prompt
        isApplyingPromptFromSelection = true
        systemPrompt = prompt.systemPrompt
        userPrompt = prompt.userPrompt
        isApplyingPromptFromSelection = false
    }

    private func clearSelectedTextFallbackTask(id: UUID) {
        if selectedTextFallbackTaskID == id {
            selectedTextFallbackTaskID = nil
        }
    }

    private func checkAndStoreSelectedTextPromptFast() async {
        let screenContext = ScreenContextService()

        // Fast AX-only check (no 600ms pasteboard fallback)
        let selectedText = screenContext.selectedTextFast()
        let hasSelectedText = !(selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if hasSelectedText, let selectedTextPrompt = getSelectedTextPrompt() {
            // Store override WITHOUT calling updateProviders() to avoid restart
            applySelectedTextPromptOverride(selectedTextPrompt)
            selectedTextFallbackTaskID = nil
        } else {
            selectedTextPromptOverride = nil

            // Kick off slower fallback without delaying recording start
            let taskID = UUID()
            selectedTextFallbackTaskID = taskID

            Task.detached(priority: .utility) { [weak self] in
                let screenContext = ScreenContextService()
                let fallbackText = screenContext.selectedText()
                let trimmed = fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !trimmed.isEmpty else {
                    await MainActor.run { self?.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                guard let self else {
                    await MainActor.run { self?.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                // Ensure this result is still relevant for the latest request
                guard await self.selectedTextFallbackTaskID == taskID else {
                    await MainActor.run { self.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                // Don't override if we already have a selected text prompt override from fast detection
                guard await self.selectedTextPromptOverride == nil else {
                    await MainActor.run { self.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                guard let selectedTextPrompt = await self.getSelectedTextPrompt() else {
                    await MainActor.run { self.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                guard await self.isRecording else {
                    await MainActor.run { self.clearSelectedTextFallbackTask(id: taskID) }
                    return
                }

                await self.applySelectedTextPromptOverride(selectedTextPrompt)
                await MainActor.run { self.clearSelectedTextFallbackTask(id: taskID) }
            }
        }
    }

    private func persistAndUpdate() {
        UserDefaults.standard.set(transcriptionModel, forKey: "transcription.model")
        UserDefaults.standard.set(llmEnabled, forKey: "llm.enabled")
        UserDefaults.standard.set(screenContextEnabled, forKey: "screenContext.enabled")
        UserDefaults.standard.set(screenContextCaptureMode.rawValue, forKey: "screenContext.captureMode")
        UserDefaults.standard.set(clipboardContextEnabled, forKey: "clipboardContext.enabled")

        UserDefaults.standard.set(llmModel, forKey: "llm.model")
        UserDefaults.standard.set(openrouterRouting, forKey: "llm.openrouter.routing")
        UserDefaults.standard.set(openrouterReasoning.rawValue, forKey: "llm.openrouter.reasoning")
        UserDefaults.standard.set(vocabCustom, forKey: "vocab.custom")
        UserDefaults.standard.set(vocabSpelling, forKey: "vocab.spelling")
        updateProviders()
    }

    private func persistFavoriteLLMModels() {
        var normalized: [FavoriteLLMModel] = []
        var seen: Set<String> = []
        for item in favoriteLLMModels {
            let trimmedModel = item.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedProvider = item.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty else { continue }
            let normalizedProvider = trimmedProvider.isEmpty ? llmProvider : trimmedProvider
            let normalizedEntry = FavoriteLLMModel(id: item.id, provider: normalizedProvider.lowercased(), model: trimmedModel)
            let key = normalizedEntry.key
            if seen.insert(key).inserted {
                normalized.append(normalizedEntry)
            }
        }
        if normalized != favoriteLLMModels {
            favoriteLLMModels = normalized
            return
        }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: Self.favoritesDataKey)
        }
        defaults.removeObject(forKey: Self.favoritesLegacyKey)
    }

    private func persistPromptLibrary() {
        if isApplyingPromptFromSelection { return }
        persistSimplePromptSelection()
    }

    // MARK: - Simple Mode Helpers

    private func simpleSettings(for kind: SimplePromptKind) -> SimplePromptSettings {
        switch kind {
        case .dictation: return simpleDictationSettings
        case .command: return simpleCommandSettings
        }
    }

    private func withSimpleSidebarSyncSuppressed(_ action: () -> Void) {
        let previous = suppressSimpleSidebarSync
        suppressSimpleSidebarSync = true
        action()
        suppressSimpleSidebarSync = previous
    }

    private func sanitizedSimpleSettings(_ settings: SimplePromptSettings, for kind: SimplePromptKind) -> SimplePromptSettings {
        var sanitized = settings.sanitized()
        if sanitized.rules.isEmpty {
            sanitized.rules = SimpleModeDefaults.defaultRules(for: kind)
        }
        if sanitized.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.header = SimpleModeDefaults.systemHeader(for: kind)
        }
        if sanitized.footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.footer = SimpleModeDefaults.systemFooter(for: kind)
        }
        return sanitized
    }

    private func applySimpleSettings(_ settings: SimplePromptSettings, for kind: SimplePromptKind) {
        let sanitized = sanitizedSimpleSettings(settings, for: kind)
        switch kind {
        case .dictation:
            guard simpleDictationSettings != sanitized else { return }
            simpleDictationSettings = sanitized
        case .command:
            guard simpleCommandSettings != sanitized else { return }
            simpleCommandSettings = sanitized
        }
    }

    func setSimpleScreenContext(_ value: Bool, for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        guard settings.enableScreenContext != value else { return }
        settings.enableScreenContext = value
        applySimpleSettings(settings, for: kind)
    }

    func setSimpleClipboard(_ value: Bool, for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        guard settings.enableClipboardContext != value else { return }
        settings.enableClipboardContext = value
        applySimpleSettings(settings, for: kind)
    }

    func setSimpleSelectedText(_ value: Bool, for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        guard settings.enableSelectedText != value else { return }
        settings.enableSelectedText = value
        applySimpleSettings(settings, for: kind)
    }

    func setSimpleActiveTextField(_ value: Bool, for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        guard settings.enableActiveTextField != value else { return }
        settings.enableActiveTextField = value
        applySimpleSettings(settings, for: kind)
    }

    func setSimpleSelection(_ selection: HotkeyManager.Selection?, for kind: SimplePromptKind) {
        if let selection, selection == hermesSelection {
            settingsNotice = "That shortcut is already assigned to Hermes."
            return
        }
        var settings = simpleSettings(for: kind)
        guard settings.selection != selection else { return }
        settings.selection = selection
        applySimpleSettings(settings, for: kind)
    }

    func setSimpleIncludeImage(_ include: Bool, for kind: SimplePromptKind) {
        guard kind == .command else { return }
        var settings = simpleSettings(for: kind)
        guard settings.includeScreenImage != include else { return }
        settings.includeScreenImage = include
        applySimpleSettings(settings, for: kind)
    }

    func updateSimpleHeader(kind: SimplePromptKind, text: String) {
        var settings = simpleSettings(for: kind)
        guard settings.header != text else { return }
        settings.header = text
        applySimpleSettings(settings, for: kind)
    }

    func updateSimpleFooter(kind: SimplePromptKind, text: String) {
        var settings = simpleSettings(for: kind)
        guard settings.footer != text else { return }
        settings.footer = text
        applySimpleSettings(settings, for: kind)
    }

    func restoreSimpleHeader(for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        settings.header = SimpleModeDefaults.systemHeader(for: kind)
        applySimpleSettings(settings, for: kind)
    }

    func restoreSimpleFooter(for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        settings.footer = SimpleModeDefaults.systemFooter(for: kind)
        applySimpleSettings(settings, for: kind)
    }

    func updateSimpleRules(kind: SimplePromptKind, text: String) {
        var settings = simpleSettings(for: kind)
        if settings.rules == text { return }
        settings.rules = text
        applySimpleSettings(settings, for: kind)
    }

    func restoreSimpleRules(for kind: SimplePromptKind) {
        var settings = simpleSettings(for: kind)
        settings.rules = SimpleModeDefaults.defaultRules(for: kind)
        applySimpleSettings(settings, for: kind)
    }

    func applyDictationPromptTemplate(id: UUID) {
        guard let template = dictationPromptTemplates.first(where: { $0.id == id }) else { return }
        selectedDictationPromptTemplateID = id
        var settings = simpleSettings(for: .dictation)
        settings.rules = template.rules
        settings.footer = template.footer
        applySimpleSettings(settings, for: .dictation)
    }

    func saveCurrentDictationPromptTemplate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let template = SimplePromptTemplate(
            name: trimmed,
            rules: simpleDictationSettings.rules,
            footer: simpleDictationSettings.footer
        )
        customDictationPromptTemplates.append(template)
        selectedDictationPromptTemplateID = template.id
    }

    func updateDictationPromptTemplate(id: UUID, name: String, rules: String, footer: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = customDictationPromptTemplates.firstIndex(where: { $0.id == id }) else { return }
        customDictationPromptTemplates[index].name = trimmed
        customDictationPromptTemplates[index].rules = rules
        customDictationPromptTemplates[index].footer = footer

        if selectedDictationPromptTemplateID == id {
            applyDictationPromptTemplate(id: id)
        }
    }

    func deleteDictationPromptTemplate(id: UUID) {
        guard customDictationPromptTemplates.contains(where: { $0.id == id }) else { return }
        customDictationPromptTemplates.removeAll { $0.id == id }
        if selectedDictationPromptTemplateID == id {
            selectedDictationPromptTemplateID = nil
        }
    }

    func addCustomSimpleModel(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if simpleCustomModels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return }
        simpleCustomModels.append(trimmed)
        simpleSelectedModel = trimmed
    }

    func removeCustomSimpleModel(id: String) {
        simpleCustomModels.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
        if simpleSelectedModel.caseInsensitiveCompare(id) == .orderedSame {
            simpleSelectedModel = SimpleModeDefaults.defaultModelID
        }
    }
    
    func addFavoriteOpenRouterModel(id: String, name: String) {
        guard !favoriteOpenRouterModels.contains(where: { $0.id.lowercased() == id.lowercased() }) else { return }
        let favorite = FavoriteOpenRouterModel(id: id, name: name)
        favoriteOpenRouterModels.append(favorite)
    }
    
    func removeFavoriteOpenRouterModel(id: String) {
        favoriteOpenRouterModels.removeAll { $0.id.lowercased() == id.lowercased() }
        if simpleSelectedModel.lowercased() == id.lowercased(), let first = favoriteOpenRouterModels.first {
            simpleSelectedModel = first.id
        } else if favoriteOpenRouterModels.isEmpty {
            simpleSelectedModel = SimpleModeDefaults.defaultModelID
        }
    }
    
    func setActiveOpenRouterModel(id: String) {
        simpleSelectedModel = id
    }
    
    private func persistFavoriteOpenRouterModels() {
        if let data = try? JSONEncoder().encode(favoriteOpenRouterModels) {
            UserDefaults.standard.set(data, forKey: Self.favoriteOpenRouterModelsKey)
        }
    }

    private func persistSimpleSettings(kind: SimplePromptKind, settings: SimplePromptSettings) {
        let sanitized = sanitizedSimpleSettings(settings, for: kind)
        let key = (kind == .dictation) ? SimpleDefaultsKey.dictationSettings : SimpleDefaultsKey.commandSettings
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistSimpleCustomModels() {
        var seen: Set<String> = []
        let cleaned = simpleCustomModels.compactMap { entry -> String? in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return trimmed
        }
        if cleaned != simpleCustomModels {
            simpleCustomModels = cleaned
            return
        }
        UserDefaults.standard.set(cleaned, forKey: SimpleDefaultsKey.customModels)
        applySimplePrompts()
    }

    private func persistCustomDictationPromptTemplates() {
        if let data = try? JSONEncoder().encode(customDictationPromptTemplates) {
            UserDefaults.standard.set(data, forKey: SimpleDefaultsKey.dictationPromptTemplates)
        }
    }

    private func simpleVoiceEngineDidChange(oldValue: SimpleVoiceEngine) {
        if simpleVoiceEngine == oldValue { return }
        UserDefaults.standard.set(simpleVoiceEngine.rawValue, forKey: SimpleDefaultsKey.voiceEngine)
        transcriptionModel = Self.voiceModel(
            for: simpleVoiceEngine,
            openRouterModel: openRouterTranscriptionModel
        )
        applySimplePrompts()
    }

    private func simpleModelDidChange(oldValue: String) {
        let trimmed = simpleSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? SimpleModeDefaults.defaultModelID : trimmed
        if final != simpleSelectedModel {
            simpleSelectedModel = final
            return
        }
        if final == oldValue { return }
        UserDefaults.standard.set(final, forKey: SimpleDefaultsKey.selectedModel)
        llmModel = final
        suppressSimpleSidebarSync = true
        applySimplePrompts()
        suppressSimpleSidebarSync = false
    }

    private func simpleLLMEnabledDidChange(oldValue: Bool) {
        if simpleLLMEnabled == oldValue { return }
        UserDefaults.standard.set(simpleLLMEnabled, forKey: SimpleDefaultsKey.llmEnabled)
        llmEnabled = simpleLLMEnabled
        updateProviders()
    }

    private func simpleSidebarSelectionDidChange(oldValue: SimpleSidebarItem) {
        if simpleSidebarSelection == oldValue { return }
        if !isUpdatingSimpleSidebar {
            persistSimpleSidebarSelection()
        }
        guard let kind = promptKind(forSidebar: simpleSidebarSelection) else { return }
        let targetID = kind.promptID
        guard selectedPromptID != targetID else { return }
        isApplyingPromptFromSelection = true
        selectedPromptID = targetID
        if let prompt = prompts.first(where: { $0.id == targetID }) {
            systemPrompt = prompt.systemPrompt
            userPrompt = prompt.userPrompt
        }
        isApplyingPromptFromSelection = false
    }

    private func persistSimpleSidebarSelection() {
        UserDefaults.standard.set(simpleSidebarSelection.rawValue, forKey: SimpleDefaultsKey.sidebar)
    }

    private func simpleSettingsDidChange(kind: SimplePromptKind, oldValue: SimplePromptSettings) {
        let current = simpleSettings(for: kind)
        if current == oldValue { return }
        persistSimpleSettings(kind: kind, settings: current)
        screenContextEnabled = simpleShouldEnableScreenContext()
        clipboardContextEnabled = simpleShouldEnableClipboard()
        if screenContextCaptureMode != .text {
            screenContextCaptureMode = .text
        }
        applySimplePrompts()
    }

    private func persistSimplePromptSelection() {
        if shouldSyncSidebar(),
           !suppressSimpleSidebarSync,
           let sidebar = sidebarItem(forPromptID: selectedPromptID),
           simpleSidebarSelection != sidebar {
            isUpdatingSimpleSidebar = true
            simpleSidebarSelection = sidebar
            isUpdatingSimpleSidebar = false
        }
        persistSimpleSidebarSelection()
    }

    private func shouldSyncSidebar() -> Bool {
        return simpleSidebarSelection == .dictation || simpleSidebarSelection == .command
    }
    
    private func sidebarItem(forPromptID id: UUID?) -> SimpleSidebarItem? {
        guard let id else { return nil }
        if id == SimplePromptKind.dictation.promptID { return .dictation }
        if id == SimplePromptKind.command.promptID { return .command }
        return nil
    }

    private func promptKind(forSidebar item: SimpleSidebarItem) -> SimplePromptKind? {
        switch item {
        case .dictation: return .dictation
        case .command: return .command
        case .vocabulary, .history, .hermes, .microphone, .permissions, .settings: return nil
        }
    }

    /// Determines which prompt should be activated based on the hotkey that was pressed.
    /// Always defaults to dictation unless the command hotkey was explicitly pressed.
    private func determinePromptIDForCurrentHotkey() -> UUID {
        // Get the current hotkey selection
        let currentHotkeySelection = hotkeys.selection
        
        // Check if the command mode's hotkey matches the current hotkey
        if let commandHotkey = simpleCommandSettings.selection,
           commandHotkey == currentHotkeySelection {
            return SimplePromptKind.command.promptID
        }
        
        // Default to dictation for all other cases
        return SimplePromptKind.dictation.promptID
    }

    private func buildSimplePromptConfigurations() -> [PromptConfiguration] {
        let dictation = sanitizedSimpleSettings(simpleDictationSettings, for: .dictation)
        let command = sanitizedSimpleSettings(simpleCommandSettings, for: .command)
        let voiceModel = Self.voiceModel(
            for: simpleVoiceEngine,
            openRouterModel: openRouterTranscriptionModel
        )
        return [
            SimplePromptComposer.configuration(for: .dictation, settings: dictation, llmModel: simpleSelectedModel, provider: "openrouter", voiceModel: voiceModel),
            SimplePromptComposer.configuration(for: .command, settings: command, llmModel: simpleSelectedModel, provider: "openrouter", voiceModel: voiceModel)
        ]
    }

    private func simpleShouldEnableScreenContext() -> Bool {
        simpleDictationSettings.enableScreenContext || simpleCommandSettings.enableScreenContext
    }

    private func simpleShouldEnableClipboard() -> Bool {
        simpleDictationSettings.enableClipboardContext || simpleCommandSettings.enableClipboardContext
    }

    private func applySimplePrompts(preferredKind: SimplePromptKind? = nil) {
        if isApplyingSimplePrompts { return }
        let configs = buildSimplePromptConfigurations()
        guard !configs.isEmpty else { return }
        isApplyingSimplePrompts = true
        let currentKind = preferredKind ?? promptKind(forSidebar: simpleSidebarSelection) ?? .dictation
        let targetID = configs.contains(where: { $0.id == currentKind.promptID }) ? currentKind.promptID : configs[0].id
        isApplyingPromptFromSelection = true
        prompts = configs
        selectedPromptID = targetID
        if let active = configs.first(where: { $0.id == targetID }) ?? configs.first {
            systemPrompt = active.systemPrompt
            userPrompt = active.userPrompt
        }
        isApplyingPromptFromSelection = false
        if let sidebar = sidebarItem(forPromptID: targetID), shouldSyncSidebar(), !isUpdatingSimpleSidebar, !suppressSimpleSidebarSync, simpleSidebarSelection != sidebar {
            isUpdatingSimpleSidebar = true
            simpleSidebarSelection = sidebar
            isUpdatingSimpleSidebar = false
        }
        isApplyingSimplePrompts = false
        refreshPromptHotkeys()
        updateProvidersImmediately()
    }

    private func configureSimpleModeState(preferredKind: SimplePromptKind? = nil) {
        simpleDictationSettings = sanitizedSimpleSettings(simpleDictationSettings, for: .dictation)
        simpleCommandSettings = sanitizedSimpleSettings(simpleCommandSettings, for: .command)
        llmEnabled = simpleLLMEnabled
        llmModel = simpleSelectedModel
        transcriptionModel = Self.voiceModel(
            for: simpleVoiceEngine,
            openRouterModel: openRouterTranscriptionModel
        )
        screenContextEnabled = simpleShouldEnableScreenContext()
        clipboardContextEnabled = simpleShouldEnableClipboard()
        screenContextCaptureMode = .text
        applySimplePrompts(preferredKind: preferredKind)
    }

    private func applySelection() {
        guard !isApplyingPromptFromSelection else { return }
        guard let prompt = prompts.prompt(withID: selectedPromptID) ?? prompts.first else { return }
        isApplyingPromptFromSelection = true
        systemPrompt = prompt.systemPrompt
        userPrompt = prompt.userPrompt
        isApplyingPromptFromSelection = false
        if !isUpdatingSimpleSidebar,
           !suppressSimpleSidebarSync,
           shouldSyncSidebar(),
           let sidebar = sidebarItem(forPromptID: prompt.id),
           simpleSidebarSelection != sidebar {
            isUpdatingSimpleSidebar = true
            simpleSidebarSelection = sidebar
            isUpdatingSimpleSidebar = false
        }
        persistPromptLibrary()
        updateProviders()
    }

    private func updateActivePrompt(systemText: String? = nil, userText: String? = nil) {
        guard !isApplyingPromptFromSelection else { return }
        guard let id = selectedPromptID, let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[index]
        if let systemText { updated.systemPrompt = systemText }
        if let userText { updated.userPrompt = userText }
        if updated != prompts[index] {
            prompts[index] = updated
            updateProviders()
        }
    }

    private func refreshPromptHotkeys() {
        promptHotkeyManager.unregisterAll()
        for prompt in prompts {
            if let selection = prompt.selection {
                promptHotkeyManager.register(selection: selection, for: prompt.id)
            } else if let shortcut = prompt.shortcut {
                promptHotkeyManager.register(shortcut: shortcut, for: prompt.id)
            }
        }
        if hermesAgentEnabled, let hermesSelection {
            promptHotkeyManager.register(selection: hermesSelection, for: HermesAgentHotkey.promptID)
        }
    }

    private var promptPressTimes: [UUID: Date] = [:]
    private let promptPressThreshold: TimeInterval = 0.8

    func startHermesReply() {
        startHermesReply(to: focusedHermesResponseSessionID ?? selectedHermesSessionID)
    }

    func startHermesReply(to sessionID: UUID?) {
        Task {
            let state = await controller.currentState()
            if case .recording = state {
                guard let recordingSessionID = activeHermesRecordingSessionID else { return }
                if sessionID == nil || sessionID == recordingSessionID {
                    await finishHermesRecording(
                        promptID: activeHermesPromptID ?? SimplePromptKind.command.promptID,
                        sessionID: recordingSessionID
                    )
                }
                return
            }

            guard isIdleOrError(state) else { return }
            let targetSessionID = ensureHermesSessionID(sessionID)
            await beginHermesRecording(
                promptID: SimplePromptKind.command.promptID,
                sessionID: targetSessionID
            )
        }
    }

    func startNewHermesSessionRecording() {
        Task {
            let state = await controller.currentState()
            guard isIdleOrError(state) else { return }
            let sessionID = createHermesSession().id
            await beginHermesRecording(
                promptID: SimplePromptKind.command.promptID,
                sessionID: sessionID
            )
        }
    }

    func sendHermesTextReply(_ text: String,
                             to sessionID: UUID?,
                             dismissResponseWindow: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hermesAgentEnabled else {
            settingsNotice = "Enable Hermes agent before sending a text reply."
            return
        }
        let targetSessionID = ensureHermesSessionID(sessionID)
        guard let targetSession = hermesSessions.first(where: { $0.id == targetSessionID }),
              canUseHermesTextReply(for: targetSession) else {
            settingsNotice = "Hermes session is not ready for a text reply."
            return
        }
        if dismissResponseWindow {
            removeHermesResponseWindow(for: targetSessionID)
        }
        Task {
            await submitHermesTextTurn(trimmed, sessionID: targetSessionID)
        }
    }

    var selectedHermesSession: HermesChatSession? {
        guard let selectedHermesSessionID else { return nil }
        return hermesSessions.first(where: { $0.id == selectedHermesSessionID })
    }

    var activeHermesSessions: [HermesChatSession] {
        HermesSessionLifecycle.activeSessions(hermesSessions)
    }

    var archivedHermesSessions: [HermesChatSession] {
        HermesSessionLifecycle.archivedSessions(hermesSessions)
    }

    func selectHermesSession(_ sessionID: UUID?) {
        selectedHermesSessionID = sessionID
    }

    func activateHermesSession(_ sessionID: UUID) {
        focusedHermesResponseSessionID = sessionID
        selectedHermesSessionID = sessionID
    }

    func dismissHermesResponse() {
        hermesResponseWindowState = nil
        hermesResponseWindowStates.removeAll()
        focusedHermesResponseSessionID = nil
    }

    func dismissHermesResponse(sessionID: UUID) {
        removeHermesResponseWindow(for: sessionID)
    }

    func closeHermesSession(_ sessionID: UUID) {
        archiveHermesSession(sessionID)
    }

    func archiveHermesSession(_ sessionID: UUID) {
        releaseHermesRequest(for: sessionID)
        updateHermesSession(sessionID) { session in
            session = HermesSessionLifecycle.archive(session)
        }
        removeHermesResponseWindow(for: sessionID)
        if selectedHermesSessionID == sessionID {
            selectedHermesSessionID = activeHermesSessions.first?.id
        }
        settingsNotice = "Hermes session archived."
    }

    func restoreHermesSession(_ sessionID: UUID) {
        updateHermesSession(sessionID) { session in
            session = HermesSessionLifecycle.restore(session)
        }
        selectedHermesSessionID = sessionID
        settingsNotice = "Hermes session restored."
    }

    func deleteHermesSession(_ sessionID: UUID) {
        releaseHermesRequest(for: sessionID)
        removeHermesResponseWindow(for: sessionID)
        hermesSessions.removeAll { $0.id == sessionID }
        hermesSessions = hermesSessionStore.save(hermesSessions)
        if selectedHermesSessionID == sessionID {
            selectedHermesSessionID = activeHermesSessions.first?.id ?? archivedHermesSessions.first?.id
        } else {
            updateHermesChatProjection()
        }
        settingsNotice = "Hermes session deleted locally."
    }

    func showHermesResponseWindow(for sessionID: UUID) {
        guard let session = hermesSessions.first(where: { $0.id == sessionID }),
              let message = session.latestAssistantMessage else {
            return
        }
        upsertHermesResponseWindow(
            sessionID: sessionID,
            title: session.title,
            text: message.text,
            isError: message.role == .error
        )
    }

    func clearHermesChat() {
        archiveActiveHermesSessions()
    }

    func archiveActiveHermesSessions() {
        let activeIDs = Set(activeHermesSessions.map(\.id))
        guard !activeIDs.isEmpty else { return }
        for sessionID in activeIDs {
            releaseHermesRequest(for: sessionID)
            removeHermesResponseWindow(for: sessionID)
        }
        hermesSessions = hermesSessions.map { session in
            activeIDs.contains(session.id) ? HermesSessionLifecycle.archive(session) : session
        }
        hermesSessions = hermesSessionStore.save(hermesSessions)
        if let selectedHermesSessionID, activeIDs.contains(selectedHermesSessionID) {
            self.selectedHermesSessionID = activeHermesSessions.first?.id
        } else {
            updateHermesChatProjection()
        }
        settingsNotice = "Active Hermes sessions archived."
    }

    func canReplyToHermesSession(_ session: HermesChatSession) -> Bool {
        !session.isArchived && !hermesInFlightSessionIDs.contains(session.id)
    }

    func isHermesRecordingReply(to sessionID: UUID) -> Bool {
        activeHermesRecordingSessionID == sessionID
    }

    func canUseHermesReplyButton(for session: HermesChatSession) -> Bool {
        guard !session.isArchived, !hermesInFlightSessionIDs.contains(session.id) else {
            return false
        }
        if let activeHermesRecordingSessionID {
            return activeHermesRecordingSessionID == session.id
        }
        return true
    }

    func canUseHermesTextReply(for session: HermesChatSession) -> Bool {
        hermesAgentEnabled
            && !session.isArchived
            && !hermesInFlightSessionIDs.contains(session.id)
            && activeHermesRecordingSessionID == nil
    }

    func canInterruptHermesSession(_ session: HermesChatSession) -> Bool {
        !session.isArchived && (session.status == .waiting || hermesInFlightSessionIDs.contains(session.id))
    }

    func isHermesSessionActivelyWaiting(_ session: HermesChatSession) -> Bool {
        !session.isArchived && session.status == .waiting && hermesInFlightSessionIDs.contains(session.id)
    }

    func interruptHermesSession(_ sessionID: UUID) {
        releaseHermesRequest(for: sessionID)
        updateHermesSession(sessionID) { session in
            session = HermesSessionRecovery.interrupt(session)
        }
        settingsNotice = "Hermes session interrupted. You can reply to continue it."
    }

    func saveHermesApiKey(_ value: String) {
        let kc = KeychainService()
        do {
            try kc.setSecret(value, forKey: AppConfig.hermesAPIKeyAlias)
            hermesConnectionStatus = "Hermes API key saved."
            hermesConnectionSucceeded = nil
            settingsNotice = "Hermes API key saved."
        } catch {
            let message = "Could not save Hermes API key: \(error.localizedDescription)"
            hermesConnectionStatus = message
            hermesConnectionSucceeded = false
            settingsNotice = message
        }
    }

    func testHermesConnection() async {
        hermesConnectionStatus = "Testing Hermes connection..."
        hermesConnectionSucceeded = nil
        do {
            try await hermesClient.checkHealth(settings: currentHermesSettings())
            hermesConnectionStatus = "Hermes API server reachable and bearer key accepted."
            hermesConnectionSucceeded = true
            settingsNotice = hermesConnectionStatus
        } catch {
            hermesConnectionStatus = "Hermes connection failed: \(error.localizedDescription)"
            hermesConnectionSucceeded = false
            settingsNotice = hermesConnectionStatus
        }
    }

    func setHermesSelection(_ selection: HotkeyManager.Selection?) {
        if let selection,
           selection == simpleDictationSettings.selection || selection == simpleCommandSettings.selection {
            hermesConnectionStatus = "That shortcut is already assigned to Dictation or Command."
            hermesConnectionSucceeded = false
            return
        }
        guard hermesSelection != selection else { return }
        hermesSelection = selection
    }

    private func isIdleOrError(_ state: DictationController.State) -> Bool {
        if state == .idle { return true }
        if case .error = state { return true }
        return false
    }

    private func currentHermesSettings(conversationName: String? = nil) -> HermesAgentSettings {
        HermesAgentSettings(
            baseURLString: hermesBaseURLString,
            model: hermesModel,
            profileName: hermesProfileName,
            conversationName: conversationName ?? hermesConversationName,
            timeout: HermesAgentSettings.clampedTimeout(hermesTimeoutSeconds)
        )
    }

    private func handleHermesPromptHotkey(id: UUID,
                                          phase: PromptHotkeyManager.TriggerPhase,
                                          currentState: DictationController.State) async {
        switch phase {
        case .down:
            promptPressTimes[id] = Date()
            switch currentState {
            case .idle, .error:
                let sessionID = hermesSessionIDForHotkey()
                await beginHermesRecording(promptID: id, sessionID: sessionID)
            case .recording:
                if let sessionID = activeHermesRecordingSessionID {
                    await finishHermesRecording(
                        promptID: activeHermesPromptID ?? id,
                        sessionID: sessionID
                    )
                }
            default:
                break
            }
        case .up:
            guard let start = promptPressTimes.removeValue(forKey: id) else { return }
            let duration = Date().timeIntervalSince(start)
            guard duration >= promptPressThreshold else { return }
            let state = await controller.currentState()
            if case .recording = state, let sessionID = activeHermesRecordingSessionID {
                await finishHermesRecording(
                    promptID: activeHermesPromptID ?? id,
                    sessionID: sessionID
                )
            }
        }
    }

    private func beginHermesRecording(promptID: UUID, sessionID: UUID) async {
        guard let session = hermesSessions.first(where: { $0.id == sessionID }) else { return }
        guard canReplyToHermesSession(session) else {
            settingsNotice = "Hermes session is \(session.status.rawValue)."
            return
        }
        prepareHermesContextCapture()

        await MainActor.run {
            self.hermesResponseWindowStates = HermesResponseWindowLifecycle.replyRecordingStarted(
                self.hermesResponseWindowStates,
                sessionID: sessionID
            )
            self.hermesResponseWindowState = self.hermesResponseWindowStates.first {
                $0.id == sessionID
            } ?? self.hermesResponseWindowState
            self.isRecording = true
            self.recordingStartTimestamp = Date()
            self.recordingStartInProgress = true
            self.recordingStopInProgress = false
            self.activeHermesPromptID = promptID
            self.activeHermesRecordingSessionID = sessionID
            self.focusedHermesResponseSessionID = sessionID
            self.selectedHermesSessionID = sessionID
        }

        await MainActor.run {
            if self.selectedPromptID != promptID {
                self.suppressSimpleSidebarSync = true
                self.selectedPromptID = promptID
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await MainActor.run {
            self.suppressSimpleSidebarSync = false
            self.updateProvidersImmediately()
        }
        await waitForLatestProviderUpdate()
        await controller.updateLLMEnabled(true)
        await controller.updateScreenContextEnabled(hermesScreenContextEnabled)
        await controller.updateClipboardContextEnabled(false)
        await checkAndStoreSelectedTextPromptFast()

        let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == promptID }) }
        await controller.toggle(userPrompt: "", activePrompt: activePrompt)
        let state = await controller.currentState()
        await MainActor.run {
            self.recordingStartInProgress = false
            if case .error = state {
                self.clearActiveHermesRecording(cancelContext: true)
                self.isRecording = false
            }
        }
    }

    private func finishHermesRecording(promptID: UUID, sessionID: UUID) async {
        await MainActor.run {
            self.hermesResponseWindowStates = HermesResponseWindowLifecycle.replyRecordingFinished(
                self.hermesResponseWindowStates,
                sessionID: sessionID
            )
            self.hermesResponseWindowState = self.hermesResponseWindowStates.first
            self.recordingStopInProgress = true
            self.isRecording = false
            self.recordingStartTimestamp = nil
            self.recordingStartInProgress = false
        }

        let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == promptID }) }
        do {
            guard let result = try await controller.finishTranscriptionOnly(activePrompt: activePrompt) else {
                await MainActor.run {
                    self.activeHermesPromptID = nil
                    self.activeHermesRecordingSessionID = nil
                    self.clearHermesContextCapture(cancel: true)
                }
                return
            }
            await MainActor.run {
                self.activeHermesPromptID = nil
                self.activeHermesRecordingSessionID = nil
            }
            await restoreOriginalPromptIfNeeded()
            await submitHermesTurn(result, sessionID: sessionID)
        } catch {
            await MainActor.run {
                self.activeHermesPromptID = nil
                self.activeHermesRecordingSessionID = nil
                self.clearHermesContextCapture(cancel: true)
                self.appendHermesChatMessage(
                    sessionID: sessionID,
                    role: .error,
                    text: error.localizedDescription,
                    status: .error
                )
                self.upsertHermesResponseWindow(
                    sessionID: sessionID,
                    title: "Hermes Error",
                    text: error.localizedDescription,
                    isError: true
                )
            }
            await restoreOriginalPromptIfNeeded()
        }
    }

    private func submitHermesTurn(_ turn: DictationController.TranscriptionOnlyResult,
                                  sessionID: UUID) async {
        let rawTranscript = turn.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .error,
                text: HermesAgentClientError.emptyInput.localizedDescription,
                status: .error
            )
            upsertHermesResponseWindow(
                sessionID: sessionID,
                title: "Hermes",
                text: HermesAgentClientError.emptyInput.localizedDescription,
                isError: true
            )
            clearHermesContextCapture(cancel: true)
            return
        }

        guard let session = hermesSessions.first(where: { $0.id == sessionID }) else {
            clearHermesContextCapture(cancel: true)
            return
        }

        let settings = currentHermesSettings(conversationName: session.conversationName)
        let requestID = UUID()
        hermesActiveRequestIDs[sessionID] = requestID
        markHermesRequestStarted(for: sessionID)
        defer {
            if hermesActiveRequestIDs[sessionID] == requestID {
                releaseHermesRequest(for: sessionID)
            }
        }

        do {
            let screenshot = await consumeHermesScreenshot()
            let clipboardText = await consumeHermesClipboardContext()
            let normalizedClipboardText = HermesAgentAPIClient.normalizedClipboardText(clipboardText)
            let imageAttachment = screenshot.map(HermesAgentImageAttachment.init(snapshot:))
            let screenContext = hermesScreenContextEnabled ? turn.screenContext : nil
            let screenContextMethod = hermesScreenContextEnabled ? turn.screenContextMethod : nil
            let transcript = await postProcessHermesTranscriptIfNeeded(
                rawTranscript,
                turn: turn,
                screenContext: screenContext,
                clipboardText: clipboardText
            )
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .user,
                text: transcript,
                contextLabels: hermesContextLabels(
                    screenContext: screenContext,
                    screenshot: screenshot,
                    clipboardText: clipboardText
                ),
                clipboardText: normalizedClipboardText,
                status: .waiting
            )
            let userMessageForHistory = HermesAgentAPIClient.enrichedInputText(
                input: transcript,
                imageAttachment: imageAttachment,
                clipboardText: clipboardText
            )
            let start = Date()
            let response = try await hermesClient.send(
                input: transcript,
                settings: settings,
                imageAttachment: imageAttachment,
                clipboardText: clipboardText
            )
            guard hermesActiveRequestIDs[sessionID] == requestID else { return }
            let hermesSeconds = Date().timeIntervalSince(start)

            await history.append(
                fileURL: turn.fileURL,
                appName: turn.appName,
                bundleID: turn.bundleID,
                transcript: transcript,
                output: "",
                screenContext: screenContext,
                screenContextMethod: screenContextMethod,
                screenImage: screenshot,
                selectedText: turn.selectedText,
                activeTextField: turn.activeTextField,
                llmSystemMessage: nil,
                llmUserMessage: userMessageForHistory,
                transcriptionModel: turn.transcriptionModel,
                llmModel: "Hermes \(response.model)",
                transcriptionSeconds: turn.transcriptionSeconds,
                llmSeconds: hermesSeconds,
                totalSeconds: turn.totalSeconds + hermesSeconds
            )

            updateHermesSession(sessionID) { session in
                session.serverSessionID = response.sessionID ?? session.serverSessionID
                session.status = .responded
                session.updatedAt = Date()
            }
            upsertHermesResponseWindow(
                sessionID: sessionID,
                title: HermesSessionNaming.displayTitle(
                    for: hermesSessions,
                    sessionID: sessionID
                ),
                text: response.text,
                isError: false
            )
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .assistant,
                text: response.text,
                status: .responded
            )
        } catch {
            guard hermesActiveRequestIDs[sessionID] == requestID else { return }
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .error,
                text: error.localizedDescription,
                status: .error
            )
            upsertHermesResponseWindow(
                sessionID: sessionID,
                title: "Hermes Error",
                text: error.localizedDescription,
                isError: true
            )
            clearHermesContextCapture(cancel: true)
        }
    }

    private func submitHermesTextTurn(_ text: String, sessionID: UUID) async {
        let rawText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return }

        guard let session = hermesSessions.first(where: { $0.id == sessionID }) else {
            return
        }
        guard canReplyToHermesSession(session) else {
            settingsNotice = "Hermes session is \(session.status.rawValue)."
            return
        }

        let settings = currentHermesSettings(conversationName: session.conversationName)
        let requestID = UUID()
        hermesActiveRequestIDs[sessionID] = requestID
        markHermesRequestStarted(for: sessionID)
        appendHermesChatMessage(
            sessionID: sessionID,
            role: .user,
            text: rawText,
            contextLabels: [],
            status: .waiting
        )
        defer {
            if hermesActiveRequestIDs[sessionID] == requestID {
                releaseHermesRequest(for: sessionID)
            }
        }

        do {
            let start = Date()
            let response = try await hermesClient.send(
                input: rawText,
                settings: settings,
                imageAttachment: nil,
                clipboardText: nil
            )
            guard hermesActiveRequestIDs[sessionID] == requestID else { return }
            let hermesSeconds = Date().timeIntervalSince(start)

            await history.append(
                fileURL: nil,
                appName: "HermesWhisper",
                bundleID: Bundle.main.bundleIdentifier,
                transcript: rawText,
                output: "",
                screenContext: nil,
                screenContextMethod: nil,
                screenImage: nil,
                selectedText: nil,
                activeTextField: nil,
                llmSystemMessage: nil,
                llmUserMessage: rawText,
                transcriptionModel: "Typed",
                llmModel: "Hermes \(response.model)",
                transcriptionSeconds: nil,
                llmSeconds: hermesSeconds,
                totalSeconds: hermesSeconds
            )

            updateHermesSession(sessionID) { session in
                session.serverSessionID = response.sessionID ?? session.serverSessionID
                session.status = .responded
                session.updatedAt = Date()
            }
            upsertHermesResponseWindow(
                sessionID: sessionID,
                title: HermesSessionNaming.displayTitle(
                    for: hermesSessions,
                    sessionID: sessionID
                ),
                text: response.text,
                isError: false
            )
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .assistant,
                text: response.text,
                status: .responded
            )
        } catch {
            guard hermesActiveRequestIDs[sessionID] == requestID else { return }
            appendHermesChatMessage(
                sessionID: sessionID,
                role: .error,
                text: error.localizedDescription,
                status: .error
            )
            upsertHermesResponseWindow(
                sessionID: sessionID,
                title: "Hermes Error",
                text: error.localizedDescription,
                isError: true
            )
        }
    }

    private func postProcessHermesTranscriptIfNeeded(
        _ rawTranscript: String,
        turn: DictationController.TranscriptionOnlyResult,
        screenContext: String?,
        clipboardText: String?
    ) async -> String {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hermesPostProcessingEnabled, simpleLLMEnabled else {
            return trimmed
        }

        let prompt = prompts.first(where: { $0.id == SimplePromptKind.dictation.promptID })
        let system = PromptBuilder.renderSystemPrompt(
            template: prompt?.systemPrompt
                ?? SimplePromptComposer.systemPrompt(
                    for: .dictation,
                    settings: simpleDictationSettings
                ),
            customVocabulary: vocabCustom
        )
        let userMessage = PromptBuilder.buildUserMessage(
            transcription: trimmed,
            selectedText: turn.selectedText,
            activeTextField: turn.activeTextField,
            appName: turn.appName,
            screenContents: nil,
            screenContextTerms: screenContext,
            customVocabulary: vocabCustom,
            clipboardText: clipboardText
        )

        do {
            let model = Self.canonicalLLMModel(for: resolvedLLMModel(for: prompt))
            let provider = OpenRouterLLMProvider(
                client: OpenRouterHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
                })
            )
            let settings = LLMSettings(
                endpoint: AppConfig.openrouterChatCompletions,
                model: model,
                systemPrompt: system,
                timeout: max(30, min(120, transcriptionTimeoutSeconds)),
                streaming: false,
                temperature: llmTemperature,
                openRouterReasoning: openrouterReasoning
            )
            var cleaned = try await provider.process(
                text: userMessage,
                userPrompt: prompt?.userPrompt ?? "",
                settings: settings
            )
            let rules = vocabSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rules.isEmpty {
                cleaned = TextReplacement.apply(to: cleaned, withRules: rules)
            }
            let final = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return final.isEmpty ? trimmed : final
        } catch {
            AppLog.dictation.error("Hermes post-processing failed: \(error.localizedDescription)")
            settingsNotice = "Hermes post-processing failed; sent raw transcript."
            return trimmed
        }
    }

    private func generateHermesTitle(for sessionID: UUID, sourceText: String) {
        guard simpleLLMEnabled else { return }

        let requestID = UUID()
        hermesTitleRequestIDs[sessionID] = requestID
        Task { [weak self] in
            guard let self else { return }
            let title = await self.generateHermesTitleText(from: sourceText)
            await MainActor.run {
                guard self.hermesTitleRequestIDs[sessionID] == requestID else { return }
                self.hermesTitleRequestIDs[sessionID] = nil
                guard let title else { return }
                self.updateHermesSession(sessionID) { session in
                    guard session.title == HermesSessionNaming.defaultTitle else { return }
                    session.title = title
                }
            }
        }
    }

    private func generateHermesTitleText(from sourceText: String) async -> String? {
        do {
            let provider = OpenRouterLLMProvider(
                client: OpenRouterHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
                })
            )
            let settings = LLMSettings(
                endpoint: AppConfig.openrouterChatCompletions,
                model: Self.canonicalLLMModel(for: simpleSelectedModel),
                systemPrompt: "You create concise titles for task conversations.",
                timeout: 30,
                streaming: false,
                temperature: 0.1,
                openRouterReasoning: openrouterReasoning
            )
            let output = try await provider.process(
                text: HermesSessionNaming.promptForGeneratedTitle(sessionText: sourceText),
                userPrompt: "",
                settings: settings
            )
            return HermesSessionNaming.normalizedGeneratedTitle(output)
        } catch {
            AppLog.dictation.error("Hermes title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func releaseHermesRequest(for sessionID: UUID) {
        hermesActiveRequestIDs[sessionID] = nil
        hermesInFlightSessionIDs.remove(sessionID)
        syncHermesRequestStatus()
    }

    private func markHermesRequestStarted(for sessionID: UUID) {
        hermesInFlightSessionIDs.insert(sessionID)
        syncHermesRequestStatus()
    }

    private func syncHermesRequestStatus() {
        hermesIsSending = !hermesInFlightSessionIDs.isEmpty
        hermesPendingResponseCount = hermesInFlightSessionIDs.count
    }

    private func appendHermesChatMessage(sessionID: UUID,
                                         role: HermesChatMessage.Role,
                                         text: String,
                                         contextLabels: [String] = [],
                                         clipboardText: String? = nil,
                                         status: HermesChatSession.Status? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = HermesChatMessage(
            role: role,
            text: trimmed,
            contextLabels: contextLabels,
            clipboardText: clipboardText
        )
        var shouldGenerateTitle = false
        updateHermesSession(sessionID) { session in
            if session.messages.isEmpty,
               role == .user,
               session.title == HermesSessionNaming.defaultTitle {
                shouldGenerateTitle = true
            }
            session.messages.append(message)
            session.status = status ?? session.status
            session.updatedAt = message.createdAt
        }
        if shouldGenerateTitle {
            generateHermesTitle(for: sessionID, sourceText: trimmed)
        }
    }

    private func hermesSessionIDForHotkey() -> UUID {
        let target = HermesSessionRouting.hotkeyTarget(
            focusedSessionID: focusedHermesResponseSessionID,
            visibleResponseSessionIDs: hermesResponseWindowStates.map(\.id)
        )

        switch target {
        case .newSession:
            return createHermesSession().id
        case .reply(let sessionID):
            return ensureHermesSessionID(sessionID)
        }
    }

    @discardableResult
    private func ensureHermesSessionID(_ sessionID: UUID?) -> UUID {
        if let sessionID, hermesSessions.contains(where: { $0.id == sessionID }) {
            selectedHermesSessionID = sessionID
            return sessionID
        }
        return createHermesSession().id
    }

    @discardableResult
    private func createHermesSession() -> HermesChatSession {
        let id = UUID()
        let settings = currentHermesSettings()
        let session = HermesChatSession(
            id: id,
            title: HermesSessionNaming.defaultTitle,
            conversationName: HermesSessionNaming.conversationName(
                base: settings.normalizedConversationName,
                id: id
            )
        )
        hermesSessions.insert(session, at: 0)
        saveHermesSessions()
        selectedHermesSessionID = id
        return session
    }

    private func updateHermesSession(_ sessionID: UUID,
                                     mutate: (inout HermesChatSession) -> Void) {
        guard let index = hermesSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        mutate(&hermesSessions[index])
        saveHermesSessions()
        syncHermesResponseWindowTitle(for: sessionID)
    }

    private func saveHermesSessions() {
        hermesSessions = hermesSessionStore.save(hermesSessions)
        if let selectedHermesSessionID,
           !hermesSessions.contains(where: { $0.id == selectedHermesSessionID }) {
            self.selectedHermesSessionID = hermesSessions.first?.id
        } else if selectedHermesSessionID == nil {
            selectedHermesSessionID = hermesSessions.first?.id
        } else {
            updateHermesChatProjection()
        }
    }

    private func updateHermesChatProjection() {
        hermesChatMessages = selectedHermesSession?.messages ?? []
    }

    private func upsertHermesResponseWindow(sessionID: UUID,
                                            title: String,
                                            text: String,
                                            isError: Bool) {
        let state = HermesResponseWindowState(
            id: sessionID,
            title: title,
            text: text,
            isError: isError
        )
        if let index = hermesResponseWindowStates.firstIndex(where: { $0.id == sessionID }) {
            hermesResponseWindowStates[index] = state
        } else {
            hermesResponseWindowStates.append(state)
        }
        hermesResponseWindowState = state
        focusedHermesResponseSessionID = sessionID
        selectedHermesSessionID = sessionID
    }

    private func syncHermesResponseWindowTitle(for sessionID: UUID) {
        guard let session = hermesSessions.first(where: { $0.id == sessionID }),
              let index = hermesResponseWindowStates.firstIndex(where: { $0.id == sessionID }),
              hermesResponseWindowStates[index].title != session.title else {
            return
        }
        hermesResponseWindowStates[index].title = session.title
        if hermesResponseWindowState?.id == sessionID {
            hermesResponseWindowState = hermesResponseWindowStates[index]
        }
    }

    private func removeHermesResponseWindow(for sessionID: UUID) {
        hermesResponseWindowStates.removeAll { $0.id == sessionID }
        if hermesResponseWindowState?.id == sessionID {
            hermesResponseWindowState = hermesResponseWindowStates.last
        }
        if focusedHermesResponseSessionID == sessionID {
            focusedHermesResponseSessionID = hermesResponseWindowStates.last?.id
        }
    }

    private func hermesContextLabels(screenContext: String?,
                                     screenshot: ScreenCaptureSnapshot?,
                                     clipboardText: String?) -> [String] {
        var labels: [String] = []
        if let screenContext,
           !screenContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append("Screen text")
        }
        if screenshot != nil {
            labels.append("Screenshot")
        }
        if HermesAgentAPIClient.normalizedClipboardText(clipboardText) != nil {
            labels.append("Clipboard")
        }
        return labels
    }

    private func prepareHermesContextCapture() {
        clearHermesContextCapture(cancel: true)
        let recordingStartedAt = Date()
        if hermesScreenshotEnabled {
            hermesScreenshotTask = Task.detached(priority: .userInitiated) {
                await DictationViewModel.captureHermesContextScreenshot()
            }
        }
        if hermesClipboardContextEnabled {
            let clipboardMonitor = hermesClipboardMonitor
            let pasteboardChangeCount = Self.currentPasteboardChangeCount()
            let retentionWindow = HermesClipboardContextPolicy.clampedRetentionWindow(
                hermesClipboardTimeoutSeconds
            )
            hermesClipboardTask = Task.detached(priority: .userInitiated) {
                await DictationViewModel.captureHermesClipboardContext(
                    recordingStartedAt: recordingStartedAt,
                    pasteboardChangeCount: pasteboardChangeCount,
                    retentionWindow: retentionWindow,
                    clipboardMonitor: clipboardMonitor
                )
            }
        }
    }

    private func consumeHermesScreenshot() async -> ScreenCaptureSnapshot? {
        let task = hermesScreenshotTask
        hermesScreenshotTask = nil
        return await task?.value
    }

    private func consumeHermesClipboardContext() async -> String? {
        let task = hermesClipboardTask
        hermesClipboardTask = nil
        return await task?.value
    }

    private func clearHermesContextCapture(cancel: Bool) {
        clearHermesScreenshotCapture(cancel: cancel)
        clearHermesClipboardCapture(cancel: cancel)
    }

    private func clearActiveHermesRecording(cancelContext: Bool) {
        activeHermesPromptID = nil
        guard let sessionID = activeHermesRecordingSessionID else {
            if cancelContext {
                clearHermesContextCapture(cancel: true)
            }
            return
        }

        activeHermesRecordingSessionID = nil
        hermesResponseWindowStates = HermesResponseWindowLifecycle.replyRecordingCancelled(
            hermesResponseWindowStates,
            sessionID: sessionID
        )
        if hermesResponseWindowState?.id == sessionID {
            hermesResponseWindowState = HermesResponseWindowLifecycle.replyRecordingCancelled(
                hermesResponseWindowState
            )
        }
        if cancelContext {
            clearHermesContextCapture(cancel: true)
        }
    }

    private func clearHermesScreenshotCapture(cancel: Bool) {
        if cancel {
            hermesScreenshotTask?.cancel()
        }
        hermesScreenshotTask = nil
    }

    private func clearHermesClipboardCapture(cancel: Bool) {
        if cancel {
            hermesClipboardTask?.cancel()
        }
        hermesClipboardTask = nil
    }

    private nonisolated static func captureHermesContextScreenshot() async -> ScreenCaptureSnapshot? {
        let service = ScreenCaptureService()
        let snapshot = await service.captureActiveWindowImage(maxDimension: 1920, lossless: false)
        if let snapshot {
            AppLog.screen.info(
                "Hermes context screenshot captured method=\(snapshot.method.rawValue, privacy: .public) width=\(snapshot.width) height=\(snapshot.height)"
            )
        } else {
            AppLog.screen.warning("Hermes context screenshot unavailable; sending text-only turn")
        }
        return snapshot
    }

    private nonisolated static func captureHermesClipboardContext(
        recordingStartedAt: Date,
        pasteboardChangeCount: Int,
        retentionWindow: TimeInterval,
        clipboardMonitor: ClipboardContextMonitor
    ) async -> String? {
        await clipboardMonitor.refreshSnapshot(
            capturedAt: recordingStartedAt,
            matchingChangeCount: pasteboardChangeCount
        )
        let snapshot = await clipboardMonitor.peekClipboardSnapshotIfRecent(
            referenceDate: recordingStartedAt,
            window: retentionWindow
        )
        let normalized = HermesClipboardContextPolicy.contextText(
            snapshot?.text,
            copiedAt: snapshot?.copiedAt ?? recordingStartedAt,
            recordingStartedAt: recordingStartedAt,
            retentionWindow: retentionWindow
        )
        if normalized != nil {
            AppLog.dictation.log("Hermes clipboard context captured")
        } else {
            AppLog.dictation.log("Hermes clipboard context skipped because copied text was stale or unavailable")
        }
        return normalized
    }

    private static func currentPasteboardChangeCount() -> Int {
        do {
            let result = try ObjCExceptionHandler.catchException {
                NSPasteboard.general.changeCount as NSNumber
            }
            return (result as? NSNumber)?.intValue ?? -1
        } catch {
            AppLog.dictation.warning("Hermes clipboard change count unavailable")
            return -1
        }
    }

    private func handlePromptHotkey(id: UUID, phase: PromptHotkeyManager.TriggerPhase) async {
        let state = await controller.currentState()
        if id == HermesAgentHotkey.promptID {
            guard hermesAgentEnabled else { return }
            await handleHermesPromptHotkey(
                id: SimplePromptKind.command.promptID,
                phase: phase,
                currentState: state
            )
            return
        }
        if activeHermesPromptID != nil {
            return
        }

        switch phase {
        case .down:
            promptPressTimes[id] = Date()

            switch state {
            case .idle, .error:
                // Update UI IMMEDIATELY for instant feedback
                await MainActor.run { 
                    self.isRecording = true
                    self.recordingStartTimestamp = Date()
                    self.recordingStartInProgress = true
                    self.recordingStopInProgress = false
                }

                // Select the prompt for this hotkey FIRST, without changing the visible UI tab
                await MainActor.run {
                    if self.selectedPromptID != id {
                        // Suppress sidebar sync to prevent UI navigation when using hotkeys
                        self.suppressSimpleSidebarSync = true
                        self.selectedPromptID = id
                    }
                }
                
                // Wait briefly for applySelection() to complete, then restore sync
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                await MainActor.run {
                    self.suppressSimpleSidebarSync = false
                }

                // Now update providers for the correct prompt immediately
                await MainActor.run { self.updateProvidersImmediately() }
                await waitForLatestProviderUpdate()

                // Fast check for selected text (AX only, ~5ms)
                await checkAndStoreSelectedTextPromptFast()

                let promptText = await MainActor.run { self.userPrompt }
                let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == id }) }
                await controller.toggle(userPrompt: promptText, activePrompt: activePrompt)
                await MainActor.run { self.recordingStartInProgress = false }

            case .recording:
                await MainActor.run { 
                    self.recordingStopInProgress = true
                    self.isRecording = false
                    self.recordingStartTimestamp = nil
                    self.recordingStartInProgress = false
                }

                // If we have a selected text prompt override, ensure providers are updated before LLM processing
                if selectedTextPromptOverride != nil {
                    await MainActor.run {
                        // Temporarily apply the selected text prompt to ensure providers use it
                        if let override = self.selectedTextPromptOverride {
                            self.isApplyingPromptFromSelection = true
                            self.systemPrompt = override.systemPrompt
                            self.userPrompt = override.userPrompt
                            self.isApplyingPromptFromSelection = false
                        }
                    }
                    await updateProvidersWithSelectedTextOverride()
                }

                let promptText = await MainActor.run { self.userPrompt }
                await controller.finish(userPrompt: promptText)
                await restoreOriginalPromptIfNeeded()

            default:
                break
            }

        case .up:
            guard let start = promptPressTimes.removeValue(forKey: id) else { return }
            let duration = Date().timeIntervalSince(start)
            if duration >= promptPressThreshold {
                let state = await controller.currentState()
                if case .recording = state {
                    await MainActor.run { 
                        self.recordingStopInProgress = true
                        self.isRecording = false
                        self.recordingStartTimestamp = nil
                        self.recordingStartInProgress = false
                    }

                    // If we have a selected text prompt override, ensure providers are updated before LLM processing
                    if selectedTextPromptOverride != nil {
                        await MainActor.run {
                            // Temporarily apply the selected text prompt to ensure providers use it
                            if let override = self.selectedTextPromptOverride {
                                self.isApplyingPromptFromSelection = true
                                self.systemPrompt = override.systemPrompt
                                self.userPrompt = override.userPrompt
                                self.isApplyingPromptFromSelection = false
                            }
                        }
                        await updateProvidersWithSelectedTextOverride()
                    }

                    let promptText = await MainActor.run { self.userPrompt }
                    let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == id }) }
                    await controller.finish(userPrompt: promptText, activePrompt: activePrompt)
                    await restoreOriginalPromptIfNeeded()
                }
            }
        }
    }

    private func updateProviders() {
        // Cancel any existing timer and task
        providerUpdateTimer?.invalidate()
        providerUpdateTimer = nil
        providerUpdateTask?.cancel()

        // Debounce provider updates to avoid excessive reinitialization
        providerUpdateTimer = Timer.scheduledTimer(withTimeInterval: providerUpdateDebounceInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            let prompt = self.prompts.prompt(withID: self.selectedPromptID) ?? self.prompts.first
            let task = self.applyProviders(using: prompt)
            self.providerUpdateTask = task
        }
    }

    // Immediately apply provider updates without debouncing (for critical operations)
    private func updateProvidersImmediately() {
        // Cancel any existing timer and task
        providerUpdateTimer?.invalidate()
        providerUpdateTimer = nil
        providerUpdateTask?.cancel()

        let prompt = prompts.prompt(withID: selectedPromptID) ?? prompts.first
        let task = applyProviders(using: prompt)
        providerUpdateTask = task
    }

    @discardableResult
    private func applyProviders(using prompt: PromptConfiguration?) -> Task<Void, Never> {
        // Update settings using the configured system prompt, rendered with current vocabulary/spelling placeholders
        let voiceModel = resolvedVoiceModel(for: prompt)
        let voiceLanguage = resolvedVoiceLanguage(for: prompt)
        let voiceVocabularyTerms = VoiceVocabularyKeyterms.terms(
            customVocabulary: vocabCustom,
            spellingCorrections: vocabSpelling
        )
        var tSettings = TranscriptionSettings(
            endpoint: AppConfig.groqAudioTranscriptions,
            model: voiceModel,
            timeout: max(5, min(120, transcriptionTimeoutSeconds)),
            language: voiceLanguage,
            vocabularyTerms: voiceVocabularyTerms
        )
        let modelForActivePrompt = resolvedLLMModel(for: prompt)
        let providerForActivePrompt = resolvedLLMProvider(for: prompt)
        let canonicalModelForActivePrompt = Self.canonicalLLMModel(for: modelForActivePrompt)

        // Get cached transcription provider
        let provider = getCachedTranscriptionProvider(for: voiceModel)

        if voiceModel.lowercased().contains("parakeet") {
            tSettings = TranscriptionSettings(
                endpoint: URL(string: "https://localhost")!,
                model: voiceModel,
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        } else if voiceModel == "groq-streaming" {
            let actualModel = AppConfig.defaultTranscriptionModel
            tSettings = TranscriptionSettings(
                endpoint: AppConfig.groqAudioTranscriptions,
                model: actualModel,
                timeout: max(5, min(120, transcriptionTimeoutSeconds)),
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        } else if Self.isOpenRouterTranscriptionModel(voiceModel) {
            tSettings = TranscriptionSettings(
                endpoint: AppConfig.openrouterAudioTranscriptions,
                model: voiceModel,
                timeout: max(5, min(120, transcriptionTimeoutSeconds)),
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        } else if voiceModel == AppConfig.defaultXAIStreamingTranscriptionModel {
            tSettings = TranscriptionSettings(
                endpoint: AppConfig.xaiSpeechToTextStreaming,
                model: voiceModel,
                timeout: max(5, min(120, transcriptionTimeoutSeconds)),
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        } else if voiceModel == AppConfig.defaultXAITranscriptionModel {
            tSettings = TranscriptionSettings(
                endpoint: AppConfig.xaiSpeechToText,
                model: voiceModel,
                timeout: max(5, min(120, transcriptionTimeoutSeconds)),
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        } else {
            tSettings = TranscriptionSettings(
                endpoint: AppConfig.groqAudioTranscriptions,
                model: voiceModel,
                timeout: max(5, min(120, transcriptionTimeoutSeconds)),
                language: voiceLanguage,
                vocabularyTerms: voiceVocabularyTerms
            )
        }

        let renderedSystem = PromptBuilder.renderSystemPrompt(template: systemPrompt, customVocabulary: vocabCustom)
        // Align LLM timeout with the user-configured timeout setting
        let llmTimeout = max(5, min(120, transcriptionTimeoutSeconds))
        var lSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: canonicalModelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming, temperature: llmTemperature)

        let routingForActivePrompt = resolvedOpenRouterRouting(for: prompt)
        let reasoningForActivePrompt = resolvedOpenRouterReasoning(for: prompt)
        let llmProviderToApply = getCachedLLMProvider(for: providerForActivePrompt, model: modelForActivePrompt, routing: routingForActivePrompt)
        lSettings = LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: canonicalModelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming, temperature: llmTemperature, openRouterReasoning: reasoningForActivePrompt)
        GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)

        let transcriberSettings = tSettings
        let llmSettingsToApply = lSettings
        let isLLMEnabled = llmEnabled
        let useScreenContext = resolvedScreenContext(for: prompt)
        let useClipboardContext = resolvedClipboardContext(for: prompt)
        let useSelectedText = resolvedSelectedText(for: prompt)
        let useActiveTextField = resolvedActiveTextField(for: prompt)
        let captureMode = resolvedScreenContextCaptureMode(for: prompt)
        let includeScreenImage = resolvedScreenImage(for: prompt)

        return Task {
            if let providerToApply = provider {
                await controller.updateTranscriberProvider(providerToApply)
            }
            await controller.updateTranscriberSettings(transcriberSettings)
            if let llmProvider = llmProviderToApply {
                await controller.updateLLMProvider(llmProvider)
            }
            await controller.updateLLMSettings(llmSettingsToApply)
            await controller.updateLLMEnabled(isLLMEnabled)
            await controller.updateScreenContextEnabled(useScreenContext)
            await controller.updateScreenContextCaptureMode(captureMode)
            await controller.updateClipboardContextEnabled(useClipboardContext)
            await controller.updateSelectedTextEnabled(useSelectedText)
            await controller.updateActiveTextFieldEnabled(useActiveTextField)
            await controller.updateScreenImageEnabled(includeScreenImage)
            await controller.updateAutoMuteEnabled(autoMuteEnabled)
        }
    }

    // Reprocess a saved history entry with current settings
    func reprocessHistoryEntry(_ entry: HistoryEntry) async {
        await waitForLatestProviderUpdate()
        await controller.reprocess(entry: entry, userPrompt: userPrompt)
    }

    // Paste the last transcription output (LLM if present; else raw transcript)
    func pasteLastTranscription() {
        guard let first = history.entries.first else { return }
        let text = first.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first.transcript : first.output
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        Task { await controller.insert(text) }
    }

    private func updateProvidersWithSelectedTextOverride() async {
        // Cancel any existing timer and task
        providerUpdateTimer?.invalidate()
        providerUpdateTimer = nil
        providerUpdateTask?.cancel()

        // Use the selected text prompt override for provider updates
        let task = applyProviders(using: selectedTextPromptOverride)
        providerUpdateTask = task
    }

    // MARK: - Provider Cache Management

    private func getCachedTranscriptionProvider(for model: String) -> TranscriptionProvider? {
        if let cached = transcriptionProviderCache[model] {
            return cached
        }

        let provider: TranscriptionProvider
        if model.lowercased().contains("parakeet") {
            provider = ParakeetTranscriptionProvider()
        } else if model == "groq-streaming" {
            // Keep the existing engine identifier for settings compatibility, but use
            // Groq's stable file upload path. Soniox is the real-time streaming engine.
            provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        } else if model == "soniox-streaming" {
            let sonioxProvider = SonioxStreamingProvider(
                apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias) },
                vocabularyProvider: { [weak self] in self?.vocabCustom },
                languageProvider: { [weak self] in self?.transcriptionLanguage }
            )
            // Wire up preview callback for live transcript overlay
            Task {
                await sonioxProvider.setOnPreviewUpdate { [weak self] text in
                    Task { @MainActor in
                        self?.sonioxPreviewText = text
                    }
                }
            }
            provider = sonioxProvider
        } else if Self.isOpenRouterTranscriptionModel(model) {
            provider = OpenRouterTranscriptionProvider(
                client: OpenRouterHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
                })
            )
        } else if model == AppConfig.defaultXAIStreamingTranscriptionModel {
            let xaiStreamingProvider = XAIStreamingTranscriptionProvider(
                apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias) }
            )
            Task {
                await xaiStreamingProvider.setOnPreviewUpdate { [weak self] text in
                    Task { @MainActor in
                        self?.sonioxPreviewText = text
                    }
                }
            }
            provider = xaiStreamingProvider
        } else if model == AppConfig.defaultXAITranscriptionModel {
            provider = XAITranscriptionProvider(
                client: XAIHTTPClient(apiKeyProvider: {
                    KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias)
                })
            )
        } else {
            provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        }

        transcriptionProviderCache[model] = provider
        return provider
    }

    private func getCachedLLMProvider(for provider: String, model: String, routing: String? = nil) -> LLMProvider? {
        let cacheKey = "\(model)::\(routing ?? "default")"

        if let cached = llmProviderCache[cacheKey] {
            return cached
        }

        GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)
        let routingPref = routing ?? openrouterRouting
        let providerInstance = OpenRouterLLMProvider(
            client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }),
            routingPrefProvider: { routingPref }
        )

        llmProviderCache[cacheKey] = providerInstance
        return providerInstance
    }

}

private struct PromptBootstrap {
    let prompts: [PromptConfiguration]
    let selectedID: UUID
    let activeSystem: String
    let activeUser: String
}

private enum SimpleDefaultsKey {
    static let dictationSettings = "simple.dictation.settings"
    static let commandSettings = "simple.command.settings"
    static let dictationPromptTemplates = "simple.dictation.promptTemplates"
    static let selectedModel = "simple.model.selected"
    static let customModels = "simple.model.custom"
    static let llmEnabled = "simple.llm.enabled"
    static let voiceEngine = "simple.voice.engine"
    static let openRouterTranscriptionModel = "transcription.openrouter.model"
    static let sidebar = "simple.sidebar.selection"
    static let hermesSelection = "hermes.shortcut.selection"
    static let hermesScreenContextEnabled = "hermes.context.screenText.enabled"
    static let hermesScreenshotEnabled = "hermes.context.screenshot.enabled"
    static let hermesClipboardContextEnabled = "hermes.context.clipboard.enabled"
    static let hermesClipboardTimeoutSeconds = "hermes.context.clipboard.timeoutSeconds"
    static let hermesPostProcessingEnabled = "hermes.postProcessing.enabled"
}

private extension DictationViewModel {
    static func loadSimpleSettings(for kind: SimplePromptKind) -> SimplePromptSettings {
        let key: String = (kind == .dictation) ? SimpleDefaultsKey.dictationSettings : SimpleDefaultsKey.commandSettings
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SimplePromptSettings.self, from: data) {
            var sanitized = decoded.sanitized()
            if sanitized.rules.isEmpty {
                sanitized.rules = SimpleModeDefaults.defaultRules(for: kind)
            }
            if sanitized.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sanitized.header = SimpleModeDefaults.systemHeader(for: kind)
            }
            if sanitized.footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sanitized.footer = SimpleModeDefaults.systemFooter(for: kind)
            }
            return sanitized
        }
        return SimpleModeDefaults.settings(for: kind)
    }

    static func loadSimpleSelectedModel() -> String {
        let stored = UserDefaults.standard.string(forKey: SimpleDefaultsKey.selectedModel) ?? SimpleModeDefaults.defaultModelID
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SimpleModeDefaults.defaultModelID : stored
    }

    static func loadSimpleCustomModels() -> [String] {
        UserDefaults.standard.stringArray(forKey: SimpleDefaultsKey.customModels) ?? []
    }

    static func loadCustomDictationPromptTemplates() -> [SimplePromptTemplate] {
        guard let data = UserDefaults.standard.data(forKey: SimpleDefaultsKey.dictationPromptTemplates),
              let decoded = try? JSONDecoder().decode([SimplePromptTemplate].self, from: data) else {
            return []
        }
        var seen: Set<String> = []
        return decoded.compactMap { template in
            let trimmed = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)

            var sanitized = template
            sanitized.name = trimmed
            sanitized.source = .custom
            return sanitized
        }
    }

    static func loadSimpleLLMEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: SimpleDefaultsKey.llmEnabled) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: SimpleDefaultsKey.llmEnabled)
    }

    static func loadSimpleVoiceEngine() -> SimpleVoiceEngine {
        let raw = UserDefaults.standard.string(forKey: SimpleDefaultsKey.voiceEngine) ?? SimpleVoiceEngine.parakeetLocal.rawValue
        return SimpleVoiceEngine(rawValue: raw) ?? .parakeetLocal
    }

    static func loadOpenRouterTranscriptionModel() -> String {
        let stored = UserDefaults.standard.string(forKey: SimpleDefaultsKey.openRouterTranscriptionModel)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? AppConfig.defaultOpenRouterTranscriptionModel : trimmed
    }

    static func loadOpenRouterReasoning() -> OpenRouterReasoningMode {
        let raw = UserDefaults.standard.string(forKey: "llm.openrouter.reasoning") ?? OpenRouterReasoningMode.omit.rawValue
        return OpenRouterReasoningMode(rawValue: raw) ?? .omit
    }

    static func voiceModel(for engine: SimpleVoiceEngine, openRouterModel: String) -> String {
        if engine == .openRouterTranscription {
            let trimmed = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? AppConfig.defaultOpenRouterTranscriptionModel : trimmed
        }
        return engine.transcriptionModel
    }

    static func isOpenRouterTranscriptionModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == SimpleVoiceEngine.openRouterTranscription.transcriptionModel
            || trimmed == AppConfig.defaultOpenRouterTranscriptionModel
            || trimmed.contains("/")
    }

    static func loadSimpleSidebarSelection() -> SimpleSidebarItem {
        let raw = UserDefaults.standard.string(forKey: SimpleDefaultsKey.sidebar) ?? SimpleSidebarItem.dictation.rawValue
        return SimpleSidebarItem(rawValue: raw) ?? .dictation
    }

    static func loadHermesSelection() -> HotkeyManager.Selection? {
        if let raw = UserDefaults.standard.string(forKey: SimpleDefaultsKey.hermesSelection) {
            return HotkeyManager.Selection(rawValue: raw)
        }
        let fallback: HotkeyManager.Selection = .backslash
        let dictation = loadSimpleSettings(for: .dictation).selection
        let command = loadSimpleSettings(for: .command).selection
        return fallback == dictation || fallback == command ? nil : fallback
    }

    func persistHermesSelection() {
        if let hermesSelection {
            UserDefaults.standard.set(hermesSelection.rawValue, forKey: SimpleDefaultsKey.hermesSelection)
        } else {
            UserDefaults.standard.removeObject(forKey: SimpleDefaultsKey.hermesSelection)
        }
    }
}

private extension DictationViewModel {
    static let favoritesDataKey = "llm.models.favorites.data"
    static let favoritesLegacyKey = "llm.models.favorites"
    static let favoriteOpenRouterModelsKey = "simple.openrouter.favorites"

    static func loadFavoriteLLMModels() -> [FavoriteLLMModel] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: favoritesDataKey),
           let decoded = try? JSONDecoder().decode([FavoriteLLMModel].self, from: data) {
            var seen: Set<String> = []
            var result: [FavoriteLLMModel] = []
            for item in decoded {
                let normalized = FavoriteLLMModel(id: item.id, provider: item.provider.lowercased(), model: item.model)
                if seen.insert(normalized.key).inserted {
                    result.append(normalized)
                }
            }
            return result
        }
        if let legacyArray = defaults.stringArray(forKey: favoritesLegacyKey) {
            let provider = (defaults.string(forKey: "llm.provider") ?? "groq").lowercased()
            var seen: Set<String> = []
            var result: [FavoriteLLMModel] = []
            for model in legacyArray {
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let entry = FavoriteLLMModel(provider: provider, model: trimmed)
                if seen.insert(entry.key).inserted {
                    result.append(entry)
                }
            }
            return result
        }
        return []
    }
    
    static func loadFavoriteOpenRouterModels() -> [FavoriteOpenRouterModel] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: favoriteOpenRouterModelsKey),
           let decoded = try? JSONDecoder().decode([FavoriteOpenRouterModel].self, from: data) {
            var seen: Set<String> = []
            var result: [FavoriteOpenRouterModel] = []
            for item in decoded {
                if seen.insert(item.id.lowercased()).inserted {
                    result.append(item)
                }
            }
            return result
        }
        return [
            FavoriteOpenRouterModel(id: "anthropic/claude-haiku-latest", name: "Anthropic · Claude Haiku Latest"),
            FavoriteOpenRouterModel(id: "openai/gpt-5.5", name: "OpenAI · GPT-5.5")
        ]
    }

    @MainActor
    func waitForLatestProviderUpdate() async {
        if let task = providerUpdateTask {
            await task.value
        }
    }

    static func bootstrapPromptLibrary(initialSystem: String, initialUser: String, legacyBasePrompt: String) -> PromptBootstrap {
        let defaults = UserDefaults.standard
        var loaded: [PromptConfiguration] = []
        if let data = defaults.data(forKey: "prompts.library"), let decoded = try? JSONDecoder().decode([PromptConfiguration].self, from: data) {
            loaded = decoded
        }
        if loaded.isEmpty {
            let defaultPrompt = PromptConfiguration(
                name: "Default",
                systemPrompt: initialSystem.isEmpty ? AppConfig.defaultSystemPromptTemplate : initialSystem,
                userPrompt: initialUser.isEmpty ? legacyBasePrompt : initialUser,
                shortcut: nil
            )
            loaded = [defaultPrompt]
        }
        let selectedID: UUID
        if let idString = defaults.string(forKey: "prompts.selected.id"), let id = UUID(uuidString: idString), loaded.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = loaded.first?.id ?? UUID()
        }
        let active = loaded.first(where: { $0.id == selectedID }) ?? loaded.first ?? PromptConfiguration(name: "Default", systemPrompt: initialSystem, userPrompt: initialUser)
        return PromptBootstrap(prompts: loaded, selectedID: active.id, activeSystem: active.systemPrompt, activeUser: active.userPrompt)
    }

    func resolvedLLMModel(for prompt: PromptConfiguration?) -> String {
        if let override = prompt?.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let fallback = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? AppConfig.defaultLLMModel : fallback
    }

    func resolvedLLMProvider(for prompt: PromptConfiguration?) -> String {
        return "openrouter"
    }

    private static func canonicalLLMModel(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    func resolvedClipboardContext(for prompt: PromptConfiguration?) -> Bool {
        if !clipboardContextEnabled { return false }
        if let override = prompt?.clipboardContextOverride {
            return clipboardContextEnabled && override
        }
        return clipboardContextEnabled
    }

    func resolvedScreenContext(for prompt: PromptConfiguration?) -> Bool {
        if !screenContextEnabled { return false }
        if let override = prompt?.screenContextOverride {
            return screenContextEnabled && override
        }
        return screenContextEnabled
    }

    func resolvedScreenContextCaptureMode(for prompt: PromptConfiguration?) -> ScreenContextCaptureMode {
        if let override = prompt?.screenContextCaptureOverride {
            return override
        }
        return screenContextCaptureMode
    }

    func resolvedSelectedText(for prompt: PromptConfiguration?) -> Bool {
        if let override = prompt?.selectedTextOverride {
            return override
        }
        return true
    }

    func resolvedActiveTextField(for prompt: PromptConfiguration?) -> Bool {
        if let override = prompt?.activeTextFieldOverride {
            return override
        }
        return true
    }

    func resolvedScreenImage(for prompt: PromptConfiguration?) -> Bool {
        guard resolvedScreenContext(for: prompt) else { return false }
        if let override = prompt?.includeScreenImageOverride {
            return override
        }
        return false
    }

    func resolvedVoiceModel(for prompt: PromptConfiguration?) -> String {
        if let override = prompt?.voiceModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            if override == SimpleVoiceEngine.openRouterTranscription.transcriptionModel {
                return Self.voiceModel(
                    for: .openRouterTranscription,
                    openRouterModel: openRouterTranscriptionModel
                )
            }
            return override
        }
        let fallback = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback == SimpleVoiceEngine.openRouterTranscription.transcriptionModel {
            return Self.voiceModel(
                for: .openRouterTranscription,
                openRouterModel: openRouterTranscriptionModel
            )
        }
        return fallback.isEmpty ? AppConfig.defaultTranscriptionModel : fallback
    }

    func resolvedVoiceLanguage(for prompt: PromptConfiguration?) -> String {
        if let override = prompt?.voiceLanguageOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let fallback = transcriptionLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "en" : fallback
    }
}
