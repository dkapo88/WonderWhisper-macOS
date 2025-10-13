import Foundation
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

    private var llmEnabled: Bool = true
    private var screenContextEnabled: Bool = true
    private var screenContextPreprocessingMode: ScreenContextPreprocessingMode = .off
    private var clipboardContextEnabled: Bool = false
    private var currentRecordingURL: URL?
    private var preCapturedScreenText: String?
    private var preCapturedScreenMethod: String?
    private var screenPreprocessingTask: Task<String?, Never>?
    private var preCapturedSelectedText: String?
    private var clipboardSnapshotForSession: String?
    private let clipboardMonitor = ClipboardContextMonitor()
    private let clipboardWindowSeconds: TimeInterval = 10



    private var screenOrganizePrompt: String = AppConfig.defaultScreenOrganizePrompt
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
    }

    func toggle(userPrompt: String) async {
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
                
                // Pre-capture screen context early (AX first, OCR fallback)
                preCapturedScreenText = nil
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
        // Stop live streaming if active
        if transcriber is AssemblyAIStreamingProvider { recorder.stopStreamingPCM16() }
        if transcriber is DeepgramStreamingProvider { recorder.stopStreamingPCM16() }
        if transcriber is GroqStreamingProvider { recorder.stopStreamingPCM16() }
        if transcriber is SonioxStreamingProvider { recorder.stopStreamingPCM16() }

        let recordingFileURL = await recorder.stopRecordingAndWait() // Always have file as backup

        let pipeId = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "WW.pipeline.total", signpostID: pipeId)

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
                AppLog.dictation.log("Transcription start (file) provider=\(String(describing: type(of: self.transcriber))) file=\(fileURL.lastPathComponent)")
                transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
            }
            let transcribeDT = Date().timeIntervalSince(t0)
            AppLog.dictation.log("Transcription done in \(transcribeDT, format: .fixed(precision: 3))s")
            // Cancel any in-flight screen organization to avoid post-stop work
            if let t = screenPreprocessingTask { t.cancel() }
            screenPreprocessingTask = nil

            os_signpost(.end, log: spLog, name: "WW.file.transcribe", signpostID: pipeId)

            var output = transcript
            var llmDT: TimeInterval = 0
            let selected = screenContextEnabled ? preCapturedSelectedText : nil
            var screenText: String? = nil
            var screenMethod: String? = nil
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil
            if llmEnabled {
                state = .processing
                var appNameForPrompt: String? = nil
                let (name, _) = screenContext.frontmostAppNameAndBundle()
                appNameForPrompt = name
                if screenContextEnabled {
                    // Use only pre-captured context; do not attempt any new gathering after stop
                    if let pre = preCapturedScreenText, !pre.isEmpty {
                        screenText = pre
                        screenMethod = preCapturedScreenMethod
                    } else {
                        screenText = nil
                        screenMethod = nil
                    }
                    if screenContextPreprocessingMode == .onDevice,
                       screenMethod == "OCR",
                       let raw = screenText,
                       let result = await performScreenPreprocessing(on: raw, context: "pipeline") {
                        screenText = result.0
                        screenMethod = result.1
                    }
                }
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    appName: appNameForPrompt,
                    screenContents: screenText,
                    customVocabulary: UserDefaults.standard.string(forKey: "vocab.custom"),
                    clipboardText: clipboardSnapshotForSession
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                AppLog.dictation.log("LLM processing start")
                os_signpost(.begin, log: spLog, name: "WW.llm.process", signpostID: pipeId)
                let t1 = Date()
                do {
                    output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
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
            await history?.append(
                fileURL: recordingFileURL ?? currentRecordingURL,
                appName: appNameHist,
                bundleID: bundleIDHist,
                transcript: transcript,
                output: output,
                screenContext: screenText,
                screenContextMethod: screenMethod,
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
            await history?.append(
                fileURL: recordingFileURL,
                appName: appNameHist,
                bundleID: bundleIDHist,
                transcript: "",
                output: "",
                screenContext: nil,
                screenContextMethod: nil,
                selectedText: screenContextEnabled ? screenContext.selectedText() : nil,
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
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        if let task = screenPreprocessingTask { task.cancel() }
        screenPreprocessingTask = nil
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
    func updateScreenContextPreprocessingMode(_ mode: ScreenContextPreprocessingMode) { self.screenContextPreprocessingMode = mode }
    func updateClipboardContextEnabled(_ enabled: Bool) {
        clipboardContextEnabled = enabled
        if !enabled {
            clipboardSnapshotForSession = nil
            Task { await clipboardMonitor.clear() }
        }
    }
    func updateScreenOrganizePrompt(_ prompt: String) { self.screenOrganizePrompt = prompt }

    func updateTranscriberProvider(_ p: TranscriptionProvider) { self.transcriber = p }
    func updateLLMProvider(_ p: LLMProvider) { self.llm = p }

    // Explicit controls for UI actions
    func finish(userPrompt: String) async {
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
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
        screenPreprocessingTask = nil
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
            streaming: streamingOverride ?? llmSettings.streaming
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
            let screenText = entry.screenContext
            let screenMethod = entry.screenContextMethod
            let appNameForPrompt = entry.appName
            
            if llmEnabled {
                state = .processing
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    appName: appNameForPrompt,
                    screenContents: screenText,
                    customVocabulary: UserDefaults.standard.string(forKey: "vocab.custom")
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                let t1 = Date()
                do {
                    output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
                } catch {
                    let ns = error as NSError
                    let isTransient = (ns.domain == NSURLErrorDomain) && (ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost || ns.code == NSURLErrorNotConnectedToInternet)
                    if AppConfig.llmEnableProviderFallback && isTransient {
                        AppLog.network.error("Primary LLM failed transiently; attempting provider fallback")
                        // Build a temporary fallback provider instance (try OpenRouter, then Groq)
                        let fallbackOrder: [(provider: String, endpoint: URL, factory: () -> LLMProvider)] = [
                            ("openrouter", AppConfig.openrouterChatCompletions, { OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) })) }),
                            ("groq", AppConfig.groqChatCompletions, { GroqLLMProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) })) })
                        ]
                        var success: String? = nil
                        for cand in fallbackOrder {
                            do {
                                let s = LLMSettings(endpoint: cand.endpoint, model: llmSettings.model, systemPrompt: llmSettings.systemPrompt, timeout: max(30, llmSettings.timeout), streaming: llmSettings.streaming)
                                success = try await cand.factory().process(text: userMsg, userPrompt: userPrompt, settings: s)
                                AppLog.network.log("LLM provider fallback succeeded with \(cand.provider)")
                                break
                            } catch {
                                AppLog.network.error("LLM provider fallback \(cand.provider) failed: \((error as NSError).localizedDescription)")
                            }
                        }
                        if let ok = success { output = ok } else { throw error }
                    } else {
                        throw error
                    }
                }
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
        // Try AX first as it's near-instant; fallback to OCR if needed
        // Capture selected text early (may wait briefly but happens during recording)
        if let sel = screenContext.selectedText(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.preCapturedSelectedText = sel
        }

        if let focused = screenContext.focusedText(), !focused.isEmpty {
            self.preCapturedScreenText = focused
            self.preCapturedScreenMethod = "AX"
            return
        }
        let ocr = await screenContext.captureActiveWindowText()
        self.preCapturedScreenText = ocr
        self.preCapturedScreenMethod = (ocr?.isEmpty ?? true) ? nil : "OCR"

        guard let ocrText = ocr,
              !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              screenContextPreprocessingMode != .off else {
            return
        }

        screenPreprocessingTask = Task { [ocrText, weak self] in
            guard let self else { return ocrText }
            if let (processed, method) = await self.performScreenPreprocessing(on: ocrText, context: "pre-capture") {
                await self.setPreprocessedScreenText(processed, method: method)
                return processed
            }
            return ocrText
        }
    }

    private func setPreprocessedScreenText(_ text: String, method: String) {
        self.preCapturedScreenText = text
        self.preCapturedScreenMethod = method
    }

    private func performScreenPreprocessing(on text: String, context: String) async -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch screenContextPreprocessingMode {
        case .off:
            return nil
        case .onDevice:
            guard let formatted = keywordExtractor.formattedKeywords(from: trimmed) else { return nil }
            return (formatted, "OCR-Keywords")
        case .llm:
            let orgSettings = LLMSettings(endpoint: llmSettings.endpoint,
                                          model: llmSettings.model,
                                          systemPrompt: nil,
                                          timeout: llmSettings.timeout,
                                          streaming: false)
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
}
