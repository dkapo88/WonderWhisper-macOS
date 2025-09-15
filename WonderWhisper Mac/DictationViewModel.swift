import Foundation
import Combine
import Carbon.HIToolbox
import AppKit

@MainActor
final class DictationViewModel: ObservableObject {
    @Published var status: String = "Idle"
    @Published var isRecording: Bool = false { didSet { updateEscapeMonitor(isRecording: isRecording) } }
    @Published var audioLevel: Float = 0

    // Prompts
    // System prompt is sent as the system role content
    @Published var systemPrompt: String = UserDefaults.standard.string(forKey: "llm.systemPrompt") ?? "" { didSet { persistAndUpdate() } }
    // User prompt is an additional user message appended after the structured transcript context
    @Published var userPrompt: String = UserDefaults.standard.string(forKey: "llm.userMessage") ?? "" { didSet { UserDefaults.standard.set(userPrompt, forKey: "llm.userMessage") } }

    // Transcription + LLM preferences
    @Published var transcriptionModel: String = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel { didSet { persistAndUpdate() } }
    @Published var llmEnabled: Bool = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var screenContextEnabled: Bool = UserDefaults.standard.object(forKey: "screenContext.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }

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

    // API Key inputs (not persisted directly; saved via Keychain on action)
    @Published var assemblyAIKeyInput: String = ""
    @Published var deepgramKeyInput: String = ""

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

    // Global Escape key monitor (enabled only while recording)
    private var escapeEventMonitor: Any?

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

        let persistedLLMModel = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel
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
        }

        var llm: LLMProvider = GroqLLMProvider(client: http)
        // Pre-warm chat endpoint to reduce cold-start latency
        GroqHTTPClient.preWarmConnection(to: AppConfig.groqChatCompletions)
        // Initialize prompts: use persisted systemPrompt if set; otherwise seed with the default system template
        let initialSystem = UserDefaults.standard.string(forKey: "llm.systemPrompt") ?? AppConfig.defaultSystemPromptTemplate
        self.systemPrompt = initialSystem
        self.userPrompt = UserDefaults.standard.string(forKey: "llm.userMessage") ?? ""

        let renderedInitial = PromptBuilder.renderSystemPrompt(template: initialSystem, customVocabulary: persistedVocabCustom)
        var llmSettings = LLMSettings(
            endpoint: AppConfig.groqChatCompletions,
            model: persistedLLMModel,
            systemPrompt: renderedInitial,
            timeout: 60,
            streaming: UserDefaults.standard.object(forKey: "llm.streaming") as? Bool ?? false
        )

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
        // Now that self is fully initialized, hook up level monitoring
        recorder.onLevel = { [weak self] level in
            guard let self = self else { return }
            Task { @MainActor in self.audioLevel = level }
        }
        // Apply initial LLM/screen-context flags
        Task {
            await controller.updateLLMEnabled(persistedLLMEnabled)
            await controller.updateScreenContextEnabled(persistedScreenContextEnabled)
        }

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
        // Persist prompts whenever toggling, so changes aren't lost
        UserDefaults.standard.set(systemPrompt, forKey: "llm.systemPrompt")
        UserDefaults.standard.set(userPrompt, forKey: "llm.userMessage")
        Task { await controller.toggle(userPrompt: userPrompt) }
    }

    func finish() {
        UserDefaults.standard.set(systemPrompt, forKey: "llm.systemPrompt")
        UserDefaults.standard.set(userPrompt, forKey: "llm.userMessage")
        Task { await controller.finish(userPrompt: userPrompt) }
    }

    func cancel() {
        Task { await controller.cancel() }
    }

    private func updateEscapeMonitor(isRecording: Bool) {
        // Remove any existing monitor first
        if let m = escapeEventMonitor { NSEvent.removeMonitor(m); escapeEventMonitor = nil }
        guard isRecording else { return }
        // Register a global keyDown monitor for Escape (keyCode 53)
        escapeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: NSEvent.EventTypeMask.keyDown) { [weak self] (event: NSEvent) in
            guard let self = self else { return }
            if event.keyCode == 53 { // kVK_Escape
                self.cancel()
            }
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

    private func persistAndUpdate() {
        UserDefaults.standard.set(transcriptionModel, forKey: "transcription.model")
        UserDefaults.standard.set(llmEnabled, forKey: "llm.enabled")
        UserDefaults.standard.set(screenContextEnabled, forKey: "screenContext.enabled")

        UserDefaults.standard.set(llmModel, forKey: "llm.model")
        UserDefaults.standard.set(llmProvider, forKey: "llm.provider")
        UserDefaults.standard.set(openrouterRouting, forKey: "llm.openrouter.routing")
        UserDefaults.standard.set(vocabCustom, forKey: "vocab.custom")
        UserDefaults.standard.set(vocabSpelling, forKey: "vocab.spelling")
        UserDefaults.standard.set(systemPrompt, forKey: "llm.systemPrompt")
        UserDefaults.standard.set(userPrompt, forKey: "llm.userMessage")
        updateProviders()
    }

    private func updateProviders() {
        // Update settings using the configured system prompt, rendered with current vocabulary/spelling placeholders
        var provider: TranscriptionProvider? = nil
        var tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: transcriptionModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
        if transcriptionModel.lowercased().contains("parakeet") || transcriptionModel.lowercased().contains("local") {
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
        } else if transcriptionModel == "groq-streaming" {
            provider = GroqStreamingProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
            // Use the actual Whisper model for the underlying transcription, but keep the groq-streaming identifier for the UI
            let actualModel = "whisper-large-v3-turbo" // Default to the fastest model for streaming
            tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: actualModel, timeout: max(5, min(120, transcriptionTimeoutSeconds)))
        } else {
            provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        }
        let renderedSystem = PromptBuilder.renderSystemPrompt(template: systemPrompt, customVocabulary: vocabCustom)
        var lSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: llmModel, systemPrompt: renderedSystem, timeout: 60, streaming: llmStreaming)

        // Choose LLM provider and endpoint
        var llmProviderInstance: LLMProvider = GroqLLMProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        if llmProvider.lowercased() == "openrouter" {
            lSettings = LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: llmModel, systemPrompt: renderedSystem, timeout: 60, streaming: llmStreaming)
            // Pre-warm OpenRouter endpoint for better latency
            GroqHTTPClient.preWarmConnection(to: AppConfig.openrouterChatCompletions)
            llmProviderInstance = OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) }))
        }

        Task {
            if let p = provider { await controller.updateTranscriberProvider(p) }
            await controller.updateTranscriberSettings(tSettings)
            await controller.updateLLMProvider(llmProviderInstance)
            await controller.updateLLMSettings(lSettings)
            await controller.updateLLMEnabled(llmEnabled)
            await controller.updateScreenContextEnabled(screenContextEnabled)
        }
    }

    // Reprocess a saved history entry with current settings
    func reprocessHistoryEntry(_ entry: HistoryEntry) async {
        await controller.reprocess(entry: entry, userPrompt: userPrompt)
    }

    // Paste the last transcription output (LLM if present; else raw transcript)
    func pasteLastTranscription() {
        guard let first = history.entries.first else { return }
        let text = first.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first.transcript : first.output
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        Task { await controller.insert(text) }
    }
}
