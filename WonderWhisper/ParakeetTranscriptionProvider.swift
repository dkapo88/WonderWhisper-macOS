import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
import OSLog

actor ParakeetTranscriptionProvider: TranscriptionProvider {
    /// A loaded backend, as returned by a test `BackendLoader`.
    enum LoadedBackend: Sendable {
        case unified(UnifiedAsrManager)
        case ultra(AsrManager)
    }
    typealias BackendLoader = @Sendable (ParakeetModelKind) async throws -> LoadedBackend
    /// Test seam: stands in for the silent prewarm decode (nil in production).
    typealias PrewarmRunner = @Sendable (ParakeetModelKind) async -> Void

    /// How long a loaded model stays in memory.
    enum Residency: Sendable, Equatable {
        /// Unload after this many idle seconds (meeting recovery, one-off fallbacks).
        case idleUnload(TimeInterval)
        /// Dictation: stay loaded while the engine is selected; unload when it is deselected or
        /// the system reports memory pressure.
        case whileSelected
    }

    /// Key-down prewarms when the model has not run for longer than this.
    static let idlePrewarmThreshold: TimeInterval = 120

    // TDT backend (Parakeet Ultra, multilingual)
    private var asrManager: AsrManager?
    // Unified backend (Parakeet Unified 0.6B, English, offline batch)
    private var unifiedManager: UnifiedAsrManager? {
        didSet {
            // Drop boosting bookkeeping for a released manager.
            if let old = oldValue, old !== unifiedManager {
                let boosting = self.boosting
                Task { await boosting.forget(old) }
            }
        }
    }
    // Serializes vocabulary configuration with Unified inference (see
    // ParakeetBoostingCoordinator for the invariants).
    private let boosting = ParakeetBoostingCoordinator<UnifiedAsrManager>(
        configure: { manager, terms in
            // Only reached once the CTC model reported ready (or, for an
            // empty "neutralize" call, after a previous successful boost).
            guard let ctcModels = await ParakeetCtcModelStore.shared.modelsIfLoaded() else {
                throw ParakeetVocabularyBoostingError.ctcModelNotLoaded
            }
            try await manager.configureVocabularyBoosting(
                vocabulary: ParakeetVocabularyBoosting.vocabularyContext(for: terms),
                ctcModels: ctcModels
            )
        },
        ctcReady: { wait in
            let store = ParakeetCtcModelStore.shared
            return wait ? await store.modelsIfAvailable() != nil : await store.modelsIfLoaded() != nil
        },
        log: { AppLog.dictation.log("[ParakeetVocab] \($0)") }
    )
    // An unboosted Unified manager loading in the background after boosting
    // was turned off; swapped in only once loaded.
    private var replacementTask: Task<Void, Never>?
    private let boostingEnabled: @Sendable () -> Bool
    private let vocabularyTerms: @Sendable () -> [String]
    private var modelsDirectory: URL
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Parakeet")
    // Idle unload after inactivity (`.idleUnload`, or `.whileSelected` while not selected).
    private var idleUnloadTask: Task<Void, Never>?
    private let residency: Residency
    private var idleSeconds: TimeInterval {
        if case .idleUnload(let seconds) = residency { return seconds }
        return 300
    }
    // Dictation residency (`.whileSelected`). Every unload bumps `residencyGeneration`; a
    // background load or prewarm that started under an older generation never keeps the
    // engine loaded.
    private var isSelected = false
    private var memoryPressureHold = false
    private var residencyGeneration = 0
    private var preloadTask: Task<Void, Never>?
    private var preloadKey: (generation: Int, kind: ParakeetModelKind)?
    private var prewarmTask: Task<Void, Never>?
    private(set) var lastInferenceAt: TimeInterval?
    private var lastUnloadAt: TimeInterval?
    private let padsInput: Bool
    private let isInstalled: @Sendable (ParakeetModelKind) -> Bool
    private let prewarmRunner: PrewarmRunner?
    // Coalesce model loading to avoid duplicate work/logs. `loadGeneration`
    // identifies the registered load so only its owner clears it.
    private var loadTask: Task<Void, Error>?
    private var loadGeneration = 0
    // Test seam: replaces the real model loads (nil in production).
    private let backendLoader: BackendLoader?
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

    /// - Parameters:
    ///   - residency: dictation uses `.whileSelected`; everything else unloads when idle.
    ///   - padsInput: pad audio with trailing silence before decoding (dictation only; see
    ///     `ParakeetInputPadding`).
    init(
        modelsDirectory: URL? = nil,
        waitsForVocabularyModel: Bool = false,
        residency: Residency = .idleUnload(300),
        padsInput: Bool = false,
        boostingEnabled: @escaping @Sendable () -> Bool = { ParakeetVocabularyBoosting.isEnabled() },
        vocabularyTerms: @escaping @Sendable () -> [String] = { ParakeetVocabularyBoosting.currentTerms() },
        isInstalled: @escaping @Sendable (ParakeetModelKind) -> Bool = { kind in
            ParakeetManager.missingFiles(kind.requiredFiles, in: ParakeetManager.modelDirectory(for: kind)).isEmpty
        },
        backendLoader: BackendLoader? = nil,
        prewarmRunner: PrewarmRunner? = nil
    ) {
        self.backendLoader = backendLoader
        self.residency = residency
        self.padsInput = padsInput
        self.isInstalled = isInstalled
        self.prewarmRunner = prewarmRunner
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            // Prefer any discovered existing install
            self.modelsDirectory = ParakeetManager.effectiveModelsDirectory
        }
        self.waitsForVocabularyModel = waitsForVocabularyModel
        self.boostingEnabled = boostingEnabled
        self.vocabularyTerms = vocabularyTerms
    }

    /// Terms to boost right now, from the injected preferences.
    private nonisolated func currentTermsToBoost() -> [String] {
        ParakeetVocabularyBoosting.termsToBoost(enabled: boostingEnabled(), terms: vocabularyTerms())
    }

    // Public warm-up to preload models on recording start (key-down). Loads the model if it is
    // not resident and prewarms it when it has not run for `idlePrewarmThreshold`, alongside
    // capture.
    /// - Parameter requestedAt: when the dictation that wants this warm-up started (uptime). A
    ///   warm-up requested before the latest unload is stale and does nothing.
    func warmUp(requestedAt: TimeInterval? = nil) async {
        // A dictation engine that is no longer selected (a warm-up queued before an engine
        // switch) never loads in the background; a real transcription still can.
        if residency == .whileSelected, !isSelected { return }
        if let requestedAt, let lastUnloadAt, requestedAt < lastUnloadAt { return }
        memoryPressureHold = false
        let generation = residencyGeneration
        do {
            let kind = preferredKind()
            let wasResident = isResident()
            try await ensureModelsLoaded(kind: kind)
            // Deselected or under memory pressure while this load ran: never keep the engine.
            if residency == .whileSelected, generation != residencyGeneration, !isSelected || memoryPressureHold {
                await unloadModels(reason: "late warm-up load")
                return
            }
            if !wasResident || isIdle(now: DictationClock.now()) {
                await prewarm(generation: generation)
            }
            if kind == .unified, let mgr = unifiedManager {
                // Load the CTC model and configure boosting while the user is
                // still speaking. Preferences are re-read after the (slow) CTC
                // load, and the result is dropped if a transcription ran first.
                let outcome = await boosting.prepare(mgr) { [self] in currentTermsToBoost() }
                handleBoostingOutcome(outcome, manager: mgr)
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
        idleUnloadTask = nil
        // A selected dictation engine stays resident until deselected or memory pressure.
        if residency == .whileSelected, isSelected, !memoryPressureHold { return }
        idleUnloadTask = Task { [weak self, idleSeconds] in
            // Sleep for idle window; cancel will abort
            try? await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.performIdleUnload()
        }
    }

    private func performIdleUnload() async {
        await unloadModels(reason: "idle timeout \(Int(idleSeconds))s")
    }

    /// Releases both backends. Bumps the residency generation first, so any background load or
    /// prewarm already in flight cannot keep or bring back the engine.
    private func unloadModels(reason: String) async {
        residencyGeneration += 1
        lastUnloadAt = DictationClock.now()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        let hadModels = (asrManager != nil) || (unifiedManager != nil)
        if hadModels {
            log.notice("[Parakeet] Unloading models: \(reason, privacy: .public)")
            AppLog.dictation.log("[Parakeet] unload reason=\(reason, privacy: .public)")
        }
        // UnifiedAsrManager releases its CoreML models when deallocated.
        unifiedManager = nil
        if hadModels { loadedKind = nil }
        await releaseUltraManager()
    }

    /// Detaches the Ultra manager, then cleans it up under the coordinator lock: an Ultra decode
    /// in flight holds that lock, so cleanup waits for it instead of pulling the models from
    /// under it.
    private func releaseUltraManager() async {
        guard let mgr = asrManager else { return }
        asrManager = nil
        await boosting.exclusive { await mgr.cleanup() }
    }

    // MARK: - Dictation residency

    /// Selected: load the chosen backend in the background (coalesced) and run one silent
    /// prewarm after loading. Deselected: unload. Also re-run after a Unified/Ultra change.
    func setSelected(_ selected: Bool) async {
        guard residency == .whileSelected else { return }
        let wasSelected = isSelected
        isSelected = selected
        if selected {
            ensureResidentInBackground()
        } else if wasSelected {
            preloadTask = nil
            preloadKey = nil
            await unloadModels(reason: "engine deselected")
        }
    }

    /// System memory-pressure warning: drop the model. The next dictation loads it again.
    func handleMemoryPressure() async {
        guard residency == .whileSelected else { return }
        memoryPressureHold = true
        preloadTask = nil
        preloadKey = nil
        await unloadModels(reason: "memory pressure")
    }

    private func ensureResidentInBackground() {
        guard isSelected, !memoryPressureHold else { return }
        let kind = preferredKind()
        let generation = residencyGeneration
        if preloadTask != nil, let key = preloadKey, key.generation == generation, key.kind == kind {
            return // already loading this backend for this generation
        }
        preloadKey = (generation, kind)
        preloadTask = Task { [weak self] in
            await self?.runPreload(kind: kind, generation: generation)
        }
    }

    private func runPreload(kind: ParakeetModelKind, generation: Int) async {
        defer {
            if let key = preloadKey, key.generation == generation, key.kind == kind {
                preloadTask = nil
                preloadKey = nil
            }
        }
        guard isInstalled(kind) else {
            AppLog.dictation.log("[Parakeet] background load skipped: \(kind.rawValue, privacy: .public) not installed")
            return
        }
        let wasResident = loadedKind == kind && isLoaded(kind)
        let started = DictationClock.now()
        do {
            try await ensureModelsLoaded(kind: kind)
        } catch {
            AppLog.dictation.error("[Parakeet] background load failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard generation == residencyGeneration, isSelected, !memoryPressureHold else {
            // Deselected or under memory pressure while loading: never bring the engine back.
            if !isSelected || memoryPressureHold {
                await unloadModels(reason: "late background load")
            }
            return
        }
        if !wasResident {
            let loadMs = Int((DictationClock.now() - started) * 1_000)
            AppLog.dictation.log("[Parakeet] background load done kind=\(kind.rawValue, privacy: .public) loadMs=\(loadMs, privacy: .public)")
            await prewarm(generation: generation)
        }
    }

    private func isIdle(now: TimeInterval) -> Bool {
        guard let lastInferenceAt else { return true }
        return now - lastInferenceAt > Self.idlePrewarmThreshold
    }

    /// One silent decode on the resident backend, coalesced, and serialised with real decoding
    /// through the boosting coordinator. Skipped if an unload happened since `generation`.
    private func prewarm(generation: Int) async {
        if let inFlight = prewarmTask {
            await inFlight.value
            return
        }
        let task = Task { await self.runPrewarm(generation: generation) }
        prewarmTask = task
        await task.value
        prewarmTask = nil
    }

    private func runPrewarm(generation: Int) async {
        guard generation == residencyGeneration, let kind = loadedKind, isLoaded(kind) else { return }
        let started = DictationClock.now()
        let runner = prewarmRunner
        switch kind {
        case .unified:
            guard let mgr = unifiedManager else { return }
            await boosting.exclusive {
                if let runner { await runner(kind); return }
                guard let buffer = Self.silentPrewarmBuffer() else { return }
                _ = try? await mgr.transcribe(buffer)
            }
        case .ultra:
            guard let mgr = asrManager else { return }
            await boosting.exclusive {
                if let runner { await runner(kind); return }
                guard let buffer = Self.silentPrewarmBuffer() else { return }
                var state = TdtDecoderState.make(decoderLayers: await mgr.decoderLayerCount)
                _ = try? await mgr.transcribe(buffer, decoderState: &state, language: nil)
            }
        }
        lastInferenceAt = DictationClock.now()
        let prewarmMs = Int((DictationClock.now() - started) * 1_000)
        AppLog.dictation.log("[Parakeet] prewarm done kind=\(kind.rawValue, privacy: .public) prewarmMs=\(prewarmMs, privacy: .public)")
    }

    /// One second of digital silence at 16 kHz.
    private static func silentPrewarmBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
              let samples = buffer.floatChannelData?[0] else { return nil }
        for index in 0..<16_000 { samples[index] = 0 }
        buffer.frameLength = 16_000
        return buffer
    }

    var isSelectedForTesting: Bool { isSelected }

    func prewarmForTesting() async {
        await prewarm(generation: residencyGeneration)
    }

    func waitForBackgroundWorkForTesting() async {
        for _ in 0..<10 {
            guard let task = preloadTask ?? prewarmTask else { return }
            await task.value
        }
    }

    func setLastInferenceForTesting(_ uptime: TimeInterval?) {
        lastInferenceAt = uptime
    }

    /// Whether the model a transcription with `settings` would use is loaded right now.
    func isResident(for settings: TranscriptionSettings? = nil) -> Bool {
        let kind = preferredKind(for: settings)
        return loadedKind == kind && isLoaded(kind)
    }

    private func isLoaded(_ kind: ParakeetModelKind) -> Bool {
        switch kind {
        case .unified: return unifiedManager != nil
        case .ultra: return asrManager != nil
        }
    }

    /// Load `kind` unless it is resident. Loads are coalesced and never run
    /// concurrently: a caller that finds a load in flight (of either kind)
    /// waits for it and re-checks from the top, since another waiter may have
    /// registered a newer load meanwhile. Each load clears `loadTask` itself,
    /// and only if it is still the registered one, so an older caller resuming
    /// late can never erase a newer load.
    private func ensureModelsLoaded(kind: ParakeetModelKind) async throws {
        while true {
            if loadedKind == kind, isLoaded(kind) { return }
            if let inFlight = loadTask {
                // Another load's failure is not ours; re-check and, if still
                // needed, start our own.
                _ = try? await inFlight.value
                continue
            }
            loadGeneration += 1
            let generation = loadGeneration
            let task = Task {
                do {
                    try await self.performModelLoad(kind: kind)
                } catch {
                    self.finishLoad(generation: generation)
                    throw error
                }
                self.finishLoad(generation: generation)
            }
            loadTask = task
            try await task.value
            return
        }
    }

    /// Clear `loadTask` only if it still belongs to `generation`.
    private func finishLoad(generation: Int) {
        if loadGeneration == generation { loadTask = nil }
    }

    private func performModelLoad(kind: ParakeetModelKind) async throws {
        // Free the other backend to keep only one model resident in memory.
        await unloadOtherBackend(keeping: kind)
        if let backendLoader {
            switch try await backendLoader(kind) {
            case .unified(let manager): unifiedManager = manager
            case .ultra(let manager): asrManager = manager
            }
        } else {
            switch kind {
            case .ultra:
                try await loadTdtModel(version: .ultra)
            case .unified:
                try await loadUnifiedModel()
            }
        }
        loadedKind = kind
        scheduleIdleUnload()
    }

    private func unloadOtherBackend(keeping kind: ParakeetModelKind) async {
        if kind != .ultra {
            await releaseUltraManager()
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
            guard let mgr = unifiedManager else { throw ProviderError.notImplemented }
            let desired = ParakeetVocabularyBoosting.termsToBoost(
                enabled: boostingEnabled(),
                terms: settings.vocabularyTerms
            )
            if waitsForVocabularyModel, !desired.isEmpty {
                // Off the dictation path: wait for the CTC model outside the
                // coordinator's critical section.
                _ = await ParakeetCtcModelStore.shared.modelsIfAvailable()
            }
            // Boosting is aligned and inference runs with no configuration able
            // to interleave. Boosting never throws or reloads ASR here; only
            // the decode itself can fail.
            let (text, outcome) = try await boosting.run(on: mgr, desired: desired) {
                try await self.transcribeUnified(mgr: mgr, fileURL: fileURL)
            }
            lastInferenceAt = DictationClock.now()
            handleBoostingOutcome(outcome, manager: mgr)
            return text
        case .ultra:
            guard let mgr = asrManager else { throw ProviderError.notImplemented }
            // Serialised with the prewarm decode, which goes through the same lock.
            let text = try await boosting.exclusiveThrowing {
                try await self.transcribeTdt(mgr: mgr, fileURL: fileURL, settings: settings)
            }
            lastInferenceAt = DictationClock.now()
            return text
        }
    }

    // MARK: - Vocabulary boosting (Unified only)

    private func handleBoostingOutcome(
        _ outcome: ParakeetBoostingCoordinator<UnifiedAsrManager>.Outcome,
        manager: UnifiedAsrManager
    ) {
        switch outcome {
        case .configured(let terms):
            log.notice("[ParakeetVocab] boosting configured terms=\(terms.count, privacy: .public)")
            AppLog.dictation.log("[ParakeetVocab] boosting configured terms=\(terms.count)")
        case .neutralized:
            scheduleUnboostedReplacement(for: manager)
        case .unchanged, .skipped, .stale:
            break
        }
    }

    /// After boosting is turned off, a neutralized manager still runs a CTC
    /// pass per transcription. Load a clean manager in the background and swap
    /// it in only once it has loaded and boosting is still off. Dictation keeps
    /// using the neutralized manager meanwhile; a failed load changes nothing.
    private func scheduleUnboostedReplacement(for old: UnifiedAsrManager) {
        guard replacementTask == nil else { return }
        let boosting = self.boosting
        replacementTask = Task { [weak self] in
            let fresh = UnifiedAsrManager()
            do {
                try await fresh.loadModels(to: ParakeetManager.modelsDirectory)
            } catch {
                AppLog.dictation.error(
                    "[ParakeetVocab] unboosted replacement failed to load: \(error.localizedDescription)"
                )
                await self?.finishReplacement()
                return
            }
            // Under the coordinator lock no configuration can change `old`, so
            // its neutral state read here still holds at commit time. The
            // commit itself is one synchronous actor step that rechecks the
            // backend; backend loads don't take this lock.
            guard let provider = self else { return }
            let swapped = await boosting.exclusive { () -> Bool in
                let oldIsNeutral = await boosting.configuredTerms(of: old) == []
                return await provider.commitReplacement(old: old, fresh: fresh, oldIsNeutral: oldIsNeutral)
            }
            AppLog.dictation.log("[ParakeetVocab] unboosted replacement swapped=\(swapped)")
            await provider.finishReplacement()
        }
    }

    private func finishReplacement() {
        replacementTask = nil
    }

    /// Install `fresh` in place of `old` only if, at this exact moment, `old`
    /// is still the resident Unified manager, Unified is the active backend,
    /// no backend load is in flight, `old` is neutralized and boosting is
    /// still off. Synchronous: nothing can interleave between the checks and
    /// the assignment.
    func commitReplacement(
        old: UnifiedAsrManager,
        fresh: UnifiedAsrManager,
        oldIsNeutral: Bool
    ) -> Bool {
        guard oldIsNeutral,
              loadTask == nil,
              loadedKind == .unified,
              unifiedManager === old,
              asrManager == nil,
              currentTermsToBoost().isEmpty else { return false }
        unifiedManager = fresh
        return true
    }

    // MARK: - Test support

    /// Install a Unified manager as the active backend without loading models.
    func installUnifiedForTesting(_ manager: UnifiedAsrManager?) {
        unifiedManager = manager
        loadedKind = manager == nil ? nil : .unified
    }

    /// Mimic `performModelLoad(kind: .ultra)`'s effect on Unified state.
    func simulateSwitchToUltraForTesting() {
        unifiedManager = nil
        loadedKind = .ultra
    }

    var residentUnifiedManagerForTesting: UnifiedAsrManager? { unifiedManager }

    func ensureModelsLoadedForTesting(_ kind: ParakeetModelKind) async throws {
        try await ensureModelsLoaded(kind: kind)
    }

    var loadedKindForTesting: ParakeetModelKind? { loadedKind }


    /// Parakeet Unified offline-batch path: hand the recording to the
    /// FastConformer-RNNT manager via an `AVAudioPCMBuffer` (it resamples to
    /// 16 kHz mono itself and handles long-form windowing). We deliberately use
    /// the buffer API rather than a hand-rolled Float decode, which proved
    /// fragile (threw `_GenericObjCError`) on real recordings.
    private func transcribeUnified(mgr: UnifiedAsrManager, fileURL: URL) async throws -> String {
        AppLog.dictation.log("[Parakeet] Unified ASR begin file=\(fileURL.lastPathComponent)")
        let buffer: AVAudioPCMBuffer
        if padsInput {
            guard let padded = try ParakeetInputPadding.paddedBuffer(contentsOf: fileURL) else {
                AppLog.dictation.log("[Parakeet] Unified: empty/invalid audio file")
                return ""
            }
            buffer = padded
        } else {
            let file = try AVAudioFile(forReading: fileURL)
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let unpadded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                log.notice("[Parakeet] Unified: empty/invalid audio file frames=\(file.length, privacy: .public)")
                AppLog.dictation.log("[Parakeet] Unified: empty/invalid audio file")
                return ""
            }
            try file.read(into: unpadded)
            buffer = unpadded
        }
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
            let language = Self.fluidLanguage(for: settings.language)
            if padsInput, let padded = try ParakeetInputPadding.paddedBuffer(contentsOf: fileURL) {
                result = try await mgr.transcribe(padded, decoderState: &decoderState, language: language)
            } else {
                result = try await mgr.transcribe(fileURL, decoderState: &decoderState, language: language)
            }
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
        
        // Dictation pads like the other paths: max(n, 1.5 s) + 400 ms of trailing silence.
        if padsInput {
            let padded = ParakeetInputPadding.paddedSampleCount(forModelSamples: samples.count)
            if stats.meanAbs < 0.002 && stats.peak < 0.01 {
                throw NSError(domain: "Parakeet", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Audio appears near-silent; check microphone and input gain"])
            }
            let result = try await transcribeRawSamples(
                mgr: mgr,
                samples: samples + [Float](repeating: 0, count: padded - samples.count)
            )
            scheduleIdleUnload()
            return result
        }

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

        let text = try await transcribeRawSamples(mgr: mgr, samples: finalSamples)

        // Schedule idle unload instead of immediate cleanup
        // Immediate cleanup breaks subsequent transcriptions by de-initializing the manager
        // The idle timeout (60s) provides the same benefits without breaking rapid-fire transcriptions
        AppLog.dictation.log("[Parakeet] Raw mode: scheduling idle unload (\(Int(self.idleSeconds))s)")
        scheduleIdleUnload()

        return text
    }

    private func transcribeRawSamples(mgr: AsrManager, samples: [Float]) async throws -> String {
        // Transcribe without source hint (VoiceInk-style for this pinned API)
        AppLog.dictation.log("[Parakeet] Raw mode: transcribing (no source hint)")
        let result: ASRResult
        do {
            let decoderLayers = await mgr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            result = try await mgr.transcribe(samples, decoderState: &decoderState)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] Raw mode transcribe error=\(ns.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] Raw mode error: \(ns.localizedDescription)")
            throw error
        }
        
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] Raw mode result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] Raw mode: result length=\(result.text.count) preview=\(String(preview))")
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
actor ParakeetTranscriptionProvider: TranscriptionProvider {
    enum Residency: Sendable, Equatable {
        case idleUnload(TimeInterval)
        case whileSelected
    }
    init(
        modelsDirectory: URL? = nil,
        waitsForVocabularyModel: Bool = false,
        residency: Residency = .idleUnload(300),
        padsInput: Bool = false
    ) {}
    func isResident(for settings: TranscriptionSettings? = nil) -> Bool { false }
    func setSelected(_ selected: Bool) async {}
    func handleMemoryPressure() async {}
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        throw ProviderError.notImplemented
    }
}
#endif
