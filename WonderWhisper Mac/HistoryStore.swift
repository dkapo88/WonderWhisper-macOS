import Foundation
import AppKit
import OSLog

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var maxEntries: Int {
        didSet {
            if maxEntries < 1 { maxEntries = 1 }
            UserDefaults.standard.set(maxEntries, forKey: Self.defaultsMaxKey)
            enforceMaxEntries()
        }
    }

    private let baseDir: URL
    private let entriesDir: URL
    private let audioDir: URL
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    init() {
       let fm = FileManager.default
       let appSupport: URL
       do {
           appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
       } catch {
           // Fallback to a default location in case the system directory is inaccessible
           // This shouldn't normally happen, but we'll handle it gracefully
           AppLog.dictation.error("Failed to access Application Support directory: \(error)")
           appSupport = URL(fileURLWithPath: "/tmp/WonderWhisper")
       }
       let root = appSupport.appendingPathComponent("WonderWhisper", isDirectory: true)
       let base = root.appendingPathComponent("History", isDirectory: true)
       self.baseDir = base
       self.entriesDir = base.appendingPathComponent("entries", isDirectory: true)
       self.audioDir = base.appendingPathComponent("audio", isDirectory: true)
       try? fm.createDirectory(at: self.entriesDir, withIntermediateDirectories: true)
       try? fm.createDirectory(at: self.audioDir, withIntermediateDirectories: true)
       let persisted = UserDefaults.standard.object(forKey: Self.defaultsMaxKey) as? Int
       self.maxEntries = persisted ?? 50
       load()
       enforceMaxEntries()
   }

    func load() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: entriesDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        // Consider only JSON files and sort by most recent file date (modification or creation)
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        func fileDate(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.contentModificationDate ?? values?.creationDate ?? .distantPast
        }
        let sorted = jsonFiles.sorted { fileDate($0) > fileDate($1) }
        let limited = sorted.prefix(maxEntries)
        var loaded: [HistoryEntry] = []
        for f in limited {
            if let data = try? Data(contentsOf: f, options: .mappedIfSafe), let entry = try? decoder.decode(HistoryEntry.self, from: data) {
                loaded.append(entry)
            }
        }
        self.entries = loaded
    }

    func append(fileURL: URL?, appName: String?, bundleID: String?, transcript: String, output: String, screenContext: String?, screenContextMethod: String?, selectedText: String?, llmSystemMessage: String? = nil, llmUserMessage: String? = nil, transcriptionModel: String?, llmModel: String?, transcriptionSeconds: Double?, llmSeconds: Double?, totalSeconds: Double?) async {
        let id = UUID()
        let date = Date()
        var audioFilename: String? = nil

        // Move/copy audio into persistent store
        if let src = fileURL {
            let dest = audioDir.appendingPathComponent("\(id).\(src.pathExtension.isEmpty ? "m4a" : src.pathExtension)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: src, to: dest)
                audioFilename = dest.lastPathComponent
            } catch {
                // If move fails (e.g., permission), try copy
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                    audioFilename = dest.lastPathComponent
                } catch {
                    audioFilename = nil
                }
            }
        }

        let entry = HistoryEntry(
            id: id,
            date: date,
            appName: appName,
            bundleID: bundleID,
            transcript: transcript,
            output: output,
            audioFilename: audioFilename,
            screenContext: screenContext,
            screenContextMethod: screenContextMethod,
            selectedText: selectedText,
            llmSystemMessage: llmSystemMessage,
            llmUserMessage: llmUserMessage,
            transcriptionModel: transcriptionModel,
            llmModel: llmModel,
            transcriptionSeconds: transcriptionSeconds,
            llmSeconds: llmSeconds,
            totalSeconds: totalSeconds
        )
        let path = entriesDir.appendingPathComponent("\(id).json")
        do {
            let data = try encoder.encode(entry)
            try data.write(to: path, options: .atomic)
        } catch {
            // ignore persistence failure for now
        }
        entries.insert(entry, at: 0)
        enforceMaxEntries()
    }

    func replace(id: UUID, with updated: HistoryEntry) async {
        // Persist to disk
        let path = entriesDir.appendingPathComponent("\(id).json")
        do {
            let data = try encoder.encode(updated)
            try data.write(to: path, options: .atomic)
        } catch {
            // ignore
        }
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = updated
            // Move to top
            entries.remove(at: idx)
            entries.insert(updated, at: 0)
        }
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFilename else { return nil }
        return audioDir.appendingPathComponent(name)
    }

    func revealInFinder(entry: HistoryEntry) {
        if let url = audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(entriesDir)
        }
    }

    func delete(entry: HistoryEntry) {
        let fm = FileManager.default
        // Remove JSON
        let jsonURL = entriesDir.appendingPathComponent("\(entry.id).json")
        if fm.fileExists(atPath: jsonURL.path) { try? fm.removeItem(at: jsonURL) }
        // Remove audio
        if let name = entry.audioFilename {
            let aURL = audioDir.appendingPathComponent(name)
            if fm.fileExists(atPath: aURL.path) { try? fm.removeItem(at: aURL) }
        }
        // Update in-memory list
        entries.removeAll { $0.id == entry.id }
    }
}

// MARK: - Private helpers
private extension HistoryStore {
    static let defaultsMaxKey = "history.maxEntries"

    func enforceMaxEntries() {
        guard entries.count > maxEntries else { return }
        let fm = FileManager.default
        // Entries are newest-first; remove oldest beyond maxEntries
        let overflow = entries.count - maxEntries
        guard overflow > 0 else { return }
        let toRemove = Array(entries.suffix(overflow))
        // Remove files from disk
        for e in toRemove {
            // JSON
            let jsonURL = entriesDir.appendingPathComponent("\(e.id).json")
            if fm.fileExists(atPath: jsonURL.path) { try? fm.removeItem(at: jsonURL) }
            // Audio
            if let name = e.audioFilename {
                let aURL = audioDir.appendingPathComponent(name)
                if fm.fileExists(atPath: aURL.path) { try? fm.removeItem(at: aURL) }
            }
        }
        // Trim in memory
        entries = Array(entries.prefix(maxEntries))
    }
}
