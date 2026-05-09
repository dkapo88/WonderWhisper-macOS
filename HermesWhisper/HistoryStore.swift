import Foundation
import AppKit
import OSLog

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var hasMoreEntries: Bool = false
    @Published var isLoadingMore: Bool = false
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
    private let imageDir: URL
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()
    
    // Pagination support
    private let pageSize = 20 // Number of entries to load at once
    private var allEntryFiles: [URL] = []
    private var currentIndex = 0
    private var isInitialized = false  // Guard against duplicate initialization
    private var isLoadingInitial = false  // Track if initial load is in progress
    private var initialLoadWorkItem: DispatchWorkItem?  // Track background work for cancellation
    private let backgroundQueue = DispatchQueue(label: "com.hermeswhisper.history", qos: .utility)

    init() {
       let fm = FileManager.default
       let root = AppStoragePaths.appSupportRoot(fileManager: fm)
       let base = root.appendingPathComponent("History", isDirectory: true)
       self.baseDir = base
       self.entriesDir = base.appendingPathComponent("entries", isDirectory: true)
       self.audioDir = base.appendingPathComponent("audio", isDirectory: true)
       self.imageDir = base.appendingPathComponent("images", isDirectory: true)
       try? fm.createDirectory(at: self.entriesDir, withIntermediateDirectories: true)
       try? fm.createDirectory(at: self.audioDir, withIntermediateDirectories: true)
       try? fm.createDirectory(at: self.imageDir, withIntermediateDirectories: true)
       let persisted = UserDefaults.standard.object(forKey: Self.defaultsMaxKey) as? Int
       self.maxEntries = persisted ?? 50
       
       // Load initial page of entries
       loadInitialEntries()
    }

    func loadInitialEntries() {
        guard !isInitialized && !isLoadingInitial else { return }
        isInitialized = true
        isLoadingInitial = true
        
        // Cancel any pending initial load work
        initialLoadWorkItem?.cancel()
        
        // Create new work item
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.loadEntryFiles()
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoadingInitial = false
                self.loadNextPage()
            }
        }
        
        initialLoadWorkItem = workItem
        backgroundQueue.async(execute: workItem)
    }
    
    private func loadEntryFiles() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        
        // Use shallow enumeration without prefetching all metadata upfront
        // This avoids the expensive I/O of reading all file metadata at once
        var filesByDate: [(url: URL, date: Date)] = []
        
        guard let enumerator = fm.enumerator(at: entriesDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        
        for case let fileURL as URL in enumerator {
            // Only process JSON files
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            
            // Get file date with lazy evaluation
            let date: Date
            if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
               let modDate = values.contentModificationDate {
                date = modDate
            } else if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      let creationDate = values.creationDate {
                date = creationDate
            } else {
                date = .distantPast
            }
            
            filesByDate.append((url: fileURL, date: date))
        }
        
        // Sort only once at the end, using pre-fetched dates
        allEntryFiles = filesByDate.sorted { $0.date > $1.date }.map { $0.url }
        currentIndex = 0
    }
    
    func loadNextPage() {
        guard !isLoadingMore else { return }
        
        isLoadingMore = true
        
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            
            let endIndex = min(self.currentIndex + self.pageSize, self.allEntryFiles.count)
            let filesToLoad = Array(self.allEntryFiles[self.currentIndex..<endIndex])
            
            var newEntries: [HistoryEntry] = []
            for f in filesToLoad {
                if let data = try? Data(contentsOf: f, options: .mappedIfSafe),
                   let entry = try? self.decoder.decode(HistoryEntry.self, from: data) {
                    newEntries.append(entry)
                }
            }
            
            DispatchQueue.main.async {
                self.entries.append(contentsOf: newEntries)
                self.currentIndex = endIndex
                self.hasMoreEntries = endIndex < self.allEntryFiles.count
                self.isLoadingMore = false
                
                // Enforce max entries after loading
                self.enforceMaxEntries()
            }
        }
    }
    
    func refresh() {
        // Cancel any pending initial load work
        initialLoadWorkItem?.cancel()
        initialLoadWorkItem = nil
        
        entries.removeAll()
        currentIndex = 0
        hasMoreEntries = false
        isInitialized = false
        isLoadingInitial = false
        loadInitialEntries()
    }

    func load() {
        // Legacy method - now just refreshes
        refresh()
    }

    func append(fileURL: URL?,
                appName: String?,
                bundleID: String?,
                transcript: String,
                output: String,
                screenContext: String?,
                screenContextMethod: String?,
                screenImage: ScreenCaptureSnapshot?,
                selectedText: String?,
                activeTextField: String?,
                llmSystemMessage: String? = nil,
                llmUserMessage: String? = nil,
                transcriptionModel: String?,
                llmModel: String?,
                transcriptionSeconds: Double?,
                llmSeconds: Double?,
                totalSeconds: Double?,
                copyFileOnly: Bool = false) async {
        let id = UUID()
        let date = Date()
        backgroundQueue.async { [weak self] in
            guard let self else { return }
            var audioFilename: String? = nil

            // Move/copy audio into persistent store
            if let src = fileURL {
                let dest = self.audioDir.appendingPathComponent(
                    "\(id).\(src.pathExtension.isEmpty ? "m4a" : src.pathExtension)"
                )
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    
                    if copyFileOnly {
                        // For file transcription benchmarking, copy instead of move
                        try FileManager.default.copyItem(at: src, to: dest)
                        audioFilename = dest.lastPathComponent
                    } else {
                        // For dictation recordings, try move first (faster), fall back to copy
                        try FileManager.default.moveItem(at: src, to: dest)
                        audioFilename = dest.lastPathComponent
                    }
                } catch {
                    // If move fails (e.g., permission), try copy
                    if !copyFileOnly {
                        do {
                            try FileManager.default.copyItem(at: src, to: dest)
                            audioFilename = dest.lastPathComponent
                        } catch {
                            audioFilename = nil
                        }
                    } else {
                        audioFilename = nil
                    }
                }
            }

            var screenImageFilename: String? = nil
            var screenImageMimeType: String? = nil
            var screenImageWidth: Int? = nil
            var screenImageHeight: Int? = nil

            if let snapshot = screenImage {
                let ext = Self.fileExtension(forMimeType: snapshot.mimeType)
                let dest = self.imageDir.appendingPathComponent("\(id).\(ext)")
                do {
                    try snapshot.data.write(to: dest, options: .atomic)
                    screenImageFilename = dest.lastPathComponent
                    screenImageMimeType = snapshot.mimeType
                    screenImageWidth = snapshot.width
                    screenImageHeight = snapshot.height
                } catch {
                    AppLog.dictation.error("Failed to persist screen image: \(error.localizedDescription)")
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
                screenImageFilename: screenImageFilename,
                screenImageMimeType: screenImageMimeType,
                screenImageWidth: screenImageWidth,
                screenImageHeight: screenImageHeight,
                selectedText: selectedText,
                activeTextField: activeTextField,
                llmSystemMessage: llmSystemMessage,
                llmUserMessage: llmUserMessage,
                transcriptionModel: transcriptionModel,
                llmModel: llmModel,
                transcriptionSeconds: transcriptionSeconds,
                llmSeconds: llmSeconds,
                totalSeconds: totalSeconds
            )
            
            // Save to disk in background
            let path = self.entriesDir.appendingPathComponent("\(id).json")
            do {
                let data = try self.encoder.encode(entry)
                try data.write(to: path, options: .atomic)
                
                // Update in-memory state on main thread
                DispatchQueue.main.async {
                    self.entries.insert(entry, at: 0)
                    self.allEntryFiles.insert(path, at: 0)
                    self.currentIndex += 1
                    self.enforceMaxEntries()
                }
            } catch {
                AppLog.dictation.error("Failed to save history entry: \(error.localizedDescription)")
            }
        }
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

    func imageURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.screenImageFilename else { return nil }
        return imageDir.appendingPathComponent(name)
    }

    func revealInFinder(entry: HistoryEntry) {
        if let url = audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let image = imageURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([image])
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
        if let imageName = entry.screenImageFilename {
            let imgURL = imageDir.appendingPathComponent(imageName)
            if fm.fileExists(atPath: imgURL.path) { try? fm.removeItem(at: imgURL) }
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
        
        // Remove excess entries from memory
        let excessCount = entries.count - maxEntries
        let entriesToRemove = Array(entries.suffix(excessCount))
        
        // Update in-memory state
        entries = Array(entries.prefix(maxEntries))
        
        // Clean up files in background - ALL array access must be on same queue
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            
            // Track files that need removal from allEntryFiles array
            var filesToRemoveFromArray: [URL] = []
            
            for entry in entriesToRemove {
                // Remove JSON
                let jsonURL = self.entriesDir.appendingPathComponent("\(entry.id).json")
                if fm.fileExists(atPath: jsonURL.path) { 
                    try? fm.removeItem(at: jsonURL)
                    filesToRemoveFromArray.append(jsonURL)
                }
                
                // Remove audio
                if let name = entry.audioFilename {
                    let aURL = self.audioDir.appendingPathComponent(name)
                    if fm.fileExists(atPath: aURL.path) { 
                        try? fm.removeItem(at: aURL) 
                    }
                }
                
                // Remove image
                if let imageName = entry.screenImageFilename {
                    let imgURL = self.imageDir.appendingPathComponent(imageName)
                    if fm.fileExists(atPath: imgURL.path) { 
                        try? fm.removeItem(at: imgURL) 
                    }
                }
            }
            
            // Update allEntryFiles array on main thread to avoid race conditions
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Find indices before removing to avoid shifting issues
                var indicesToRemove: [Int] = []
                for fileURL in filesToRemoveFromArray {
                    if let index = self.allEntryFiles.firstIndex(of: fileURL) {
                        indicesToRemove.append(index)
                    }
                }
                
                // Count how many files below currentIndex will be removed
                let filesBelowCurrent = indicesToRemove.filter { $0 < self.currentIndex }.count
                
                // Remove files from allEntryFiles array (in reverse order to avoid index shifting)
                for index in indicesToRemove.sorted(by: >) {
                    self.allEntryFiles.remove(at: index)
                }
                
                // Apply index adjustment based on files removed before currentIndex
                self.currentIndex = max(0, self.currentIndex - filesBelowCurrent)
                
                // Update hasMoreEntries flag
                self.hasMoreEntries = self.currentIndex < self.allEntryFiles.count
            }
        }
    }
}

extension HistoryStore {
    nonisolated static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        default: return "bin"
        }
    }

    nonisolated static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
