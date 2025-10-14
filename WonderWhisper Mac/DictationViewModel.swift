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
    @Published var isRecording: Bool = false { didSet { updateEscapeMonitor(isRecording: isRecording) } }
    @Published var audioLevel: Float = 0

    // Prompts
    @Published var prompts: [PromptConfiguration] = [] {
        didSet {
            // Persist prompt library changes and refresh hotkeys only when the prompt list/assignments change.
            // Avoid refreshing hotkeys on mere selection changes to prevent losing key-up events mid-press.
            persistPromptLibrary()
            refreshPromptHotkeys()
        }
    }
    @Published var selectedPromptID: UUID? { didSet { applySelection() } }
    // System prompt is sent as the system role content
    @Published var systemPrompt: String = "" { didSet { updateActivePrompt(systemText: systemPrompt) } }
    // User prompt is an additional user message appended after the structured transcript context
    @Published var userPrompt: String = "" { didSet { updateActivePrompt(userText: userPrompt) } }

    // Transcription + LLM preferences
    @Published var transcriptionModel: String = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel { didSet { persistAndUpdate() } }
    // Groq Whisper options
    @Published var transcriptionLanguage: String = UserDefaults.standard.string(forKey: "transcription.language") ?? "en" {
        didSet {
            UserDefaults.standard.set(transcriptionLanguage, forKey: "transcription.language")
            updateProviders()
        }
    }

    @Published var llmEnabled: Bool = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var screenContextEnabled: Bool = UserDefaults.standard.object(forKey: "screenContext.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var clipboardContextEnabled: Bool = UserDefaults.standard.object(forKey: "clipboardContext.enabled") as? Bool ?? false { didSet { persistAndUpdate() } }
    @Published var screenContextPreprocessingMode: ScreenContextPreprocessingMode = {
        if let raw = UserDefaults.standard.string(forKey: "screenContext.preprocessMode"),
           let mode = ScreenContextPreprocessingMode(rawValue: raw) {
            return mode
        }
        if UserDefaults.standard.object(forKey: "screenContext.organize") != nil {
            let legacy = UserDefaults.standard.bool(forKey: "screenContext.organize")
            return ScreenContextPreprocessingMode.fromLegacyOrganizeFlag(legacy)
        }
        return .off
    }() { didSet { persistAndUpdate() } }

    @Published var screenOrganizePrompt: String = UserDefaults.standard.string(forKey: "screenContext.organizePrompt") ?? AppConfig.defaultScreenOrganizePrompt { didSet { persistAndUpdate() } }

    @Published var llmModel: String = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel { didSet { persistAndUpdate() } }
    // LLM provider selection: "groq" (default) or "openrouter"
    @Published var llmProvider: String = UserDefaults.standard.string(forKey: "llm.provider") ?? "groq" { didSet { persistAndUpdate() } }
    // OpenRouter routing preference: "latency" or "throughput"
    @Published var openrouterRouting: String = UserDefaults.standard.string(forKey: "llm.openrouter.routing") ?? "latency" { didSet { persistAndUpdate() } }
    @Published var llmStreaming: Bool = UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(llmStreaming, forKey: "llm.streaming")
            updateProviders()
        }
    }
    @Published var favoriteLLMModels: [FavoriteLLMModel] = DictationViewModel.loadFavoriteLLMModels() {
        didSet { persistFavoriteLLMModels() }
    }

    // API Key inputs (not persisted directly; saved via Keychain on action)
    @Published var assemblyAIKeyInput: String = ""
    @Published var deepgramKeyInput: String = ""
    @Published var sonioxKeyInput: String = ""

    // Soniox + streaming audio options
    @Published var sonioxEndpointDetection: Bool = {
        if UserDefaults.standard.object(forKey: "soniox.endpointDetection") == nil { return false }
        return UserDefaults.standard.bool(forKey: "soniox.endpointDetection")
    }() { didSet { UserDefaults.standard.set(sonioxEndpointDetection, forKey: "soniox.endpointDetection") } }
    @Published var sonioxLanguageIdentification: Bool = {
        if UserDefaults.standard.object(forKey: "soniox.languageIdentification.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "soniox.languageIdentification.enabled")
    }() { didSet { UserDefaults.standard.set(sonioxLanguageIdentification, forKey: "soniox.languageIdentification.enabled") } }
    @Published var sonioxSpeakerDiarization: Bool = {
        if UserDefaults.standard.object(forKey: "soniox.speakerDiarization.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "soniox.speakerDiarization.enabled")
    }() { didSet { UserDefaults.standard.set(sonioxSpeakerDiarization, forKey: "soniox.speakerDiarization.enabled") } }

    // Soniox context configuration for maximum accuracy
    @Published var sonioxContextKeywords: String = {
        UserDefaults.standard.string(forKey: "soniox.context.keywords") ?? ""
    }() { didSet { UserDefaults.standard.set(sonioxContextKeywords, forKey: "soniox.context.keywords") } }
    @Published var sonioxContextParagraph: String = {
        UserDefaults.standard.string(forKey: "soniox.context.paragraph") ?? ""
    }() { didSet { UserDefaults.standard.set(sonioxContextParagraph, forKey: "soniox.context.paragraph") } }
    @Published var sonioxLanguageHints: String = {
        UserDefaults.standard.string(forKey: "soniox.languageHints") ?? ""
    }() { didSet { UserDefaults.standard.set(sonioxLanguageHints, forKey: "soniox.languageHints") } }

    // Soniox debug mode for troubleshooting
    @Published var sonioxDebugMode: Bool = {
        if UserDefaults.standard.object(forKey: "soniox.debug.enabled") == nil { return false }
        return UserDefaults.standard.bool(forKey: "soniox.debug.enabled")
    }() { didSet { UserDefaults.standard.set(sonioxDebugMode, forKey: "soniox.debug.enabled") } }

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
    @Published var forceHTTP2Uploads: Bool = UserDefaults.standard.bool(forKey: "network.force_http2_uploads") { didSet { UserDefaults.standard.set(forceHTTP2Uploads, forKey: "network.force_http2_uploads") } }

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

    // Screen Context / OCR
    @Published var accurateOCRForEditors: Bool = {
        if let v = UserDefaults.standard.object(forKey: "ocr.accurateForEditors") as? Bool { return v }
        return true
    }() {
        didSet { UserDefaults.standard.set(accurateOCRForEditors, forKey: "ocr.accurateForEditors") }
    }

    // Vocabulary
    @Published var vocabCustom: String = UserDefaults.standard.string(forKey: "vocab.custom") ?? "" { didSet { persistAndUpdate() } }
    @Published var vocabSpelling: String = UserDefaults.standard.string(forKey: "vocab.spelling") ?? "" { didSet { persistAndUpdate() } }

    private let controller: DictationController
    private var timer: Timer?
    private var idleSkipCounter: Int = 0
    let history = HistoryStore()
    private let promptHotkeyManager = PromptHotkeyManager()
    private var isApplyingPromptFromSelection = false
    private var providerUpdateTask: Task<Void, Never>?
    private var selectedTextPromptOverride: PromptConfiguration?
    private var selectedTextFallbackTaskID: UUID?

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
        let persistedTranscriptionModel = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel
        let persistedLLMEnabled = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true
        let persistedScreenContextEnabled = UserDefaults.standard.object(forKey: "screenContext.enabled") as? Bool ?? true
        let persistedClipboardContextEnabled = UserDefaults.standard.object(forKey: "clipboardContext.enabled") as? Bool ?? false
        let persistedOrganizePrompt = UserDefaults.standard.string(forKey: "screenContext.organizePrompt") ?? AppConfig.defaultScreenOrganizePrompt

        let persistedPreprocessMode: ScreenContextPreprocessingMode = {
            if let raw = UserDefaults.standard.string(forKey: "screenContext.preprocessMode"),
               let mode = ScreenContextPreprocessingMode(rawValue: raw) {
                return mode
            }
            let hasLegacy = UserDefaults.standard.object(forKey: "screenContext.organize") != nil
            if hasLegacy {
                let legacy = UserDefaults.standard.bool(forKey: "screenContext.organize")
                return ScreenContextPreprocessingMode.fromLegacyOrganizeFlag(legacy)
            }
            return .off
        }()

        let persistedLLMModel = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel
        let persistedLLMProvider = UserDefaults.standard.string(forKey: "llm.provider") ?? "groq"
        let persistedVocabCustom = UserDefaults.standard.string(forKey: "vocab.custom") ?? ""
        let persistedVocabSpelling = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        let persistedUseAXInsertion = UserDefaults.standard.object(forKey: "insertion.useAX") as? Bool ?? false
        // Legacy long-form prompt that previously seeded the system message
        let legacyBasePrompt = UserDefaults.standard.string(forKey: "llm.userPrompt") ?? AppConfig.defaultDictationPrompt

        let keychain = KeychainService()
        let http = GroqHTTPClient(apiKeyProvider: { keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) })

        var transcriber: TranscriptionProvider = GroqTranscriptionProvider(client: http)
        var transcriberSettings = TranscriptionSettings(
            endpoint: AppConfig.groqAudioTranscriptions,
            model: persistedTranscriptionModel,
            timeout: max(5, min(120, UserDefaults.standard.object(forKey: "transcription.timeout") as? Double ?? 10))
        )
        if persistedTranscriptionModel.lowercased().contains("parakeet") || persistedTranscriptionModel.lowercased().contains("local") {
            transcriber = ParakeetTranscriptionProvider()
            // Dummy settings to satisfy interface (not used by local provider)
            transcriberSettings = TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: persistedTranscriptionModel)
        } else if persistedTranscriptionModel == "assemblyai-streaming" {
            let key = KeychainService().getSecret(forKey: AppConfig.assemblyAIAPIKeyAlias) ?? ""
            transcriber = AssemblyAIStreamingProvider(apiKey: key)
            // Endpoint not used by streaming provider but keep required contract
            transcriberSettings = TranscriptionSettings(endpoint: URL(string: "https://streaming.assemblyai.com")!, model: persistedTranscriptionModel, timeout: 180)
        } else if persistedTranscriptionModel == "soniox-streaming" {
            let provider = SonioxStreamingProvider(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias) })
            transcriber = provider
            let sonioxModel = UserDefaults.standard.string(forKey: "soniox.model") ?? AppConfig.defaultSonioxModel
            let timeout = max(5, min(180, UserDefaults.standard.object(forKey: "transcription.timeout") as? Double ?? 10))
            transcriberSettings = TranscriptionSettings(endpoint: AppConfig.sonioxRealtime, model: sonioxModel, timeout: timeout)
        }

        // Choose initial LLM provider/endpoints based on persisted settings
        let storedSystem = UserDefaults.standard.string(forKey: "llm.systemPrompt") ?? AppConfig.defaultSystemPromptTemplate
        let storedUser = UserDefaults.standard.string(forKey: "llm.userMessage") ?? ""
        let promptBootstrap = DictationViewModel.bootstrapPromptLibrary(initialSystem: storedSystem, initialUser: storedUser, legacyBasePrompt: legacyBasePrompt)

        let renderedInitial = PromptBuilder.renderSystemPrompt(template: promptBootstrap.activeSystem, customVocabulary: persistedVocabCustom)

        var llm: LLMProvider
        var llmSettings: LLMSettings
        switch persistedLLMProvider.lowercased() {
        case "openrouter":
            llm = OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }))
            llmSettings = LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: persistedLLMModel, systemPrompt: renderedInitial, timeout: 60, streaming: UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false)
            GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)
        case "cerebras":
            llm = CerebrasLLMProvider(client: CerebrasHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.cerebrasAPIKeyAlias) }))
            llmSettings = LLMSettings(endpoint: AppConfig.cerebrasChatCompletions, model: persistedLLMModel, systemPrompt: renderedInitial, timeout: 60, streaming: UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false)
            GroqHTTPClient.preWarmConnection(to: AppConfig.cerebrasChatCompletions)
        default:
            // Groq as default
            let httpClient = http
            llm = GroqLLMProvider(client: httpClient)
            llmSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: persistedLLMModel, systemPrompt: renderedInitial, timeout: 60, streaming: UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false)
            GroqHTTPClient.preWarmConnection(to: AppConfig.groqChatCompletions)
        }

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
        // Apply initial LLM/screen-context flags
        screenContextPreprocessingMode = persistedPreprocessMode
        clipboardContextEnabled = persistedClipboardContextEnabled

        Task {
            await controller.updateLLMEnabled(persistedLLMEnabled)
            await controller.updateScreenContextEnabled(persistedScreenContextEnabled)
            await controller.updateClipboardContextEnabled(persistedClipboardContextEnabled)
            await controller.updateScreenContextPreprocessingMode(persistedPreprocessMode)
            await controller.updateScreenOrganizePrompt(persistedOrganizePrompt)
        }

        promptHotkeyManager.onPromptEvent = { [weak self] id, phase in
            Task { await self?.handlePromptHotkey(id: id, phase: phase) }
        }
        refreshPromptHotkeys()

        // Hotkey callbacks
        hotkeys.onActivate = { [weak self] in self?.toggle() }
        hotkeys.onPaste = { [weak self] in self?.pasteLastTranscription() }

        // Load saved hotkey selection
        updateHotkeys()
        updateProviders()
        updatePasteShortcut()

        // Poll state periodically for a simple UI reflection
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Throttle polling when idle to reduce wakeups
            let isActive = self.isRecording || self.status == "Transcribing" || self.status == "Processing" || self.status == "Inserting"
            if !isActive {
                idleSkipCounter = (idleSkipCounter + 1) % 2 // ~2.5 Hz when idle
                if idleSkipCounter != 0 { return }
            } else {
                idleSkipCounter = 0
            }
            Task { [weak self] in
                guard let self = self else { return }
                let s = await self.controllerState()
                await MainActor.run {
                    if self.status != s { self.status = s }
                    let rec = (s == "Recording")
                    if self.isRecording != rec { self.isRecording = rec }
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
        persistPromptLibrary()
        Task {
            await waitForLatestProviderUpdate()

            let currentState = await controller.currentState()

            switch currentState {
            case .idle, .error:
                // Fast check for selected text (AX only, ~5ms, no pasteboard fallback)
                await checkAndStoreSelectedTextPromptFast()

                // Update UI IMMEDIATELY
                await MainActor.run { self.isRecording = true }

                let prompt = await MainActor.run { self.userPrompt }
                await controller.toggle(userPrompt: prompt)

            case .recording:
                await MainActor.run { self.isRecording = false }
                let prompt = await MainActor.run { self.userPrompt }
                await controller.toggle(userPrompt: prompt)

            default:
                break
            }
        }
    }

    func finish() {
        persistPromptLibrary()
        Task {
            // Optimistically update UI immediately for snappy visual feedback
            await MainActor.run { self.isRecording = false }

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
            } else {
                await waitForLatestProviderUpdate()
            }

            let prompt = await MainActor.run { self.userPrompt }
            await controller.finish(userPrompt: prompt)

            // Restore original prompt if we had a selected text override
            await restoreOriginalPromptIfNeeded()
        }
    }

    func cancel() {
        Task {
            // Optimistically update UI immediately for snappy visual feedback
            await MainActor.run { self.isRecording = false }
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
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
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
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.groqAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
    }

    func saveAssemblyAIKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.assemblyAIAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
        // If currently selected, refresh provider so it picks up new key
        if transcriptionModel == "assemblyai-streaming" {
            updateProviders()
        }
    }

    func saveCerebrasKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.cerebrasAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
    }

    func saveOpenRouterKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.openrouterAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
    }

    func saveDeepgramKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.deepgramAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
        if transcriptionModel == "deepgram-streaming" {
            updateProviders()
        }
    }

    func saveSonioxKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.sonioxAPIKeyAlias) } catch {
            #if DEBUG
            print("Keychain error: \(error)")
            #endif
        }
        if transcriptionModel == "soniox-streaming" {
            updateProviders()
        }
    }

    private func updateHotkeys() {
        UserDefaults.standard.set(hotkeySelection.rawValue, forKey: "hotkey.selection")
        hotkeys.selection = hotkeySelection
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
            updated.screenContextPreprocessingOverride = nil
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

    func updateScreenContextPreprocessingOverride(for id: UUID, to override: ScreenContextPreprocessingMode?) {
        guard let idx = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts[idx]
        if updated.screenContextPreprocessingOverride == override {
            return
        }
        updated.screenContextPreprocessingOverride = override
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
        UserDefaults.standard.set(clipboardContextEnabled, forKey: "clipboardContext.enabled")
        UserDefaults.standard.set(screenContextPreprocessingMode.rawValue, forKey: "screenContext.preprocessMode")
        UserDefaults.standard.set(screenContextPreprocessingMode == .llm, forKey: "screenContext.organize")

        UserDefaults.standard.set(llmModel, forKey: "llm.model")
        UserDefaults.standard.set(llmProvider, forKey: "llm.provider")
        UserDefaults.standard.set(openrouterRouting, forKey: "llm.openrouter.routing")
        UserDefaults.standard.set(vocabCustom, forKey: "vocab.custom")
        UserDefaults.standard.set(vocabSpelling, forKey: "vocab.spelling")
        UserDefaults.standard.set(screenOrganizePrompt, forKey: "screenContext.organizePrompt")
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
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(prompts) {
            defaults.set(data, forKey: "prompts.library")
        }
        if let id = selectedPromptID {
            defaults.set(id.uuidString, forKey: "prompts.selected.id")
        }
        defaults.set(systemPrompt, forKey: "llm.systemPrompt")
        defaults.set(userPrompt, forKey: "llm.userMessage")
    }

    private func applySelection() {
        guard !isApplyingPromptFromSelection else { return }
        guard let prompt = prompts.prompt(withID: selectedPromptID) ?? prompts.first else { return }
        isApplyingPromptFromSelection = true
        systemPrompt = prompt.systemPrompt
        userPrompt = prompt.userPrompt
        isApplyingPromptFromSelection = false
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
    }

    private var promptPressTimes: [UUID: Date] = [:]
    private let promptPressThreshold: TimeInterval = 0.8

    private func handlePromptHotkey(id: UUID, phase: PromptHotkeyManager.TriggerPhase) async {
        await waitForLatestProviderUpdate()

        switch phase {
        case .down:
            promptPressTimes[id] = Date()
            let state = await controller.currentState()

            switch state {
            case .idle, .error:
                // Select the prompt for this hotkey
                await MainActor.run {
                    if self.selectedPromptID != id {
                        self.selectedPromptID = id
                    }
                }

                // Fast check for selected text (AX only, ~5ms)
                await checkAndStoreSelectedTextPromptFast()

                // Update UI IMMEDIATELY
                await MainActor.run { self.isRecording = true }

                let promptText = await MainActor.run { self.userPrompt }
                await controller.toggle(userPrompt: promptText)

            case .recording:
                await MainActor.run { self.isRecording = false }

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
                } else {
                    await waitForLatestProviderUpdate()
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
                    await MainActor.run { self.isRecording = false }

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
                    } else {
                        await waitForLatestProviderUpdate()
                    }

                    let promptText = await MainActor.run { self.userPrompt }
                    await controller.finish(userPrompt: promptText)
                    await restoreOriginalPromptIfNeeded()
                }
            }
        }
    }

    private func updateProviders() {
        let prompt = prompts.prompt(withID: selectedPromptID) ?? prompts.first
        let task = applyProviders(using: prompt)
        providerUpdateTask = task
    }

    private func updateProvidersWithSelectedTextOverride() async {
        // Use the selected text prompt override for provider updates
        let task = applyProviders(using: selectedTextPromptOverride)
        providerUpdateTask = task
    }

    // MARK: - Soniox Context Optimization

    func buildSonioxContext() -> String {
        var contextParts: [String] = []

        // Add keyword context (highest priority for accuracy)
        if !sonioxContextKeywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextParts.append(sonioxContextKeywords.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Add paragraph context (domain-specific information)
        if !sonioxContextParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextParts.append(sonioxContextParagraph.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return contextParts.joined(separator: "\n")
    }

    func buildSonioxLanguageHints() -> [String] {
        let hints = sonioxLanguageHints.trimmingCharacters(in: .whitespacesAndNewlines)
        if hints.isEmpty {
            // Fallback to single language from settings
            let lang = UserDefaults.standard.string(forKey: "transcription.language") ?? "en"
            return [lang]
        }

        // Parse comma-separated language hints
        return hints.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Soniox Accuracy Presets

    enum SonioxPreset {
        case medical
        case legal
        case technical
        case general
    }

    func applySonioxPreset(_ preset: SonioxPreset) {
        switch preset {
        case .medical:
            sonioxContextKeywords = "Celebrex, Zyrtec, Xanax, Prilosec, Amoxicillin, Clavulanate, Potassium, patient, diagnosis, treatment, medication, prescription, dosage, symptoms, examination, clinical, therapy, regimen, adverse, reaction, contraindication, pharmacology, therapeutic, efficacy, prognosis"
            sonioxContextParagraph = "Medical consultation discussing patient symptoms, diagnosis, treatment options, medications, dosages, and clinical observations. Includes discussion of drug interactions, side effects, and patient care plans."
            sonioxLanguageHints = "en"

        case .legal:
            sonioxContextKeywords = "plaintiff, defendant, jurisdiction, statute, regulation, contract, agreement, liability, negligence, tort, claim, settlement, judgment, appeal, precedent, testimony, evidence, deposition, affidavit, motion, hearing, verdict, damages, injunction"
            sonioxContextParagraph = "Legal proceedings discussing case law, statutes, regulations, contracts, and legal arguments. Includes references to court filings, testimony, evidence, and judicial decisions."
            sonioxLanguageHints = "en"

        case .technical:
            sonioxContextKeywords = "API, endpoint, database, PostgreSQL, MySQL, Redis, cache, authentication, authorization, token, JWT, OAuth, REST, GraphQL, microservices, container, Docker, Kubernetes, deployment, CI/CD, pipeline, repository, commit, merge, branch, frontend, backend, fullstack"
            sonioxContextParagraph = "Technical discussion about software development, system architecture, APIs, databases, deployment pipelines, and engineering practices. Includes discussion of programming concepts, infrastructure, and development workflows."
            sonioxLanguageHints = "en"

        case .general:
            sonioxContextKeywords = ""
            sonioxContextParagraph = ""
            sonioxLanguageHints = "en"
        }
    }

    @discardableResult
    private func applyProviders(using prompt: PromptConfiguration?) -> Task<Void, Never> {
        // Update settings using the configured system prompt, rendered with current vocabulary/spelling placeholders
        var provider: TranscriptionProvider? = nil
        var tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: transcriptionModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
        let modelForActivePrompt = resolvedLLMModel(for: prompt)
        if transcriptionModel == "apple-native" {
            if #available(macOS 26, *) {
                provider = NativeAppleTranscriptionProvider()
                tSettings = TranscriptionSettings(endpoint: URL(string: "https://apple-native.local")!, model: transcriptionModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
            } else {
                AppLog.dictation.error("Apple native transcription requires macOS 26 or later; falling back to Groq.")
                provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
                tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: AppConfig.defaultTranscriptionModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
            }
        } else if transcriptionModel.lowercased().contains("parakeet") || transcriptionModel.lowercased().contains("local") {
            provider = ParakeetTranscriptionProvider()
            tSettings = TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: transcriptionModel)
        } else if transcriptionModel == "assemblyai-streaming" {
            let key = KeychainService().getSecret(forKey: AppConfig.assemblyAIAPIKeyAlias) ?? ""
            provider = AssemblyAIStreamingProvider(apiKey: key)
            // Endpoint not used by streaming provider, but keep for logging
            tSettings = TranscriptionSettings(endpoint: URL(string: "wss://streaming.assemblyai.com")!, model: transcriptionModel, timeout: max(5, min(180, transcriptionTimeoutSeconds)))
        } else if transcriptionModel == "deepgram-streaming" {
            let key = KeychainService().getSecret(forKey: AppConfig.deepgramAPIKeyAlias) ?? ""
            provider = DeepgramStreamingProvider(apiKey: key)
            tSettings = TranscriptionSettings(endpoint: URL(string: "wss://api.deepgram.com/v1/listen")!, model: transcriptionModel, timeout: max(5, min(180, transcriptionTimeoutSeconds)))
        } else if transcriptionModel == "soniox-streaming" {
            let providerInstance = SonioxStreamingProvider(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias) })
            provider = providerInstance
            let sonioxModel = UserDefaults.standard.string(forKey: "soniox.model") ?? AppConfig.defaultSonioxModel
            tSettings = TranscriptionSettings(endpoint: AppConfig.sonioxRealtime, model: sonioxModel, timeout: max(5, min(180, transcriptionTimeoutSeconds)))
        } else if transcriptionModel == "groq-streaming" {
            provider = GroqStreamingProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
            // Use the actual Whisper model for the underlying transcription, but keep the groq-streaming identifier for the UI
            let actualModel = "whisper-large-v3-turbo" // Default to the fastest model for streaming
            tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: actualModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
        } else {
            provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        }
        let renderedSystem = PromptBuilder.renderSystemPrompt(template: systemPrompt, customVocabulary: vocabCustom)
        let providerForActivePrompt = resolvedLLMProvider(for: prompt)
        // Align LLM timeout with the user-configured timeout setting
        let llmTimeout = max(5, min(120, transcriptionTimeoutSeconds))
        var lSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: modelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming)

        // Choose LLM provider and endpoint
        var llmProviderInstance: LLMProvider
        switch providerForActivePrompt.lowercased() {
        case "openrouter":
            lSettings = LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: modelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming)
            GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)
            llmProviderInstance = OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }))
        case "cerebras":
            lSettings = LLMSettings(endpoint: AppConfig.cerebrasChatCompletions, model: modelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming)
            GroqHTTPClient.preWarmConnection(to: AppConfig.cerebrasChatCompletions)
            llmProviderInstance = CerebrasLLMProvider(client: CerebrasHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.cerebrasAPIKeyAlias) }))
        default:
            lSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: modelForActivePrompt, systemPrompt: renderedSystem, timeout: llmTimeout, streaming: llmStreaming)
            GroqHTTPClient.preWarmConnection(to: AppConfig.groqChatCompletions)
            llmProviderInstance = GroqLLMProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        }

        let providerToApply = provider
        let transcriberSettings = tSettings
        let llmProviderToApply = llmProviderInstance
        let llmSettingsToApply = lSettings
        let isLLMEnabled = llmEnabled
        let useScreenContext = resolvedScreenContext(for: prompt)
        let useClipboardContext = resolvedClipboardContext(for: prompt)
        let preprocessingMode = resolvedScreenContextPreprocessingMode(for: prompt)
        let screenOrganizePromptToApply = screenOrganizePrompt

        return Task {
            if let providerToApply {
                await controller.updateTranscriberProvider(providerToApply)
            }
            await controller.updateTranscriberSettings(transcriberSettings)
            await controller.updateLLMProvider(llmProviderToApply)
            await controller.updateLLMSettings(llmSettingsToApply)
            await controller.updateLLMEnabled(isLLMEnabled)
            await controller.updateScreenContextEnabled(useScreenContext)
            await controller.updateClipboardContextEnabled(useClipboardContext)
            await controller.updateScreenContextPreprocessingMode(preprocessingMode)
            await controller.updateScreenOrganizePrompt(screenOrganizePromptToApply)
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

    func generateScratchpadTitle(for content: String) async throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard llmEnabled else {
            throw NSError(domain: "DictationViewModel", code: -2100, userInfo: [NSLocalizedDescriptionKey: "LLM processing is disabled in settings."])
        }
        await waitForLatestProviderUpdate()
        let noteText = """
        <NOTE_CONTENT>
        \(trimmed)
        </NOTE_CONTENT>
        """
        let response = try await controller.runLLM(
            text: noteText,
            userPrompt: AppConfig.scratchpadTitleUserPrompt,
            systemPromptOverride: AppConfig.scratchpadTitleSystemPrompt,
            streamingOverride: false
        )
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runScratchpadPrompt(content: String, prompt: PromptConfiguration) async throws -> String {
        guard llmEnabled else {
            throw NSError(domain: "DictationViewModel", code: -2101, userInfo: [NSLocalizedDescriptionKey: "LLM processing is disabled in settings."])
        }
        await waitForLatestProviderUpdate()
        let previousPrompt = prompts.prompt(withID: selectedPromptID) ?? prompts.first
        let overrideTask = applyProviders(using: prompt)
        providerUpdateTask = overrideTask
        defer {
            if previousPrompt?.id != prompt.id {
                updateProviders()
            }
        }
        await overrideTask.value
        let system = PromptBuilder.renderSystemPrompt(template: prompt.systemPrompt, customVocabulary: vocabCustom)
        let noteText = """
        <NOTE_CONTENT>
        \(content)
        </NOTE_CONTENT>
        """
        let response = try await controller.runLLM(
            text: noteText,
            userPrompt: prompt.userPrompt,
            systemPromptOverride: system,
            streamingOverride: llmStreaming,
            modelOverride: resolvedLLMModel(for: prompt)
        )
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PromptBootstrap {
    let prompts: [PromptConfiguration]
    let selectedID: UUID
    let activeSystem: String
    let activeUser: String
}

private extension DictationViewModel {
    static let favoritesDataKey = "llm.models.favorites.data"
    static let favoritesLegacyKey = "llm.models.favorites"

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
        if let override = prompt?.llmProviderOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let fallback = llmProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "groq" : fallback
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

    func resolvedScreenContextPreprocessingMode(for prompt: PromptConfiguration?) -> ScreenContextPreprocessingMode {
        guard resolvedScreenContext(for: prompt) else { return .off }
        if let override = prompt?.screenContextPreprocessingOverride {
            return override
        }
        return screenContextPreprocessingMode
    }
}
