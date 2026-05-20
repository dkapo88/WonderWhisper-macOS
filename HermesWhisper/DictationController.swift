import Foundation
import AppKit
import ApplicationServices
import OSLog
import os.signpost

actor DictationController {
    private let spLog = OSLog(subsystem: AppConfig.bundleIdentifier, category: "Dictation-SP")
    enum State: Equatable { case idle, recording, transcribing, processing, inserting, error(String) }
    struct TranscriptionOnlyResult: Equatable {
        var fileURL: URL?
        var appName: String?
        var bundleID: String?
        var transcript: String
        var screenContext: String?
        var screenContextMethod: String?
        var selectedText: String?
        var activeTextField: String?
        var transcriptionModel: String
        var transcriptionSeconds: Double
        var totalSeconds: Double
    }
    private(set) var state: State = .idle

    private let recorder: AudioRecorder
    private var transcriber: TranscriptionProvider
    private var transcriberSettings: TranscriptionSettings
    private var llm: LLMProvider
    private var llmSettings: LLMSettings
    private let inserter: InsertionService
    private let screenContext: ScreenContextService
    private let history: HistoryStore?
    private let conversationHistoryStore: ConversationHistoryStore

    private var llmEnabled: Bool = true
    private var screenContextEnabled: Bool = true
    private var screenImageEnabled: Bool = false
    private var clipboardContextEnabled: Bool = false
    private var selectedTextEnabled: Bool = true
    private var activeTextFieldEnabled: Bool = true
    private var currentRecordingURL: URL?
    private var insertionTargetProcessIdentifier: pid_t?
    private var preCapturedScreenSnapshot: ScreenCaptureSnapshot?
    private var preCapturedScreenText: String?
    private var preCapturedScreenMethod: String?
    private var preCapturedSelectedText: String?
    private var preCapturedActiveTextField: String?
    private var clipboardSnapshotForSession: String?
    private let clipboardMonitor = ClipboardContextMonitor(startsEnabled: false)
    private let clipboardWindowSeconds: TimeInterval = 10
    private var screenContextCaptureGeneration: Int = 0

    private var screenContextCaptureMode: ScreenContextCaptureMode = .image
    private var autoMuteEnabled: Bool = false

    // Removed memory recording feature due to unreliable output

    init(recorder: AudioRecorder,
         transcriber: TranscriptionProvider,
         transcriberSettings: TranscriptionSettings,
         llm: LLMProvider,
         llmSettings: LLMSettings,
         inserter: InsertionService,
         screenContext: ScreenContextService = ScreenContextService(),
         history: HistoryStore? = nil) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.transcriberSettings = transcriberSettings
        self.llm = llm
        self.llmSettings = llmSettings
        self.inserter = inserter
        self.screenContext = screenContext
        self.history = history
        self.conversationHistoryStore = ConversationHistoryStore()
    }

    private var currentPrompt: PromptConfiguration?

    func toggle(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
        self.currentPrompt = activePrompt
        switch state {
        case .idle, .error:
            do {
                AppLog.dictation.log("Recording start")
                insertionTargetProcessIdentifier = Self.currentExternalFrontmostProcessIdentifier()

                if autoMuteEnabled {
                    _ = SystemAudioController.shared.muteSystemAudioAndWait()
                }

                // Always start file recording as backup for all providers
                recorder.captureProfile = .standard16k

                // Update state IMMEDIATELY after starting recording for instant UI feedback
                let url = try recorder.startRecording()
                state = .recording

                let recordingStart = Date()
                currentRecordingURL = url

                // If Parakeet is active, preload models in the background to hide cold-start latency
                if let pk = transcriber as? ParakeetTranscriptionProvider {
                    Task { await pk.warmUp() }
                }

                if let groq = transcriber as? GroqStreamingProvider {
                    groq.updateSettings(transcriberSettings)
                    try await groq.beginRealtime()
                    do {
                        try recorder.startStreamingPCM16 { data in
                            Task { try? await groq.feedPCM16(data) }
                        }
                    } catch {
                        AppLog.dictation.error("Groq streaming audio start failed; continuing with file fallback: \(error.localizedDescription)")
                        await groq.abort()
                    }
                }

                if let soniox = transcriber as? SonioxStreamingProvider {
                    await soniox.updateSettings(transcriberSettings)
                    await soniox.setInputSampleRate(16_000)
                    try await soniox.beginRealtime()
                    try recorder.startStreamingPCM16 { data in
                        soniox.enqueuePCM16(data)
                    }
                }

                if let xaiStreaming = transcriber as? XAIStreamingTranscriptionProvider {
                    try await xaiStreaming.beginRealtime(settings: transcriberSettings)
                    try recorder.startStreamingPCM16 { data in
                        xaiStreaming.enqueuePCM16(data)
                    }
                }

                // Pre-capture screen context early so it is ready once recording stops
                preCapturedScreenSnapshot = nil
                preCapturedScreenText = nil
                preCapturedScreenMethod = nil
                preCapturedSelectedText = nil
                preCapturedActiveTextField = nil
                clipboardSnapshotForSession = nil
                screenContextCaptureGeneration += 1
                let contextGeneration = screenContextCaptureGeneration

                if llmEnabled && screenContextEnabled {
                    Task { await self.preCaptureScreenContext(generation: contextGeneration) }
                }
                if clipboardContextEnabled {
                    await clipboardMonitor.refreshSnapshot()
                    clipboardSnapshotForSession = await clipboardMonitor.consumeClipboardIfRecent(referenceDate: recordingStart, window: clipboardWindowSeconds)
                }
            } catch {
                AppLog.dictation.error("Recording start failed: \(error.localizedDescription)")
                recorder.stopStreamingPCM16()
                if let groq = transcriber as? GroqStreamingProvider {
                    await groq.abort()
                }
                if let soniox = transcriber as? SonioxStreamingProvider {
                    await soniox.abort()
                }
                if let xaiStreaming = transcriber as? XAIStreamingTranscriptionProvider {
                    await xaiStreaming.abort()
                }
                _ = recorder.stopRecording()
                if autoMuteEnabled {
                    SystemAudioController.shared.unmuteSystemAudioAndWait()
                }
                resetTransientSessionState()
                state = .error("Recording start failed: \(error.localizedDescription)")
            }
        case .recording:
            await stopAndProcess(userPrompt: userPrompt)
        default:
            break
        }
    }

    // Helper to detect effectively empty transcripts (empty or punctuation-only)
    private func looksEmptyOrPunctuation(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Treat strings like "...", "—", "…", etc. as empty
        return t.rangeOfCharacter(from: .alphanumerics) == nil
    }

    private func stopAndProcess(userPrompt: String) async {
        guard state == .recording else { return }
        AppLog.dictation.log("Stop requested provider=\(String(describing: type(of: self.transcriber)), privacy: .public) model=\(self.transcriberSettings.model, privacy: .public)")
        // Stop live streaming if active
        AppLog.dictation.log("Stopping streaming recorder")
        recorder.stopStreamingPCM16()
        // Do NOT abort streaming providers here; we want them to finalize
        // and provide a fast, low-latency final transcript.

        AppLog.dictation.log("Stopping file recorder")
        let recordingFileURL = await recorder.stopRecordingAndWait() // Always have file as backup
        if let recordingFileURL {
            AppLog.dictation.log("File recorder finalized file=\(recordingFileURL.lastPathComponent, privacy: .public)")
        } else {
            AppLog.dictation.warning("File recorder returned nil URL")
        }
        
        if autoMuteEnabled {
            SystemAudioController.shared.unmuteSystemAudioAndWait()
        }

        let pipeId = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "HW.pipeline.total", signpostID: pipeId)
        defer {
            resetTransientSessionState()
            os_signpost(.end, log: spLog, name: "HW.pipeline.total", signpostID: pipeId)
        }

        let captureModeForSession: ScreenContextCaptureMode = {
            if preCapturedScreenSnapshot != nil { return .image }
            if preCapturedScreenText != nil { return .text }
            return screenContextCaptureMode
        }()
        var activeTextFieldForHistory: String? = nil

        do {
            let overallStart = Date()
            state = .transcribing
            let t0 = Date()
            var transcript: String = ""
            let hotkeySettings = TranscriptionSettings(
                endpoint: transcriberSettings.endpoint,
                model: transcriberSettings.model,
                timeout: transcriberSettings.timeout,
                language: transcriberSettings.language,
                vocabularyTerms: transcriberSettings.vocabularyTerms,
                context: "hotkey"
            )

            os_signpost(.begin, log: spLog, name: "HW.file.transcribe", signpostID: pipeId)
            if let groq = transcriber as? GroqStreamingProvider {
                // Prefer Groq chunked streaming transcript for speed
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await groq.endRealtime()
                // Fallback to file if streaming gave empty or punctuation-only result
                if looksEmptyOrPunctuation(transcript), let fileURL = recordingFileURL {
                    AppLog.dictation.log("Streaming empty/punctuation-only; fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let soniox = transcriber as? SonioxStreamingProvider {
                // Soniox real-time streaming - use preview text immediately
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await soniox.endRealtime()
                // Fallback to Groq file transcription if Soniox gave empty result
                if looksEmptyOrPunctuation(transcript), recordingFileURL != nil {
                    AppLog.dictation.log("Soniox streaming empty; no file fallback available")
                    // Soniox doesn't support file transcription, so just use empty
                }
            } else if let xaiStreaming = transcriber as? XAIStreamingTranscriptionProvider {
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await xaiStreaming.endRealtime()
                if looksEmptyOrPunctuation(transcript), let fileURL = recordingFileURL {
                    AppLog.dictation.log("xAI streaming empty/punctuation-only; fallback to async file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else {
                // Standard file-based transcription for non-streaming providers
                guard let fileURL = recordingFileURL else { throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"]) }
                // Ensure the recorded file is fully finalized before reading to avoid rare
                // issues on some systems where the file appears complete but is still being flushed.
                AppLog.dictation.log("Waiting for stable file file=\(fileURL.lastPathComponent, privacy: .public)")
                await Self.waitUntilFileIsStable(fileURL)
                AppLog.dictation.log("Transcription start (file) provider=\(String(describing: type(of: self.transcriber)), privacy: .public) model=\(hotkeySettings.model, privacy: .public) file=\(fileURL.lastPathComponent, privacy: .public)")
                transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
            }
            let transcribeDT = Date().timeIntervalSince(t0)
            AppLog.dictation.log("Transcription done in \(transcribeDT, format: .fixed(precision: 3))s")
            os_signpost(.end, log: spLog, name: "HW.file.transcribe", signpostID: pipeId)
            transcript = applyVocabularyCorrections(to: transcript)

            let selected = resolveSelectedTextForSession()
            let activeTextField = resolveActiveTextFieldForSession()
            activeTextFieldForHistory = activeTextField

            // Skip LLM and insertion if transcript is still empty after all fallbacks
            if looksEmptyOrPunctuation(transcript) {
                AppLog.dictation.warning("Transcript empty or punctuation-only; skipping LLM and insertion")
                state = .idle
                // Record history entry with empty transcript
                var appNameHist: String? = nil
                var bundleIDHist: String? = nil
                let pair = screenContext.frontmostAppNameAndBundle()
                appNameHist = pair.0
                bundleIDHist = screenContextEnabled ? pair.1 : nil
                await history?.append(
                    fileURL: recordingFileURL ?? currentRecordingURL,
                    appName: appNameHist,
                    bundleID: bundleIDHist,
                    transcript: transcript,
                    output: "",
                    screenContext: nil,
                    screenContextMethod: nil,
                    screenImage: nil,
                    selectedText: selected,
                    activeTextField: activeTextFieldForHistory,
                    llmSystemMessage: nil,
                    llmUserMessage: nil,
                    transcriptionModel: transcriberSettings.model,
                    llmModel: nil,
                    transcriptionSeconds: transcribeDT,
                    llmSeconds: nil,
                    totalSeconds: Date().timeIntervalSince(overallStart)
                )
                return
            }

            var output = transcript
            var llmDT: TimeInterval = 0
            
            var screenContentsForPrompt: String? = nil
            var screenMethod: String? = nil
            var screenAttachment: LLMImageAttachment? = nil
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil
            if llmEnabled {
                state = .processing
                var appNameForPrompt: String? = nil
                let (name, _) = screenContext.frontmostAppNameAndBundle()
                appNameForPrompt = name
                if screenContextEnabled {
                    if let text = preCapturedScreenText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                        screenContentsForPrompt = text
                        screenMethod = preCapturedScreenMethod
                    }
                }
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    activeTextField: activeTextField,
                    appName: appNameForPrompt,
                    screenContents: nil,
                    screenContextTerms: screenContentsForPrompt,
                    customVocabulary: UserDefaults.standard.string(forKey: "vocab.custom"),
                    clipboardText: clipboardSnapshotForSession
                )
                AppLog.dictation.log("Prompt context lengths: transcript=\(transcript.count) selected=\(selected?.count ?? 0) activeField=\(activeTextField?.count ?? 0) screen=\(screenContentsForPrompt?.count ?? 0) clipboard=\(self.clipboardSnapshotForSession?.count ?? 0)")
                // Capture full user message for history
                userMsgForHistory = userMsg
                AppLog.dictation.log("LLM processing start")
                os_signpost(.begin, log: spLog, name: "HW.llm.process", signpostID: pipeId)
                let t1 = Date()
                do {
                    // Handle conversation mode if enabled for this prompt
                    if let prompt = currentPrompt, prompt.conversationModeEnabled {
                        // Check if provider changed and clear history if so
                        _ = await conversationHistoryStore.checkProviderChange(for: prompt.id, currentProvider: llmSettings.model, currentEndpoint: llmSettings.endpoint)

                        // Build context with prior messages
                        let contextMessages = await conversationHistoryStore.getContextMessages(for: prompt.id, count: prompt.conversationContextMessages)

                        // Build full message list with conversation context
                        var fullPrompt = userMsg
                        if !contextMessages.isEmpty {
                            let contextStr = contextMessages.map { msg in
                                let roleLabel = msg.role.uppercased()
                                return "\(roleLabel): \(msg.content)"
                            }.joined(separator: "\n\n")
                            fullPrompt = contextStr + "\n\nUSER: " + userMsg
                        }

                        // Send to LLM with full context
                        output = try await llm.process(text: fullPrompt, userPrompt: userPrompt, settings: llmSettings, imageAttachment: screenAttachment)

                        // Store both user and assistant messages
                        await conversationHistoryStore.addMessages(to: prompt.id, messages: [
                            PromptConversationMessage(role: "user", content: transcript),
                            PromptConversationMessage(role: "assistant", content: output)
                        ])

                        // Update provider info
                        await conversationHistoryStore.updateProvider(for: prompt.id, provider: llmSettings.model, endpoint: llmSettings.endpoint)

                        AppLog.dictation.log("Conversation mode: stored \(contextMessages.count) context messages")
                    } else {
                        // Standard non-conversation mode
                        output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings, imageAttachment: screenAttachment)
                    }

                    llmDT = Date().timeIntervalSince(t1)
                    AppLog.dictation.log("LLM processing done in \(llmDT, format: .fixed(precision: 3))s")
                    os_signpost(.end, log: spLog, name: "HW.llm.process", signpostID: pipeId)
                } catch {
                    let ns = error as NSError
                    llmDT = Date().timeIntervalSince(t1)
                    AppLog.dictation.error("LLM error after \(llmDT, format: .fixed(precision: 3))s: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code)")
                    // Fallback to raw transcript on LLM failure
                    output = transcript
                    state = .transcribing
                }
            }

            // Apply deterministic text replacements on final output
            let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
            if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = TextReplacement.apply(to: output, withRules: rules)
            }
            // Ensure a single trailing space to facilitate continued dictation
            output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "

            state = .inserting
            os_signpost(.begin, log: spLog, name: "HW.insert.total", signpostID: pipeId)
            inserter.insert(output, targetProcessIdentifier: insertionTargetProcessIdentifier)
            os_signpost(.end, log: spLog, name: "HW.insert.total", signpostID: pipeId)

            state = .idle

            // Record history entry
            var appNameHist: String? = nil
            var bundleIDHist: String? = nil
            let pair = screenContext.frontmostAppNameAndBundle()
            appNameHist = pair.0
            bundleIDHist = screenContextEnabled ? pair.1 : nil
            let totalDT = Date().timeIntervalSince(overallStart)
            let imageForHistory: ScreenCaptureSnapshot? = nil
            await history?.append(
                fileURL: recordingFileURL ?? currentRecordingURL,
                appName: appNameHist,
                bundleID: bundleIDHist,
                transcript: transcript,
                output: output,
                screenContext: screenContentsForPrompt,
                screenContextMethod: screenMethod,
                screenImage: imageForHistory,
                selectedText: selected,
                activeTextField: activeTextFieldForHistory,
                llmSystemMessage: systemForHistory,
                llmUserMessage: userMsgForHistory,
                transcriptionModel: transcriberSettings.model,
                llmModel: llmEnabled ? llmSettings.model : nil,
                transcriptionSeconds: transcribeDT,
                llmSeconds: llmEnabled ? llmDT : nil,
                totalSeconds: totalDT
            )
        } catch {
            let ns = error as NSError
            let diagnostic = (error as? ProviderError)?.diagnosticDescription ?? "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
            AppLog.dictation.error("Pipeline error: \(diagnostic, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            // Persist audio so the user can reprocess later even on failure
            var appNameHist: String? = nil
            var bundleIDHist: String? = nil
            let pair = screenContext.frontmostAppNameAndBundle()
            appNameHist = pair.0
            bundleIDHist = screenContextEnabled ? pair.1 : nil
            let imageForHistory: ScreenCaptureSnapshot? = nil
            let textForHistory = (captureModeForSession == .text) ? preCapturedScreenText : nil
            // Capture selected text dynamically for error case (preCapturedSelectedText may not be set)
            let selectedTextForHistory = resolveSelectedTextForSession()
            await history?.append(
                fileURL: recordingFileURL,
                appName: appNameHist,
                bundleID: bundleIDHist,
                transcript: "",
                output: "",
                screenContext: textForHistory,
                screenContextMethod: (captureModeForSession == .text) ? preCapturedScreenMethod : imageForHistory?.method.rawValue,
                screenImage: imageForHistory,
                selectedText: selectedTextForHistory,
                activeTextField: activeTextFieldForHistory ?? resolveActiveTextFieldForSession(),
                llmSystemMessage: llmEnabled ? llmSettings.systemPrompt : nil,
                llmUserMessage: nil,
                transcriptionModel: transcriberSettings.model,
                llmModel: llmEnabled ? llmSettings.model : nil,
                transcriptionSeconds: nil,
                llmSeconds: nil,
                totalSeconds: nil
            )
            state = .error(error.localizedDescription)
        }
    }

    func currentState() -> State { state }

    func updateTranscriberSettings(_ s: TranscriptionSettings) { self.transcriberSettings = s }
    func updateLLMSettings(_ s: LLMSettings) { self.llmSettings = s }
    func updateLLMEnabled(_ enabled: Bool) { self.llmEnabled = enabled }
    func updateScreenContextEnabled(_ enabled: Bool) { self.screenContextEnabled = enabled }
    func updateScreenContextCaptureMode(_ mode: ScreenContextCaptureMode) { self.screenContextCaptureMode = mode }
    func updateClipboardContextEnabled(_ enabled: Bool) {
        clipboardContextEnabled = enabled
        Task { await clipboardMonitor.setMonitoringEnabled(enabled) }
        if !enabled {
            clipboardSnapshotForSession = nil
            Task { await clipboardMonitor.clear() }
        }
    }
    func updateScreenImageEnabled(_ enabled: Bool) { self.screenImageEnabled = enabled }
    func updateAutoMuteEnabled(_ enabled: Bool) { self.autoMuteEnabled = enabled }

    func clearConversationHistory(for promptID: UUID) {
        conversationHistoryStore.clearHistory(for: promptID)
        AppLog.dictation.log("Cleared conversation history for prompt \(promptID)")
    }

    func updateTranscriberProvider(_ p: TranscriptionProvider) { self.transcriber = p }
    func updateLLMProvider(_ p: LLMProvider) { self.llm = p }

    private func applyVocabularyCorrections(to transcript: String) -> String {
        let vocabulary = UserDefaults.standard.string(forKey: "vocab.custom") ?? ""
        let corrected = VocabularyTextCorrector.apply(to: transcript, vocabulary: vocabulary)
        if corrected != transcript {
            AppLog.dictation.log("Applied deterministic vocabulary corrections")
        }
        return corrected
    }

    private func resetTransientSessionState() {
        currentRecordingURL = nil
        insertionTargetProcessIdentifier = nil
        preCapturedScreenSnapshot = nil
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        preCapturedSelectedText = nil
        preCapturedActiveTextField = nil
        clipboardSnapshotForSession = nil
        screenContextCaptureGeneration += 1
        recorder.captureProfile = .standard16k
    }

    // Explicit controls for UI actions
    func finish(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
        self.currentPrompt = activePrompt
        await stopAndProcess(userPrompt: userPrompt)
    }

    func finishTranscriptionOnly(activePrompt: PromptConfiguration? = nil) async throws -> TranscriptionOnlyResult? {
        self.currentPrompt = activePrompt
        guard state == .recording else { return nil }

        AppLog.dictation.log("Stop requested for transcription-only flow provider=\(String(describing: type(of: self.transcriber)), privacy: .public) model=\(self.transcriberSettings.model, privacy: .public)")
        recorder.stopStreamingPCM16()

        let recordingFileURL = await recorder.stopRecordingAndWait()
        if autoMuteEnabled {
            SystemAudioController.shared.unmuteSystemAudioAndWait()
        }

        let pipeId = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "HW.pipeline.transcriptionOnly", signpostID: pipeId)
        defer {
            resetTransientSessionState()
            os_signpost(.end, log: spLog, name: "HW.pipeline.transcriptionOnly", signpostID: pipeId)
        }

        let overallStart = Date()
        let activeTextFieldForHistory: String?
        do {
            state = .transcribing
            let t0 = Date()
            var transcript = ""
            let hotkeySettings = TranscriptionSettings(
                endpoint: transcriberSettings.endpoint,
                model: transcriberSettings.model,
                timeout: transcriberSettings.timeout,
                language: transcriberSettings.language,
                vocabularyTerms: transcriberSettings.vocabularyTerms,
                context: "hermes"
            )

            os_signpost(.begin, log: spLog, name: "HW.file.transcribe", signpostID: pipeId)
            if let groq = transcriber as? GroqStreamingProvider {
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await groq.endRealtime()
                if looksEmptyOrPunctuation(transcript), let fileURL = recordingFileURL {
                    AppLog.dictation.log("Hermes flow streaming empty/punctuation-only; fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let soniox = transcriber as? SonioxStreamingProvider {
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await soniox.endRealtime()
                if looksEmptyOrPunctuation(transcript) {
                    AppLog.dictation.log("Hermes flow Soniox streaming empty; no file fallback available")
                }
            } else if let xaiStreaming = transcriber as? XAIStreamingTranscriptionProvider {
                try? await Task.sleep(nanoseconds: 150_000_000)
                transcript = try await xaiStreaming.endRealtime()
                if looksEmptyOrPunctuation(transcript), let fileURL = recordingFileURL {
                    AppLog.dictation.log("Hermes flow xAI streaming empty/punctuation-only; fallback to async file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else {
                guard let fileURL = recordingFileURL else {
                    throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"])
                }
                await Self.waitUntilFileIsStable(fileURL)
                transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
            }
            let transcribeDT = Date().timeIntervalSince(t0)
            os_signpost(.end, log: spLog, name: "HW.file.transcribe", signpostID: pipeId)
            transcript = applyVocabularyCorrections(to: transcript)

            let selected = resolveSelectedTextForSession()
            let activeTextField = resolveActiveTextFieldForSession()
            activeTextFieldForHistory = activeTextField

            let pair = screenContext.frontmostAppNameAndBundle()
            state = .idle
            return TranscriptionOnlyResult(
                fileURL: recordingFileURL ?? currentRecordingURL,
                appName: pair.0,
                bundleID: screenContextEnabled ? pair.1 : nil,
                transcript: transcript,
                screenContext: preCapturedScreenText,
                screenContextMethod: preCapturedScreenMethod,
                selectedText: selected,
                activeTextField: activeTextFieldForHistory,
                transcriptionModel: transcriberSettings.model,
                transcriptionSeconds: transcribeDT,
                totalSeconds: Date().timeIntervalSince(overallStart)
            )
        } catch {
            let ns = error as NSError
            AppLog.dictation.error("Transcription-only pipeline error: \(ns.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func cancel() async {
        // Cancel only applies to active recording; do not emit any output or history
        guard state == .recording else { return }
        // Stop live mic streaming if active
        recorder.stopStreamingPCM16()
        // Abort any active streaming provider sessions immediately (best-effort)
        if let groq = transcriber as? GroqStreamingProvider {
            await groq.abort()
        }
        if let soniox = transcriber as? SonioxStreamingProvider {
            await soniox.abort()
        }
        if let xaiStreaming = transcriber as? XAIStreamingTranscriptionProvider {
            await xaiStreaming.abort()
        }
        // Stop file recording and delete any created file
        _ = recorder.stopRecording()
        
        if autoMuteEnabled {
            SystemAudioController.shared.unmuteSystemAudioAndWait()
        }
        
        if let url = currentRecordingURL { try? FileManager.default.removeItem(at: url) }
        currentRecordingURL = nil
        // Reset any pre-captured context
        preCapturedScreenSnapshot = nil
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        preCapturedActiveTextField = nil
        clipboardSnapshotForSession = nil
        screenContextCaptureGeneration += 1
        Task { await clipboardMonitor.clear() }
        // Return to idle; no processing/transcription/insertion/history occurs
        state = .idle
    }

    // Insert arbitrary text now (used by paste-last shortcut)
    func insert(_ text: String) {
        state = .inserting
        var output = text
        // Apply deterministic text replacements
        let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = TextReplacement.apply(to: output, withRules: rules)
        }
        // Only add a single trailing space; no other formatting
        output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        inserter.insert(output)
        state = .idle
    }

    private static func currentExternalFrontmostProcessIdentifier() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let ownBundleID = Bundle.main.bundleIdentifier, app.bundleIdentifier == ownBundleID {
            return nil
        }
        return app.processIdentifier
    }

    func runLLM(text: String,
                userPrompt: String,
                systemPromptOverride: String? = nil,
                streamingOverride: Bool? = nil,
                modelOverride: String? = nil) async throws -> String {
        guard llmEnabled else {
            throw NSError(domain: "DictationController", code: -2000, userInfo: [NSLocalizedDescriptionKey: "LLM processing is currently disabled."])
        }
        let settings = LLMSettings(
            endpoint: llmSettings.endpoint,
            model: modelOverride ?? llmSettings.model,
            systemPrompt: systemPromptOverride ?? llmSettings.systemPrompt,
            timeout: llmSettings.timeout,
            streaming: streamingOverride ?? llmSettings.streaming,
            temperature: llmSettings.temperature,
            openRouterReasoning: llmSettings.openRouterReasoning
        )
        return try await llm.process(text: text, userPrompt: userPrompt, settings: settings)
    }

    func reprocess(entry: HistoryEntry, userPrompt: String) async {
        guard let history = history, let url = await history.audioURL(for: entry) else { return }
        do {
            state = .transcribing
            let overallStart = Date()
            let t0 = Date()
            let reprocSettings = TranscriptionSettings(
                endpoint: transcriberSettings.endpoint,
                model: transcriberSettings.model,
                timeout: transcriberSettings.timeout,
                language: transcriberSettings.language,
                vocabularyTerms: transcriberSettings.vocabularyTerms,
                context: "reprocess"
            )
            let transcript = applyVocabularyCorrections(
                to: try await transcriber.transcribe(fileURL: url, settings: reprocSettings)
            )
            let transcribeDT = Date().timeIntervalSince(t0)
            var output = transcript
            var llmDT: TimeInterval = 0
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil

            // Use original context from history entry instead of fetching new context
            let selected = entry.selectedText
            let screenInstruction = entry.screenContext
            let appNameForPrompt = entry.appName
            let screenContextWasTermList = [
                ScreenContextPreprocessingMethod.appleIntelligence.rawValue,
                ScreenContextPreprocessingMethod.localKeywords.rawValue
            ].contains(entry.screenContextMethod ?? "")
            var screenAttachment: LLMImageAttachment? = nil
            if let imageURL = await history.imageURL(for: entry),
               let data = try? Data(contentsOf: imageURL) {
                let inferredMime = entry.screenImageMimeType ?? HistoryStore.mimeType(forExtension: imageURL.pathExtension)
                screenAttachment = LLMImageAttachment(data: data, mimeType: inferredMime, detail: .high, filename: imageURL.lastPathComponent)
            }

            if llmEnabled {
                state = .processing
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    activeTextField: entry.activeTextField,
                    appName: appNameForPrompt,
                    screenContents: screenContextWasTermList ? nil : screenInstruction,
                    screenContextTerms: screenContextWasTermList ? screenInstruction : nil,
                    customVocabulary: UserDefaults.standard.string(forKey: "vocab.custom")
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                let t1 = Date()
                output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings, imageAttachment: screenAttachment)
                llmDT = Date().timeIntervalSince(t1)
            }
            state = .idle
            // Apply deterministic text replacements on final output
            let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
            if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = TextReplacement.apply(to: output, withRules: rules)
            }
            // Ensure a single trailing space to facilitate continued dictation
            output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "
            var updated = entry
            updated.date = Date()
            updated.transcript = transcript
            updated.output = output
            // Keep original context (screenContext, selectedText, screenContextMethod, appName, bundleID)
            // Only update the processing results and metadata
            updated.llmSystemMessage = systemForHistory
            updated.llmUserMessage = userMsgForHistory
            updated.transcriptionModel = transcriberSettings.model
            updated.llmModel = llmEnabled ? llmSettings.model : nil
            updated.transcriptionSeconds = transcribeDT
            updated.llmSeconds = llmEnabled ? llmDT : nil
            updated.totalSeconds = Date().timeIntervalSince(overallStart)
            await history.replace(id: entry.id, with: updated)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Pre-capture helpers
extension DictationController {
    private func resolveSelectedTextForSession() -> String? {
        guard selectedTextEnabled else { return nil }

        if let cached = preCapturedSelectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            if cached != preCapturedSelectedText {
                preCapturedSelectedText = cached
            }
            return cached
        }

        if let live = screenContext.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !live.isEmpty {
            preCapturedSelectedText = live
            return live
        }

        return nil
    }

    private func resolveActiveTextFieldForSession() -> String? {
        guard activeTextFieldEnabled else { return nil }
        if let selected = preCapturedSelectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            AppLog.dictation.log("Active text field: skipped because selected text present (\(selected.count) chars)")
            return nil
        }
        if let cached = preCapturedActiveTextField {
            AppLog.dictation.log("Active text field: using pre-captured (\(cached.count) chars)")
            return cached
        }
        if let live = screenContext.activeTextField() {
            preCapturedActiveTextField = live
            AppLog.dictation.log("Active text field: captured live (\(live.count) chars)")
            return live
        }
        let pair = screenContext.frontmostAppNameAndBundle()
        let trusted = AXIsProcessTrusted()
        AppLog.dictation.log("Active text field: unavailable (nil) app=\(pair.1 ?? pair.0 ?? "unknown") axTrusted=\(trusted)")
        return nil
    }

    private func preCaptureScreenContext(generation: Int) async {
        if !screenContextEnabled { return }
        guard generation == screenContextCaptureGeneration else { return }

        if selectedTextEnabled {
            _ = resolveSelectedTextForSession()
        }

        let hasSelectedText = preCapturedSelectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        // Always capture screen text for OCR context
        self.preCapturedScreenSnapshot = nil
        self.preCapturedScreenText = nil
        self.preCapturedScreenMethod = nil
        self.preCapturedActiveTextField = nil

        // Capture active text field unless there is already selected text.
        if !hasSelectedText,
           activeTextFieldEnabled,
           let focused = screenContext.activeTextField(),
           !focused.isEmpty {
            self.preCapturedActiveTextField = focused
        }

        if let result = await screenContext.captureFullScreenContextTerms(preferAccurate: true),
           !result.contextText.isEmpty {
            guard generation == screenContextCaptureGeneration else { return }
            self.preCapturedScreenText = result.contextText
            self.preCapturedScreenMethod = result.method.rawValue
            AppLog.dictation.log("Screen context terms captured via \(result.method.rawValue, privacy: .public): \(result.contextText.count, privacy: .public) chars")
        }
    }

    func updateSelectedTextEnabled(_ enabled: Bool) async {
        selectedTextEnabled = enabled
        if !enabled {
            preCapturedSelectedText = nil
        }
    }

    func updateActiveTextFieldEnabled(_ enabled: Bool) async {
        activeTextFieldEnabled = enabled
        if !enabled {
            preCapturedActiveTextField = nil
        }
    }
}

// MARK: - File Finalization Helper
extension DictationController {
    /// Waits until the file's size has remained unchanged for a short window,
    /// or until a timeout elapses. This helps avoid racing with AVAudioRecorder's
    /// final flush on some systems.
    static func waitUntilFileIsStable(_ url: URL, minStableMillis: Int = 50, timeoutSeconds: Double = 3.0) async {
        let fm = FileManager.default
        let pollInterval: useconds_t = 50_000 // 50 ms
        let minStable: useconds_t = useconds_t(minStableMillis) * 1000
        var lastSize: UInt64 = 0
        var stableFor: useconds_t = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        func currentSize() -> UInt64 {
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let n = attrs[.size] as? NSNumber {
                return n.uint64Value
            }
            return 0
        }

        lastSize = currentSize()
        while Date() < deadline {
            usleep(pollInterval)
            let s = currentSize()
            if s == lastSize {
                stableFor += pollInterval
                if stableFor >= minStable { break }
            } else {
                stableFor = 0
                lastSize = s
            }
        }
    }
}
