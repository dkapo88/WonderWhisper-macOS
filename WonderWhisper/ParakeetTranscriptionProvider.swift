import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
import OSLog

final class ParakeetTranscriptionProvider: TranscriptionProvider {
    // TDT backend (Parakeet Ultra, multilingual)
    private var asrManager: AsrManager?
    // Unified backend (Parakeet Unified 0.6B, English, offline batch)
    private var unifiedManager: UnifiedAsrManager? {
        // A fresh (or released) manager starts without vocabulary boosting.
        didSet { boostedTerms = [] }
    }
    // Vocabulary terms currently configured on `unifiedManager` (empty = none).
    private var boostedTerms: [String] = []
    private var modelsDirectory: URL
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Parakeet")
    // Idle unload after inactivity to balance memory and reliability
    private var idleUnloadTask: Task<Void, Never>?
    private let idleSeconds: TimeInterval = 300 // 5 minutes
    // Coalesce model loading to avoid duplicate work/logs
    private var loadTask: Task<Void, Error>?
    // Track which model is loaded to allow switching between Unified and Ultra
    private var loadedKind: ParakeetModelKind?

    // Raw mode: VoiceInk-style minimal processing (no preprocessing, no source hint, immediate cleanup)
    private var rawMode: Bool {
        (AppConfig.defaults.object(forKey: "parakeet.raw.mode") as? Bool) ?? false
    }

    // Whether `transcribe` may wait for the CTC vocabulary model to load.
    // Dictation never does (the first load can take seconds); recovery and
    // tests do, so their output is consistently boosted.
    private let waitsForVocabularyModel: Bool

    init(modelsDirectory: URL? = nil, waitsForVocabularyModel: Bool = false) {
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            // Prefer any discovered existing install
            self.modelsDirectory = ParakeetManager.effectiveModelsDirectory
        }
        self.waitsForVocabularyModel = waitsForVocabularyModel
    }

    // Public warm-up to preload models on recording start
    func warmUp() async {
        do {
            let kind = preferredKind()
            try await ensureModelsLoaded(kind: kind)
            if kind == .unified {
                // Load the CTC model and configure boosting while the user is
                // still speaking so the transcription after stop finds it ready.
                await applyVocabularyBoosting(
                    terms: ParakeetVocabularyBoosting.currentTerms(),
                    waitForModel: true
                )
            }
            scheduleIdleUnload()
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] warmUp failed: \(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            AppLog.dictation.error("[Parakeet] warmUp failed: domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            // Sleep for idle window; cancel will abort
            try? await Task.sleep(nanoseconds: UInt64(self.idleSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            let hadModels = (self.asrManager != nil) || (self.unifiedManager != nil)
            if hadModels {
                self.log.notice("[Parakeet] Idle timeout (\(Int(self.idleSeconds))s) — unloading models")
                AppLog.dictation.log("[Parakeet] idle unload")
            }
            if let mgr = self.asrManager {
                await mgr.cleanup()
                self.asrManager = nil
            }
            // UnifiedAsrManager releases its CoreML models when deallocated.
            self.unifiedManager = nil
            if hadModels { self.loadedKind = nil }
        }
    }

    private func isLoaded(_ kind: ParakeetModelKind) -> Bool {
        switch kind {
        case .unified: return unifiedManager != nil
        case .ultra: return asrManager != nil
        }
    }

    private func ensureModelsLoaded(kind: ParakeetModelKind) async throws {
        if loadedKind == kind, isLoaded(kind) {
            // Already loaded with the requested model
            return
        }
        if let t = loadTask {
            // If a load is in-flight, await it then re-check
            try await t.value
            if loadedKind == kind, isLoaded(kind) { return }
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            try await self.performModelLoad(kind: kind)
        }
        try await loadTask?.value
    }

    private func performModelLoad(kind: ParakeetModelKind) async throws {
        // Free the other backend to keep only one model resident in memory.
        await unloadOtherBackend(keeping: kind)
        switch kind {
        case .ultra:
            try await loadTdtModel(version: .ultra)
        case .unified:
            try await loadUnifiedModel()
        }
        loadedKind = kind
        scheduleIdleUnload()
    }

    private func unloadOtherBackend(keeping kind: ParakeetModelKind) async {
        if kind != .ultra, let mgr = asrManager {
            await mgr.cleanup()
            asrManager = nil
        }
        if kind != .unified {
            unifiedManager = nil
        }
    }

    private func loadTdtModel(version: AsrModelVersion) async throws {
        // Ultra is the only TDT model offered; FluidAudio places it canonically
        // under FluidAudio/Models/<Repo.folderName>.
        modelsDirectory = ParakeetManager.modelDirectory(for: .ultra)
        log.notice("[Parakeet] ensureModelsLoaded (ultra) dir=\(self.modelsDirectory.path, privacy: .public)")
        AppLog.dictation.log("[Parakeet] ensureModelsLoaded (ultra) dir=\(self.modelsDirectory.path)")
        let missing = ParakeetManager.missingFiles(ParakeetModelKind.ultra.requiredFiles, in: modelsDirectory)
        if !missing.isEmpty {
            // Not an error: downloadAndLoad fetches whatever is missing.
            log.notice("[Parakeet] ultra files missing=\(String(describing: missing), privacy: .public); downloading")
            AppLog.dictation.log("[Parakeet] ultra files missing=\(String(describing: missing)); downloading")
        }
        // Ultra ships a single int8 encoder build (no precision variants).
        let models = try await AsrModels.downloadAndLoad(version: version)
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(models)
        let available = await mgr.isAvailable
        log.notice("[Parakeet] manager available=\(available, privacy: .public)")
        AppLog.dictation.log("[Parakeet] manager available=\(available)")
        asrManager = mgr
    }

    private func loadUnifiedModel() async throws {
        let baseDir = ParakeetManager.modelsDirectory
        let unifiedDir = ParakeetManager.modelDirectory(for: .unified)
        log.notice("[Parakeet] ensureModelsLoaded (unified) dir=\(unifiedDir.path, privacy: .public)")
        AppLog.dictation.log("[Parakeet] ensureModelsLoaded (unified) dir=\(unifiedDir.path)")
        // int8 encoder (default): identical WER to fp16, half the download.
        let mgr = UnifiedAsrManager()
        // Downloads the "offline" (full-attention 15 s) variant if missing,
        // then loads it. `baseDir` is the FluidAudio/Models root; the manager
        // appends the repo folder itself.
        try await mgr.loadModels(to: baseDir)
        unifiedManager = mgr
        AppLog.dictation.log("[Parakeet] unified manager loaded")
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let kind = preferredKind(for: settings)
        try await ensureModelsLoaded(kind: kind)
        scheduleIdleUnload()
        switch kind {
        case .unified:
            await applyVocabularyBoosting(
                terms: settings.vocabularyTerms,
                waitForModel: waitsForVocabularyModel
            )
            // Turning boosting off reloads the manager; make sure one is resident.
            if unifiedManager == nil { try await ensureModelsLoaded(kind: .unified) }
            guard let mgr = unifiedManager else { throw ProviderError.notImplemented }
            return try await transcribeUnified(mgr: mgr, fileURL: fileURL)
        case .ultra:
            guard let mgr = asrManager else { throw ProviderError.notImplemented }
            return try await transcribeTdt(mgr: mgr, fileURL: fileURL, settings: settings)
        }
    }

    // MARK: - Vocabulary boosting (Unified only)

    /// Bring the Unified manager's vocabulary boosting in line with the
    /// Vocabulary list and the Settings toggle. Never throws: when the CTC model
    /// is missing (a background download starts), still loading and
    /// `waitForModel` is false, or configuring fails, the transcription simply
    /// runs without boosting.
    private func applyVocabularyBoosting(terms: [String], waitForModel: Bool) async {
        let desired = ParakeetVocabularyBoosting.termsToBoost(
            enabled: ParakeetVocabularyBoosting.isEnabled(),
            terms: terms
        )
        guard let mgr = unifiedManager, desired != boostedTerms else { return }

        if desired.isEmpty {
            // FluidAudio has no "disable boosting" call; drop the manager so
            // the next load starts clean.
            AppLog.dictation.log("[ParakeetVocab] boosting off; reloading Unified without it")
            unifiedManager = nil
            loadedKind = nil
            do {
                try await ensureModelsLoaded(kind: .unified)
            } catch {
                let message = (error as NSError).localizedDescription
                AppLog.dictation.error("[ParakeetVocab] Unified reload failed: \(message)")
            }
            return
        }

        let store = ParakeetCtcModelStore.shared
        let loaded = waitForModel ? await store.modelsIfAvailable() : await store.modelsIfLoaded()
        guard let ctcModels = loaded else {
            AppLog.dictation.log("[ParakeetVocab] CTC model not ready; transcribing without boosting")
            return
        }
        let started = Date()
        do {
            try await mgr.configureVocabularyBoosting(
                vocabulary: ParakeetVocabularyBoosting.vocabularyContext(for: desired),
                ctcModels: ctcModels
            )
            // Only record it if the manager wasn't swapped while we awaited.
            if mgr === unifiedManager { boostedTerms = desired }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.notice("[ParakeetVocab] boosting configured terms=\(desired.count, privacy: .public) in \(ms, privacy: .public)ms")
            AppLog.dictation.log("[ParakeetVocab] boosting configured terms=\(desired.count) in \(ms)ms")
        } catch {
            let message = (error as NSError).localizedDescription
            log.error("[ParakeetVocab] configure failed: \(message, privacy: .public)")
            AppLog.dictation.error("[ParakeetVocab] configure failed; transcribing without boosting: \(message)")
        }
    }

    /// Parakeet Unified offline-batch path: hand the recording to the
    /// FastConformer-RNNT manager via an `AVAudioPCMBuffer` (it resamples to
    /// 16 kHz mono itself and handles long-form windowing). We deliberately use
    /// the buffer API rather than a hand-rolled Float decode, which proved
    /// fragile (threw `_GenericObjCError`) on real recordings.
    private func transcribeUnified(mgr: UnifiedAsrManager, fileURL: URL) async throws -> String {
        AppLog.dictation.log("[Parakeet] Unified ASR begin file=\(fileURL.lastPathComponent)")
        let file = try AVAudioFile(forReading: fileURL)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            log.notice("[Parakeet] Unified: empty/invalid audio file frames=\(file.length, privacy: .public)")
            AppLog.dictation.log("[Parakeet] Unified: empty/invalid audio file")
            return ""
        }
        try file.read(into: buffer)
        let result: String
        do {
            result = try await mgr.transcribe(buffer)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] Unified transcribe error=\(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            AppLog.dictation.error("[Parakeet] Unified transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        let preview = result.prefix(120)
        log.notice("[Parakeet] Unified result length=\(result.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] Unified result length=\(result.count) preview=\(String(preview))")
        scheduleIdleUnload()
        return result
    }

    private func transcribeTdt(mgr: AsrManager, fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        
        // Raw mode: VoiceInk-style minimal processing path
        if rawMode {
            AppLog.dictation.log("[Parakeet] Raw mode enabled - using VoiceInk-style minimal processing")
            return try await transcribeRawMode(mgr: mgr, fileURL: fileURL)
        }

        AppLog.dictation.log("[Parakeet] ASR begin file=\(fileURL.lastPathComponent)")
        let result: ASRResult
        do {
            let decoderLayers = await mgr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            result = try await mgr.transcribe(
                fileURL,
                decoderState: &decoderState,
                language: Self.fluidLanguage(for: settings.language)
            )
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] mgr.transcribe error=\(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            AppLog.dictation.error("[Parakeet] transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        AppLog.dictation.log("[Parakeet] ASR done")
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] result length=\(result.text.count) preview=\(String(preview))")
        // Keep models warm for subsequent transcriptions to avoid re-initialization errors
        let text = result.text
        scheduleIdleUnload()
        return text
    }

    private static func fluidLanguage(for code: String?) -> Language? {
        guard let code else { return nil }
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty, normalized != "auto" else { return nil }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return Language(rawValue: primary)
    }

    // Determine preferred Parakeet model from settings or user defaults
    private func preferredKind(for settings: TranscriptionSettings? = nil) -> ParakeetModelKind {
        if let model = settings?.model.lowercased() {
            if model.contains("unified") { return .unified }
            if model.contains("ultra") { return .ultra }
            // v3 and v2 retired -> Ultra, the multilingual TDT successor
            if model.contains("v3") || model.contains("v2") { return .ultra }
        }
        return ParakeetModelKind.selected
    }

    private static func stats(samples: [Float]) -> (meanAbs: Double, peak: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum: Double = 0
        var peak: Double = 0
        for s in samples {
            let a = abs(Double(s))
            sum += a
            if a > peak { peak = a }
        }
        return (sum / Double(samples.count), peak)
    }

    // MARK: - Raw Mode (VoiceInk-style)
    
    /// Raw mode transcription: minimal processing like VoiceInk reference implementation
    /// - No preprocessing (no high-pass, no pre-emphasis, no RMS normalization)
    /// - No source hint parameter
    /// - Idle timeout (60s) instead of immediate cleanup (preserves rapid transcription support)
    /// - Simple WAV decoding starting at byte 44
    private func transcribeRawMode(mgr: AsrManager, fileURL: URL) async throws -> String {
        // Simple WAV decoding (VoiceInk-style)
        AppLog.dictation.log("[Parakeet] Raw mode: decoding audio")
        guard let samples = Self.decodeAudioRaw(url: fileURL) else {
            throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Raw mode: Failed to decode WAV audio"])
        }
        
        let stats = Self.stats(samples: samples)
        log.notice("[Parakeet] Raw mode samples=\(samples.count, privacy: .public) meanAbs=\(stats.meanAbs, format: .fixed(precision: 4)) peak=\(stats.peak, format: .fixed(precision: 4))")
        AppLog.dictation.log("[Parakeet] Raw mode: samples=\(samples.count) meanAbs=\(String(format: "%.4f", stats.meanAbs)) peak=\(String(format: "%.4f", stats.peak))")
        
        // Validate audio
        if samples.count < 16_000 {
            throw NSError(domain: "Parakeet", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Audio too short for ASR (need >= 1s)"])
        }
        if stats.meanAbs < 0.002 && stats.peak < 0.01 {
            throw NSError(domain: "Parakeet", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Audio appears near-silent; check microphone and input gain"])
        }
        
        // Raw mode always keeps the full capture; skip VAD entirely so long-form dictations stay intact
        var finalSamples = samples
        let audioDurationSeconds = Double(samples.count) / 16_000.0
        AppLog.dictation.log("[Parakeet] Raw mode: skipping VAD (duration: \(String(format: "%.1f", audioDurationSeconds))s)")
        
        if finalSamples.count + 16_000 <= 240_000 {
            finalSamples += [Float](repeating: 0, count: 16_000)
        }

        // Transcribe without source hint (VoiceInk-style for this pinned API)
        AppLog.dictation.log("[Parakeet] Raw mode: transcribing (no source hint)")
        let result: ASRResult
        do {
            let decoderLayers = await mgr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            result = try await mgr.transcribe(finalSamples, decoderState: &decoderState)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] Raw mode transcribe error=\(ns.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] Raw mode error: \(ns.localizedDescription)")
            throw error
        }
        
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] Raw mode result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] Raw mode: result length=\(result.text.count) preview=\(String(preview))")
        
        // Schedule idle unload instead of immediate cleanup
        // Immediate cleanup breaks subsequent transcriptions by de-initializing the manager
        // The idle timeout (60s) provides the same benefits without breaking rapid-fire transcriptions
        AppLog.dictation.log("[Parakeet] Raw mode: scheduling idle unload (\(Int(self.idleSeconds))s)")
        scheduleIdleUnload()
        
        return result.text
    }
    
    /// Simple WAV decoder for raw mode (VoiceInk-style)
    /// Reads from byte 44 onwards, converts Int16 to Float32
    private static func decodeAudioRaw(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count >= 44 else { return nil }
        
        // Basic WAV validation
        guard data[0...3] == Data([82, 73, 70, 70]) else { return nil }  // "RIFF"
        guard data[8...11] == Data([87, 65, 86, 69]) else { return nil }  // "WAVE"
        
        // Simple conversion: skip header, convert Int16 → Float32
        let samples: [Float] = stride(from: 44, to: data.count, by: 2).compactMap { offset in
            guard offset + 1 < data.count else { return nil }
            let bytes = data[offset..<offset + 2]
            let short = bytes.withUnsafeBytes { $0.load(as: Int16.self).littleEndian }
            let float = Float(short) / 32767.0
            return max(-1.0, min(float, 1.0))  // Clamp to [-1, 1]
        }
        
        return samples.isEmpty ? nil : samples
    }
}
#else
final class ParakeetTranscriptionProvider: TranscriptionProvider {
    init(modelsDirectory: URL? = nil, waitsForVocabularyModel: Bool = false) {}
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        throw ProviderError.notImplemented
    }
}
#endif
