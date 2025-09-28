import Foundation

enum ParakeetManager {
    // Preferred location to place/download models
    static var modelsDirectory: URL {
        let appSupport = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent("ParakeetModels", isDirectory: true)
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

    static func modelsPresent() -> Bool { discoverInstalledModelDirectory() != nil }

    // MARK: - Discovery
    private static func discoverInstalledModelDirectory() -> URL? {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Candidates we know about
        var candidates: [URL] = []
        if let appSupport { candidates.append(appSupport.appendingPathComponent("ParakeetModels", isDirectory: true)) }
        if let appSupport { candidates.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)) }
        if let appSupport { candidates.append(appSupport.appendingPathComponent("parakeet-tdt-0.6b", isDirectory: true)) }
        // Any folder in Application Support that looks like a parakeet model root
        if let appSupport {
            if let items = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for url in items {
                    if url.lastPathComponent.lowercased().hasPrefix("parakeet-tdt") { candidates.append(url) }
                }
            }
        }
        // First candidate that exists and is non-empty wins
        for dir in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !contents.isEmpty { return dir }
            }
        }
        return nil
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
        // Heuristics: expect at least encoder/decoder/melspectrogram/joint models
        let needed = ["encoder", "decoder", "melspectrogram", "joint"]
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
}
