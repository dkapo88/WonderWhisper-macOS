import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// User-selectable on-device Parakeet model.
///
/// The choice is persisted under the `parakeet.version` UserDefaults key and read
/// by both `ParakeetTranscriptionProvider` (which model to load/run) and the
/// settings UI (which model to download / show status for).
enum ParakeetModelKind: String, CaseIterable, Identifiable {
    /// Parakeet Unified 0.6B. English-only, but the highest on-device accuracy
    /// and throughput and the only model that emits punctuation/capitalization
    /// natively. Loaded via FluidAudio's `UnifiedAsrManager` (offline batch).
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

    var id: String { rawValue }

    /// Resolve a stored `parakeet.version` value. `"ultra"` and the retired
    /// `"v3"` select Ultra; everything else (unset, `"unified"`, the retired
    /// `"v2"`, unknown values) resolves to the `.unified` default.
    init(storedValue: String?) {
        switch (storedValue ?? "").lowercased() {
        case "ultra", "v3": self = .ultra
        default: self = .unified
        }
    }

    var displayName: String {
        switch self {
        case .unified: return "English (Unified)"
        case .ultra: return "Multilingual (Ultra)"
        }
    }

    var detail: String {
        switch self {
        case .unified:
            return "Parakeet Unified. English only. Highest on-device accuracy and speed, "
                + "with automatic punctuation and capitalization."
        case .ultra:
            return "Parakeet Ultra. 25 European languages. More accurate than Parakeet v3 "
                + "at the same speed."
        }
    }

    /// Approximate download size of the dictation model files.
    var approximateDownloadSize: String {
        switch self {
        case .unified: return "About 600 MB"
        case .ultra: return "About 630 MB"
        }
    }

    /// On-disk model folder under `FluidAudio/Models`, matching FluidAudio's
    /// `Repo.folderName`. As of 0.17.7 neither repo has an explicit `folderName`
    /// case, so both hit the default branch which strips the `-coreml` suffix
    /// from the repo slug (`name.replacingOccurrences(of: "-coreml", with: "")`).
    /// A unit test pins these against `Repo.folderName`.
    var folderName: String {
        switch self {
        case .unified: return "parakeet-unified-en-0.6b"
        case .ultra: return "parakeet-ultra"
        }
    }

    /// Files that must exist in `folderName` for the model to count as
    /// downloaded, taken from FluidAudio's own lists. Unified offline ships no
    /// CoreML preprocessor since 0.15.6 (mel runs in Swift); the v3 family
    /// (Ultra) still does.
    var requiredFiles: [String] {
        #if canImport(FluidAudio)
        switch self {
        case .unified:
            return ModelNames.ParakeetUnified.requiredModels(variant: "offline").sorted()
        case .ultra:
            return ModelNames.ASR.requiredModelsV3().sorted() + [ModelNames.ASR.vocabularyFile]
        }
        #else
        return []
        #endif
    }

    /// Currently selected model, read fresh from UserDefaults. Shares
    /// `init(storedValue:)` with the settings picker so both always agree.
    static var selected: ParakeetModelKind {
        ParakeetModelKind(storedValue: AppConfig.defaults.string(forKey: defaultsKey))
    }
}

enum ParakeetManager {
    // Preferred location to place/download models
    static var modelsDirectory: URL {
        let fm = FileManager.default
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

    /// Whether the given model is downloaded. Both models are only ever placed
    /// canonically by FluidAudio, so no legacy discovery applies.
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
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
