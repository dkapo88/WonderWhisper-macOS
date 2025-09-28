import Foundation
#if canImport(FluidAudio)
import FluidAudio
@preconcurrency import CoreML
#endif

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

    // MARK: - Version detection
    static func v3ModelsPresent() -> Bool {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard let appSupport else { return false }
        let v3 = appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: v3.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func v2ModelsDirectory() -> URL? {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard let appSupport else { return nil }
        // Common v2 folder name observed in the wild
        let candidate = appSupport.appendingPathComponent("parakeet-tdt-0.6b", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        // Fallback: scan for any parakeet folder that is not the v3 coreml name
        if let items = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in items where url.lastPathComponent.lowercased().hasPrefix("parakeet-tdt") && !url.lastPathComponent.lowercased().contains("v3-coreml") {
                return url
            }
        }
        return nil
    }

    static func v2ModelsPresent() -> Bool { v2ModelsDirectory() != nil }

    #if canImport(FluidAudio)
    @available(macOS 13.0, *)
    static func v3ModelsDirectory() -> URL {
        AsrModels.defaultCacheDirectory()
    }

    @available(macOS 13.0, *)
    static func purgeV3Models() throws {
        let dir = v3ModelsDirectory()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
    #endif

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

    // MARK: - V2 loader (best effort)
    #if canImport(FluidAudio)
    @available(macOS 13.0, *)
    static func loadV2AsrModelsIfPresent() async throws -> AsrModels? {
        guard let root = v2ModelsDirectory() else { return nil }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }

        var preURL: URL? = nil
        var encURL: URL? = nil
        var decURL: URL? = nil
        var jointURL: URL? = nil
        var vocabURL: URL? = nil

        for case let url as URL in enumerator {
            if url.pathExtension == "mlmodelc" || url.lastPathComponent.lowercased().hasSuffix(".mlmodelc") {
                let name = url.lastPathComponent.lowercased()
                if preURL == nil && (name.contains("preprocess") || name.contains("melspectrogram") || name.contains("mel")) {
                    preURL = url
                } else if encURL == nil && name.contains("encoder") {
                    encURL = url
                } else if decURL == nil && name.contains("decoder") {
                    decURL = url
                } else if jointURL == nil && (name.contains("jointdecision") || name.contains("joint")) {
                    jointURL = url
                }
            } else if vocabURL == nil && url.pathExtension.lowercased() == "json" && url.lastPathComponent.lowercased().contains("vocab") {
                vocabURL = url
            } else if vocabURL == nil && url.pathExtension.lowercased() == "txt" && url.lastPathComponent.lowercased().contains("vocab") {
                vocabURL = url
            }
        }

        guard let preURL, let encURL, let decURL, let jointURL else { return nil }

        let baseConfig = AsrModels.defaultConfiguration()
        let preCfg = MLModelConfiguration(); preCfg.computeUnits = .cpuOnly
        let mmCfg = baseConfig // cpuAndNeuralEngine by default

        let pre = try MLModel(contentsOf: preURL, configuration: preCfg)
        let enc = try MLModel(contentsOf: encURL, configuration: mmCfg)
        let dec = try MLModel(contentsOf: decURL, configuration: mmCfg)
        let joi = try MLModel(contentsOf: jointURL, configuration: mmCfg)

        let vocab: [Int: String]
        if let vocabURL {
            if vocabURL.pathExtension.lowercased() == "json" {
                let data = try Data(contentsOf: vocabURL)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
                var dict: [Int: String] = [:]
                for (k, v) in obj { if let i = Int(k) { dict[i] = v } }
                vocab = dict
            } else {
                // Fallback: TXT vocab with one token per line
                let txt = (try? String(contentsOf: vocabURL)) ?? ""
                var dict: [Int: String] = [:]
                for (i, line) in txt.components(separatedBy: .newlines).enumerated() where !line.isEmpty {
                    dict[i] = line
                }
                vocab = dict
            }
        } else {
            // No vocabulary file found — abort
            return nil
        }

        return AsrModels(
            encoder: enc,
            preprocessor: pre,
            decoder: dec,
            joint: joi,
            configuration: mmCfg,
            vocabulary: vocab
        )
    }
    #endif
}
