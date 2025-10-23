import Foundation
import AppKit
import OSLog
import os.signpost

actor DictationController {
    private let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Dictation-SP")
    enum State: Equatable { case idle, recording, transcribing, processing, inserting, error(String) }
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
    private var screenContextPreprocessingMode: ScreenContextPreprocessingMode = .off
    private var clipboardContextEnabled: Bool = false
    private var selectedTextEnabled: Bool = true
    private var currentRecordingURL: URL?
    private var preCapturedScreenSnapshot: ScreenCaptureSnapshot?
    private var preCapturedScreenText: String?
    private var preCapturedScreenMethod: String?
    private var preCapturedSelectedText: String?
    private var clipboardSnapshotForSession: String?
    private let clipboardMonitor = ClipboardContextMonitor()
    private let clipboardWindowSeconds: TimeInterval = 10



    private var screenOrganizePrompt: String = AppConfig.defaultScreenOrganizePrompt
    private var screenContextCaptureMode: ScreenContextCaptureMode = .image
    private let keywordExtractor = ScreenContentKeywordExtractor()

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

                // Always start file recording as backup for all providers
                // For Apple's native Speech provider, switch to a high-quality capture profile.
                if transcriber is NativeAppleTranscriptionProvider {
                    // Capture at 48 kHz float for better front‑end fidelity, then resample for ASR
                    recorder.captureProfile = .appleNativeHighQuality
                } else {
                    recorder.captureProfile = .standard16k
                }

                // Update state IMMEDIATELY after starting recording for instant UI feedback
                let url = try recorder.startRecording()
                state = .recording

                let recordingStart = Date()
                currentRecordingURL = url

                // If Parakeet is active, preload models in the background to hide cold-start latency
                if let pk = transcriber as? ParakeetTranscriptionProvider {
                    Task { await pk.warmUp() }
                }

                // If AssemblyAI v3 streaming is active, begin live session and stream mic frames
                if let aai = transcriber as? AssemblyAIStreamingProvider {
                    try await aai.beginRealtimeSession(sampleRate: 16_000)
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await aai.feedPCM16(data) }
                    }
                } else if let dg = transcriber as? DeepgramStreamingProvider {
                    try await dg.beginRealtime()
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await dg.feedPCM16(data) }
                    }
                } else if let groq = transcriber as? GroqStreamingProvider {
                    groq.updateSettings(transcriberSettings)
                    try await groq.beginRealtime()
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await groq.feedPCM16(data) }
                    }
                } else if let soniox = transcriber as? SonioxStreamingProvider {
                    try await soniox.beginRealtime(settings: transcriberSettings)
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await soniox.feedPCM16(data) }
                    }
                }

                // Pre-capture screen context early so it is ready once recording stops
                preCapturedScreenSnapshot = nil
                preCapturedScreenText = nil
                preCapturedScreenMethod = nil
                preCapturedSelectedText = nil
                clipboardSnapshotForSession = nil

                if llmEnabled && screenContextEnabled {
                    Task { await self.preCaptureScreenContext() }
                }
                if clipboardContextEnabled {
                    await clipboardMonitor.refreshSnapshot()
                    clipboardSnapshotForSession = await clipboardMonitor.consumeClipboardIfRecent(referenceDate: recordingStart, window: clipboardWindowSeconds)
                }
            } catch {
                AppLog.dictation.error("Recording start failed: \(error.localizedDescription)")
                state = .error("Recording start failed: \(error.localizedDescription)")
            }
        case .recording:
            await stopAndProcess(userPrompt: userPrompt)
        default:
            break
        }
    }

    private func stopAndProcess(userPrompt: String) async {
        guard state == .recording else { return }
        // Stop live streaming if active and abort any pending operations
        recorder.stopStreamingPCM16()
        if let aai = transcriber as? AssemblyAIStreamingProvider {
            await aai.abortRealtimeSession()
        } else if let dg = transcriber as? DeepgramStreamingProvider {
            await dg.abort()
        } else if let groq = transcriber as? GroqStreamingProvider {
            await groq.abort()
        } else if let soniox = transcriber as? SonioxStreamingProvider {
            await soniox.abort()
        }

        let recordingFileURL = await recorder.stopRecordingAndWait() // Always have file as backup

        let pipeId = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "WW.pipeline.total", signpostID: pipeId)

        let captureModeForSession: ScreenContextCaptureMode = {
            if preCapturedScreenSnapshot != nil { return .image }
            if preCapturedScreenText != nil { return .text }
            return screenContextCaptureMode
        }()

        do {
            let overallStart = Date()
            state = .transcribing
            let t0 = Date()
            var transcript: String = ""
            let hotkeySettings = TranscriptionSettings(endpoint: transcriberSettings.endpoint, model: transcriberSettings.model, timeout: transcriberSettings.timeout, context: "hotkey")

            os_signpost(.begin, log: spLog, name: "WW.file.transcribe", signpostID: pipeId)
            // Handle streaming providers first (prefer live, fallback to file if empty)
            if let aai = transcriber as? AssemblyAIStreamingProvider {
                // Prefer the live session's final transcript for speed
                transcript = try await aai.endRealtimeSessionAndGetTranscript()
                // If empty (fallback), run file-based for safety
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fileURL = recordingFileURL {
                    AppLog.dictation.log("Streaming fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let dg = transcriber as? DeepgramStreamingProvider {
                // Prefer Deepgram live session transcript gathered during recording
                transcript = try await dg.endRealtime()
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fileURL = recordingFileURL {
                    AppLog.dictation.log("Streaming fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let groq = transcriber as? GroqStreamingProvider {
                // Prefer Groq chunked streaming transcript for speed
                transcript = try await groq.endRealtime()
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fileURL = recordingFileURL {
                    AppLog.dictation.log("Streaming fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let soniox = transcriber as? SonioxStreamingProvider {
                transcript = try await soniox.endRealtime()
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fileURL = recordingFileURL {
                    AppLog.dictation.log("Streaming fallback to file transcription")
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else {
                // Standard file-based transcription for non-streaming providers
                guard let fileURL = recordingFileURL else { throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"]) }
                // Ensure the recorded file is fully finalized before reading to avoid rare
                // issues on some systems where the file appears complete but is still being flushed.
                await Self.waitUntilFileIsStable(fileURL)
                AppLog.dictation.log("Transcription start (file) provider=\(String(describing: type(of: self.transcriber))) file=\(fileURL.lastPathComponent)")
                transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
            }
            let transcribeDT = Date().timeIntervalSince(t0)
            AppLog.dictation.log("Transcription done in \(transcribeDT, format: .fixed(precision: 3))s")
            os_signpost(.end, log: spLog, name: "WW.file.transcribe", signpostID: pipeId)

            var output = transcript
            var llmDT: TimeInterval = 0
            let selected = (screenContextEnabled && selectedTextEnabled) ? preCapturedSelectedText : nil
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
                    switch captureModeForSession {
                    case .image:
                        if let snapshot = preCapturedScreenSnapshot {
                            screenAttachment = snapshot.asAttachment()
                            screenMethod = snapshot.method.rawValue
                            screenContentsForPrompt = makeScreenInstruction(from: snapshot, appName: appNameForPrompt)
                        }
                    case .text:
                        if let text = preCapturedScreenText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                            screenContentsForPrompt = text
                            screenMethod = preCapturedScreenMethod
                            let preprocessMode = screenContextPreprocessingMode
                            if preprocessMode != .off,
                               let processed = await preprocessScreenText(text, mode: preprocessMode, context: "pipeline") {
                                screenContentsForPrompt = processed.0
                                screenMethod = processed.1
                            }
                        }
                    }
                }
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    appName: appNameForPrompt,
                    screenContents: screenContentsForPrompt,
                    customVocabulary: UserDefaults.standard.string(forKey: "vocab.custom"),
                    clipboardText: clipboardSnapshotForSession
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                AppLog.dictation.log("LLM processing start")
                os_signpost(.begin, log: spLog, name: "WW.llm.process", signpostID: pipeId)
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
                    os_signpost(.end, log: spLog, name: "WW.llm.process", signpostID: pipeId)
                } catch {
                    let ns = error as NSError
                    AppLog.dictation.error("LLM error: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code)")
                    // Fallback to raw transcript on LLM failure
                    output = transcript
                    llmDT = 0
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
            os_signpost(.begin, log: spLog, name: "WW.insert.total", signpostID: pipeId)
            inserter.insert(output)
            os_signpost(.end, log: spLog, name: "WW.insert.total", signpostID: pipeId)

            state = .idle

            // Record history entry
            var appNameHist: String? = nil
            var bundleIDHist: String? = nil
            let pair = screenContext.frontmostAppNameAndBundle()
            appNameHist = pair.0
            bundleIDHist = screenContextEnabled ? pair.1 : nil
            let totalDT = Date().timeIntervalSince(overallStart)
            let imageForHistory = captureModeForSession == .image ? preCapturedScreenSnapshot : nil
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
            AppLog.dictation.error("Pipeline error: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            os_signpost(.end, log: spLog, name: "WW.pipeline.total", signpostID: pipeId)
            // Persist audio so the user can reprocess later even on failure
            var appNameHist: String? = nil
            var bundleIDHist: String? = nil
            let pair = screenContext.frontmostAppNameAndBundle()
            appNameHist = pair.0
            bundleIDHist = screenContextEnabled ? pair.1 : nil
            let imageForHistory = captureModeForSession == .image ? preCapturedScreenSnapshot : nil
            let textForHistory = (captureModeForSession == .text) ? preCapturedScreenText : nil
            // Capture selected text dynamically for error case (preCapturedSelectedText may not be set)
            let selectedTextForHistory: String? = {
                guard screenContextEnabled && selectedTextEnabled else { return nil }
                if let cached = preCapturedSelectedText, !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return cached
                }
                if let sel = screenContext.selectedText(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return sel
                }
                return nil
            }()
            await history?.append(
                fileURL: recordingFileURL,
                appName: appNameHist,
                bundleID: bundleIDHist,
                transcript: "",
                output: "",
                screenContext: textForHistory,
                screenContextMethod: (captureModeForSession == .text) ? preCapturedScreenMethod : imageForHistory?.method.rawValue,
                screenImage: captureModeForSession == .image ? preCapturedScreenSnapshot : nil,
                selectedText: selectedTextForHistory,
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
        // Reset pre-captured context for the next run
        preCapturedScreenSnapshot = nil
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        clipboardSnapshotForSession = nil
        // Restore capture profile to default for subsequent runs
        recorder.captureProfile = .standard16k
        os_signpost(.end, log: spLog, name: "WW.pipeline.total", signpostID: pipeId)
    }

    func currentState() -> State { state }

    func updateTranscriberSettings(_ s: TranscriptionSettings) { self.transcriberSettings = s }
    func updateLLMSettings(_ s: LLMSettings) { self.llmSettings = s }
    func updateLLMEnabled(_ enabled: Bool) { self.llmEnabled = enabled }
    func updateScreenContextEnabled(_ enabled: Bool) { self.screenContextEnabled = enabled }
    func updateScreenContextCaptureMode(_ mode: ScreenContextCaptureMode) { self.screenContextCaptureMode = mode }
    func updateScreenContextPreprocessingMode(_ mode: ScreenContextPreprocessingMode) { self.screenContextPreprocessingMode = mode }
    func updateClipboardContextEnabled(_ enabled: Bool) {
        clipboardContextEnabled = enabled
        if !enabled {
            clipboardSnapshotForSession = nil
            Task { await clipboardMonitor.clear() }
        }
    }
    func updateScreenOrganizePrompt(_ prompt: String) { self.screenOrganizePrompt = prompt }

    func clearConversationHistory(for promptID: UUID) {
        conversationHistoryStore.clearHistory(for: promptID)
        AppLog.dictation.log("Cleared conversation history for prompt \(promptID)")
    }

    func updateTranscriberProvider(_ p: TranscriptionProvider) { self.transcriber = p }
    func updateLLMProvider(_ p: LLMProvider) { self.llm = p }

    // Explicit controls for UI actions
    func finish(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
        self.currentPrompt = activePrompt
        await stopAndProcess(userPrompt: userPrompt)
    }

    func cancel() async {
        // Cancel only applies to active recording; do not emit any output or history
        guard state == .recording else { return }
        // Stop live mic streaming if active
        recorder.stopStreamingPCM16()
        // Abort any active streaming provider sessions immediately (best-effort)
        if let aai = transcriber as? AssemblyAIStreamingProvider {
            await aai.abortRealtimeSession()
        } else if let dg = transcriber as? DeepgramStreamingProvider {
            await dg.abort()
        } else if let groq = transcriber as? GroqStreamingProvider {
            await groq.abort()
        } else if let soniox = transcriber as? SonioxStreamingProvider {
            await soniox.abort()
        }
        // Stop file recording and delete any created file
        _ = recorder.stopRecording()
        if let url = currentRecordingURL { try? FileManager.default.removeItem(at: url) }
        currentRecordingURL = nil
        // Reset any pre-captured context
        preCapturedScreenSnapshot = nil
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        clipboardSnapshotForSession = nil
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
            temperature: llmSettings.temperature
        )
        return try await llm.process(text: text, userPrompt: userPrompt, settings: settings)
    }

    func reprocess(entry: HistoryEntry, userPrompt: String) async {
        guard let history = history, let url = await history.audioURL(for: entry) else { return }
        do {
            state = .transcribing
            let overallStart = Date()
            let t0 = Date()
            let reprocSettings = TranscriptionSettings(endpoint: transcriberSettings.endpoint, model: transcriberSettings.model, timeout: transcriberSettings.timeout, context: "reprocess")
            let transcript = try await transcriber.transcribe(fileURL: url, settings: reprocSettings)
            let transcribeDT = Date().timeIntervalSince(t0)
            var output = transcript
            var llmDT: TimeInterval = 0
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil

            // Use original context from history entry instead of fetching new context
            let selected = entry.selectedText
            let screenInstruction = entry.screenContext
            let appNameForPrompt = entry.appName
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
                    appName: appNameForPrompt,
                    screenContents: screenInstruction,
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
    private func preCaptureScreenContext() async {
        if !screenContextEnabled { return }

        if selectedTextEnabled, let sel = screenContext.selectedText(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.preCapturedSelectedText = sel
        }

        switch screenContextCaptureMode {
        case .image:
            let snapshot = await screenContext.captureActiveWindowImage()
            self.preCapturedScreenSnapshot = snapshot
            self.preCapturedScreenText = nil
            self.preCapturedScreenMethod = snapshot?.method.rawValue
        case .text:
            self.preCapturedScreenSnapshot = nil
            self.preCapturedScreenText = nil
            self.preCapturedScreenMethod = nil

            if let focused = screenContext.focusedText(), !focused.isEmpty {
                self.preCapturedScreenText = focused
                self.preCapturedScreenMethod = "AX"
                return
            }

            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let isCodeEditor = [
                "com.cursorai.cursor",
                "com.todesktop.cursor",
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.apple.dt.Xcode",
                "com.jetbrains"
            ].contains(where: { frontBundle.hasPrefix($0) })
            let isBrowser = [
                "com.apple.Safari",
                "com.google.Chrome",
                "org.mozilla.firefox",
                "com.microsoft.edgemac",
                "com.operasoftware.Opera"
            ].contains(where: { frontBundle.hasPrefix($0) })
            let forceAccurate = UserDefaults.standard.bool(forKey: "ocr.forceAccurate")
            let preferAccurate = forceAccurate || isCodeEditor || isBrowser

            if let text = await screenContext.captureActiveWindowText(preferAccurate: preferAccurate) {
                let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.preCapturedScreenText = trimmed
                    self.preCapturedScreenMethod = "OCR"
                }
            }
        }
    }

    private func makeScreenInstruction(from snapshot: ScreenCaptureSnapshot, appName: String?) -> String {
        var intro = "Attached image captures the "
        switch snapshot.method {
        case .window:
            intro += "active window"
        case .display:
            intro += "current screen"
        }
        if let appName, !appName.isEmpty {
            intro += " in \(appName)."
        } else {
            intro += "."
        }

        let guidance = "Use it to match layout, correct names, and interpret on-screen context."
        let resolution = "Resolution: \(snapshot.width)x\(snapshot.height) pixels."
        return "\(intro) \(guidance) \(resolution)"
    }

    private func preprocessScreenText(_ text: String, mode: ScreenContextPreprocessingMode, context: String) async -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch mode {
        case .off:
            return nil
        case .onDevice:
            guard let formatted = keywordExtractor.formattedKeywords(from: trimmed) else { return nil }
            return (formatted, "OCR-Keywords")
        case .llm:
            let orgSettings = LLMSettings(
                endpoint: llmSettings.endpoint,
                model: llmSettings.model,
                systemPrompt: nil,
                timeout: llmSettings.timeout,
                streaming: false,
                temperature: llmSettings.temperature
            )
            do {
                let organized = try await llm.process(text: trimmed, userPrompt: screenOrganizePrompt, settings: orgSettings)
                let output = organized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty else { return nil }
                return (output, "OCR-Organized")
            } catch {
                if error is CancellationError {
                    AppLog.dictation.log("Screen preprocessing (\(context)) cancelled")
                } else {
                    AppLog.dictation.error("Screen preprocessing (\(context)) failed: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }
    func updateSelectedTextEnabled(_ enabled: Bool) async {
        selectedTextEnabled = enabled
        if !enabled {
            preCapturedSelectedText = nil
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
