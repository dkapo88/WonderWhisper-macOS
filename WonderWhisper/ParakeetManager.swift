import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// User-selectable on-device Parakeet model.
///
/// The choice is persisted under the `parakeet.version` UserDefaults key and read
/// by both `ParakeetTranscriptionProvider` (which model to load/run) and the
/// settings UI (which model to download / show status for). Dictation only:
/// meetings always run Parakeet Unified streaming.
enum ParakeetModelKind: String, CaseIterable, Identifiable {
    /// Underdog Bark 3.0 Clean (Conway Research): a post-training of Parakeet
    /// TDT 0.6B v3 for English that drops fillers, false starts and repeated
    /// words. Loaded via FluidAudio's `AsrManager` (`AsrModelVersion.bark3Clean`),
    /// like Ultra. Its raw output needs `BarkTranscriptCleanup`. The default for
    /// new installs.
    case barkClean = "bark-clean"
    /// Parakeet Unified 0.6B. English-only, with punctuation/capitalization
    /// natively. Loaded via FluidAudio's `UnifiedAsrManager` (offline batch).
    /// The default before Bark Clean, so existing installs keep it.
    case unified
    /// Parakeet Ultra: moondream's post-training of Parakeet TDT 0.6B v3. Same
    /// 25 European languages and decode contract as v3, more accurate on every
    /// published benchmark. Loaded via FluidAudio's `AsrManager`
    /// (`AsrModelVersion.ultra`). Replaced the plain v3 option; a stored `"v3"`
    /// reads as `.ultra`.
    case ultra

    /// The `parakeet.version` UserDefaults key. Unchanged from when v3 was the
    /// multilingual option, so existing selections carry over.
    static let defaultsKey = "parakeet.version"

    /// What an unset `parakeet.version` means on a new install. Existing installs
    /// that never set it resolve to their old default (`.unified`) instead, which
    /// `ParakeetModelDefaults` pins in a separate, unsynced key on the first launch
    /// of the version that introduced Bark Clean.
    static let newInstallDefault: ParakeetModelKind = .barkClean

    /// The default before Bark Clean.
    static let legacyDefault: ParakeetModelKind = .unified

    var id: String { rawValue }

    /// Resolve a stored `parakeet.version` value. Unset means the new-install
    /// default (Bark Clean). `"ultra"` and the retired `"v3"` select Ultra;
    /// `"unified"`, the retired `"v2"` and unknown values select Unified, as
    /// they always have.
    init(storedValue: String?) {
        guard let storedValue else {
            self = Self.newInstallDefault
            return
        }
        switch storedValue.lowercased() {
        case "bark-clean": self = .barkClean
        case "ultra", "v3": self = .ultra
        default: self = .unified
        }
    }

    /// The model a transcription model id names (`"parakeet-unified"`, `"parakeet-bark-clean"`,
    /// the retired `"parakeet-v3"`), or nil for an id that names none (`"parakeet-local"`: use
    /// the selection).
    init?(modelIdentifier: String) {
        let model = modelIdentifier.lowercased()
        if model.contains("bark") {
            self = .barkClean
        } else if model.contains("unified") {
            self = .unified
        } else if model.contains("ultra") || model.contains("v3") || model.contains("v2") {
            // v3 and v2 retired -> Ultra, the multilingual TDT successor
            self = .ultra
        } else {
            return nil
        }
    }

    /// Downloaded models that stand in, in order, for a Bark Clean that is not downloaded.
    static let barkCleanFallbackOrder: [ParakeetModelKind] = [.unified, .ultra]

    /// The model a dictation that asked for `requested` actually runs. Bark Clean that is
    /// neither resident nor downloaded runs the first downloaded fallback; with none downloaded
    /// it stays Bark Clean and downloads on demand. Shared by the provider and Settings so the
    /// status never disagrees with what runs.
    static func effective(
        requested: ParakeetModelKind,
        barkCleanResident: Bool,
        isInstalled: (ParakeetModelKind) -> Bool
    ) -> ParakeetModelKind {
        guard requested == .barkClean, !barkCleanResident, !isInstalled(.barkClean) else {
            return requested
        }
        return barkCleanFallbackOrder.first(where: isInstalled) ?? requested
    }

    /// The transcription model id that names this model (`parakeet-bark-clean`,
    /// `parakeet-unified`, `parakeet-ultra`). A dictation's configuration carries it instead of
    /// `parakeet-local`, so a model change mid-recording applies to the next dictation.
    var transcriptionModelIdentifier: String { "parakeet-\(rawValue)" }

    /// A Parakeet transcription model id resolved to a concrete model: an id that already names
    /// one (a prompt override) is kept; `parakeet-local` becomes the selected model's id.
    static func sessionModelIdentifier(
        for model: String,
        selected: @autoclosure () -> ParakeetModelKind = ParakeetModelKind.selected
    ) -> String {
        if ParakeetModelKind(modelIdentifier: model) != nil { return model }
        return selected().transcriptionModelIdentifier
    }

    /// Name in the Settings transcription picker.
    var pickerName: String {
        switch self {
        case .barkClean: return "Bark Clean (On-device, English)"
        case .unified: return "Parakeet Unified (On-device, English)"
        case .ultra: return "Parakeet Ultra (On-device, multilingual)"
        }
    }

    /// Short name for status lines.
    var shortName: String {
        switch self {
        case .barkClean: return "Bark Clean"
        case .unified: return "Parakeet Unified"
        case .ultra: return "Parakeet Ultra"
        }
    }

    var displayName: String {
        switch self {
        case .barkClean: return "Clean English (Bark Clean)"
        case .unified: return "English (Unified)"
        case .ultra: return "Multilingual (Ultra)"
        }
    }

    var detail: String {
        switch self {
        case .barkClean:
            return "Underdog Bark 3.0 Clean. English only. Removes ums, false starts and "
                + "repeated words as you dictate. Recommended for dictation."
        case .unified:
            return "Parakeet Unified. English only, with automatic punctuation and "
                + "capitalization. Keeps every word you say."
        case .ultra:
            return "Parakeet Ultra. 25 European languages. More accurate than Parakeet v3 "
                + "at the same speed."
        }
    }

    /// Approximate download size of the dictation model files.
    var approximateDownloadSize: String {
        switch self {
        case .barkClean: return "About 460 MB"
        case .unified: return "About 600 MB"
        case .ultra: return "About 630 MB"
        }
    }

    /// Model credit shown in Settings (CC-BY-4.0 attribution), or nil.
    var credit: ParakeetModelCredit? {
        switch self {
        case .barkClean: return .barkClean
        case .unified, .ultra: return nil
        }
    }

    /// Bark Clean and Unified only transcribe English.
    var isEnglishOnly: Bool {
        switch self {
        case .barkClean, .unified: return true
        case .ultra: return false
        }
    }

    /// FluidAudio's TDT model version for the `AsrManager` backends; nil for Unified.
    #if canImport(FluidAudio)
    var tdtVersion: AsrModelVersion? {
        switch self {
        case .barkClean: return .bark3Clean
        case .ultra: return .ultra
        case .unified: return nil
        }
    }
    #endif

    /// Whether the model has a live (streaming) decoder in this app. Only Unified does
    /// today, through `StreamingUnifiedAsrManager` (meetings). Phase 2 streaming must
    /// dispatch on this capability and never run Unified in place of another selection:
    /// a selected model without a live decoder falls back to its batch path.
    var supportsLiveStreaming: Bool {
        switch self {
        case .unified: return true
        case .barkClean, .ultra: return false
        }
    }

    /// On-disk model folder under `FluidAudio/Models`, matching FluidAudio's
    /// `Repo.folderName`. As of 0.18.0 Unified and Ultra have no explicit
    /// `folderName` case, so both hit the default branch which strips the
    /// `-coreml` suffix from the repo slug; Bark Clean has an explicit case for
    /// its subfolder of `bark-3.0-coreml`. A unit test pins these against
    /// `Repo.folderName`.
    var folderName: String {
        switch self {
        case .barkClean: return "bark-3.0-clean"
        case .unified: return "parakeet-unified-en-0.6b"
        case .ultra: return "parakeet-ultra"
        }
    }

    /// Files that must exist in `folderName` for the model to count as
    /// downloaded, taken from FluidAudio's own lists. Unified offline ships no
    /// CoreML preprocessor since 0.15.6 (mel runs in Swift); the v3 family
    /// (Ultra, Bark Clean) still does.
    var requiredFiles: [String] {
        #if canImport(FluidAudio)
        switch self {
        case .unified:
            return ModelNames.ParakeetUnified.requiredModels(variant: "offline").sorted()
        case .ultra, .barkClean:
            return ModelNames.ASR.requiredModelsV3().sorted() + [ModelNames.ASR.vocabularyFile]
        }
        #else
        return []
        #endif
    }

    /// Currently selected model, read fresh from UserDefaults. Shares
    /// `resolved(stored:defaults:)` with the settings picker so both always agree.
    static var selected: ParakeetModelKind {
        resolved(stored: AppConfig.defaults.string(forKey: defaultsKey))
    }

    /// The model a `parakeet.version` value selects on this Mac: the stored value, else the
    /// default pinned for an existing install, else the new-install default.
    static func resolved(stored: String?, defaults: UserDefaults = AppConfig.defaults) -> ParakeetModelKind {
        ParakeetModelKind(storedValue: stored ?? ParakeetModelDefaults.pinnedDefault(defaults: defaults))
    }
}

enum ParakeetManager {
    /// The Application Support folder model files live under: the real one, or a QA build's
    /// scratch stand-in, so QA never discovers, downloads into or loads the shared models.
    static var applicationSupportBase: URL? {
        if let qa = AppConfig.qaApplicationSupport { return qa }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
    }

    // Preferred location to place/download models
    static var modelsDirectory: URL {
        let fm = FileManager.default
        if let qa = AppConfig.qaApplicationSupport {
            let dir = qa.appendingPathComponent("FluidAudio/Models", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        do {
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        } catch {
            AppLog.dictation.error("Failed to access Application Support directory for Parakeet models: \(error.localizedDescription)")
            let fallbackBase = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let fallbackDir = fallbackBase.appendingPathComponent("FluidAudio/Models", isDirectory: true)
            do {
                try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            } catch {
                AppLog.dictation.error("Failed to create fallback Parakeet models directory: \(error.localizedDescription)")
            }
            return fallbackDir
        }
    }

    // Detect existing installs that may have landed in a different folder
    static var effectiveModelsDirectory: URL {
        if let found = discoverInstalledModelDirectory() { return found }
        return modelsDirectory
    }

    static var isLinked: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    static func modelsPresent() -> Bool {
        guard let dir = discoverInstalledModelDirectory() else { return false }
        return validateModels(at: dir).ok
    }

    // MARK: - Per-model helpers

    /// Canonical install directory for a given model under `FluidAudio/Models`.
    static func modelDirectory(for kind: ParakeetModelKind) -> URL {
        modelsDirectory.appendingPathComponent(kind.folderName, isDirectory: true)
    }

    /// Whether the given model is downloaded. Every selectable model is only ever
    /// placed canonically by FluidAudio, so no legacy discovery applies.
    static func modelsPresent(for kind: ParakeetModelKind) -> Bool {
        missingFiles(kind.requiredFiles, in: modelDirectory(for: kind)).isEmpty
    }

    /// Directory to point Finder at for the given model: the model folder once
    /// it exists, otherwise the models root.
    static func effectiveModelsDirectory(for kind: ParakeetModelKind) -> URL {
        let canonical = modelDirectory(for: kind)
        if FileManager.default.fileExists(atPath: canonical.path) { return canonical }
        return modelsDirectory
    }

    /// Required file names that are absent from `dir`. An empty `required` list
    /// (framework not linked) counts as missing everything, never as present.
    static func missingFiles(_ required: [String], in dir: URL) -> [String] {
        guard !required.isEmpty else { return ["(unknown required files)"] }
        let fm = FileManager.default
        return required.filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: - Discovery
    private static func discoverInstalledModelDirectory() -> URL? {
        let fm = FileManager.default
        let appSupport = applicationSupportBase
        // Candidates we know about
        var candidates: [URL] = []
        // FluidAudio default cache path and known nested model roots
        if let appSupport {
            let fluidModels = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
            candidates.append(fluidModels.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true))
            candidates.append(fluidModels.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true))
            candidates.append(fluidModels.appendingPathComponent("parakeet-tdt-0.6b", isDirectory: true))
            if let items = try? fm.contentsOfDirectory(at: fluidModels, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in items where url.lastPathComponent.lowercased().hasPrefix("parakeet-tdt") {
                    candidates.append(url)
                }
            }
            candidates.append(fluidModels)
        }
        // Legacy paths supported previously
        if let appSupport { candidates.append(appSupport.appendingPathComponent("ParakeetModels", isDirectory: true)) }
        if let appSupport { candidates.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)) }
        if let appSupport { candidates.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)) }
        if let appSupport { candidates.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b", isDirectory: true)) }
        // Any folder in Application Support that looks like a parakeet model root
        if let appSupport {
            if let items = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in items {
                    if url.lastPathComponent.lowercased().hasPrefix("parakeet-tdt") { candidates.append(url) }
                }
            }
        }
        // Prefer a candidate that validates as a model root; keep a non-empty
        // fallback only so diagnostics can point at partially downloaded models.
        var firstNonEmpty: URL?
        for dir in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !contents.isEmpty {
                    if validateModels(at: dir).ok { return dir }
                    if firstNonEmpty == nil { firstNonEmpty = dir }
                }
            }
        }
        return firstNonEmpty
    }

    // MARK: - Validation / Diagnostics
    static func inventory(at dir: URL) -> (mlmodelc: [String], others: [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        var compiledModels: [String] = []
        var others: [String] = []
        for url in items {
            if url.pathExtension == "mlmodelc" || url.lastPathComponent.lowercased().hasSuffix(".mlmodelc") {
                compiledModels.append(url.lastPathComponent)
            } else {
                others.append(url.lastPathComponent)
            }
        }
        return (compiledModels.sorted(), others.sorted())
    }

    static func validateModels(at dir: URL) -> (ok: Bool, missing: [String]) {
        let inv = inventory(at: dir)
        // Current FluidAudio Parakeet packages use Preprocessor.mlmodelc for
        // mel feature extraction. Older builds/logs referred to it as melspectrogram.
        let needed = ["encoder", "decoder", "preprocessor", "joint"]
        let present = Set(inv.mlmodelc.map { $0.lowercased() })
        var missing: [String] = []
        for key in needed {
            if !present.contains(where: { $0.contains(key) }) { missing.append(key) }
        }
        // Vocabulary file may be plain; just warn if not found
        let vocabPresent = (inv.others.contains(where: { $0.lowercased().contains("vocab") }))
        if !vocabPresent { missing.append("vocabulary") }
        return (missing.isEmpty, missing)
    }

    // Remove all known model caches (new + legacy paths) for a clean reset
    static func removeAllModels() {
        let fm = FileManager.default
        let appSupport = applicationSupportBase
        var targets: [URL] = []
        if let appSupport { targets.append(appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)) }
        if let appSupport { targets.append(appSupport.appendingPathComponent("ParakeetModels", isDirectory: true)) }
        if let appSupport { targets.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)) }
        if let appSupport { targets.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)) }
        if let appSupport { targets.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b", isDirectory: true)) }
        if let appSupport, let items = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in items where url.lastPathComponent.lowercased().hasPrefix("parakeet-tdt") {
                targets.append(url)
            }
        }
        for t in targets { try? fm.removeItem(at: t) }
    }
}
