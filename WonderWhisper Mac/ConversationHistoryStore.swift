import Foundation
import OSLog

// MARK: - Conversation Message Model

struct PromptConversationMessage: Codable, Identifiable {
    let id: UUID
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
    }

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Conversation History Metadata

struct ConversationHistoryMetadata: Codable {
    var lastProvider: String?
    var lastProviderEndpoint: String?
    var createdAt: Date
    var updatedAt: Date

    init(lastProvider: String? = nil, lastProviderEndpoint: String? = nil) {
        self.lastProvider = lastProvider
        self.lastProviderEndpoint = lastProviderEndpoint
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Conversation History Store

final class ConversationHistoryStore {
    private let baseDir: URL
    private let conversationsDir: URL
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let backgroundQueue = DispatchQueue(label: "com.wonderwhisper.conversationhistory", qos: .utility)

    init() {
        let fm = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            AppLog.dictation.error("Failed to access Application Support directory: \(error)")
            appSupport = URL(fileURLWithPath: "/tmp/WonderWhisper")
        }
        let root = appSupport.appendingPathComponent("WonderWhisper", isDirectory: true)
        let base = root.appendingPathComponent("ConversationHistory", isDirectory: true)
        self.baseDir = base
        self.conversationsDir = base.appendingPathComponent("conversations", isDirectory: true)
        try? fm.createDirectory(at: self.conversationsDir, withIntermediateDirectories: true)

        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public API

    /// Load conversation history for a prompt
    func loadHistory(for promptID: UUID) -> [PromptConversationMessage] {
        let messagesFile = conversationsDir.appendingPathComponent("\(promptID.uuidString)_messages.json")
        guard FileManager.default.fileExists(atPath: messagesFile.path),
              let data = try? Data(contentsOf: messagesFile) else {
            return []
        }
        do {
            return try decoder.decode([PromptConversationMessage].self, from: data)
        } catch {
            AppLog.dictation.error("Failed to decode conversation history for prompt \(promptID): \(error)")
            return []
        }
    }

    /// Get last N messages from conversation
    func getContextMessages(for promptID: UUID, count: Int) -> [PromptConversationMessage] {
        let all = loadHistory(for: promptID)
        return Array(all.suffix(count))
    }

    /// Add a message to conversation history
    func addMessage(to promptID: UUID, role: String, content: String) {
        let message = PromptConversationMessage(role: role, content: content)
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            var messages = self.loadHistory(for: promptID)
            messages.append(message)
            self.saveMessages(messages, for: promptID)
            self.updateMetadata(for: promptID)
        }
    }

    /// Add multiple messages atomically
    func addMessages(to promptID: UUID, messages: [PromptConversationMessage]) {
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            var existing = self.loadHistory(for: promptID)
            existing.append(contentsOf: messages)
            self.saveMessages(existing, for: promptID)
            self.updateMetadata(for: promptID)
        }
    }

    /// Clear conversation history for a prompt
    func clearHistory(for promptID: UUID) {
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            let messagesFile = self.conversationsDir.appendingPathComponent("\(promptID.uuidString)_messages.json")
            let metadataFile = self.conversationsDir.appendingPathComponent("\(promptID.uuidString)_metadata.json")
            try? FileManager.default.removeItem(at: messagesFile)
            try? FileManager.default.removeItem(at: metadataFile)
            AppLog.dictation.log("Cleared conversation history for prompt \(promptID)")
        }
    }

    /// Check and handle provider change
    func checkProviderChange(for promptID: UUID, currentProvider: String, currentEndpoint: URL) -> Bool {
        let metadata = loadMetadata(for: promptID)
        let endpointString = currentEndpoint.absoluteString

        if let lastProvider = metadata.lastProvider,
           (lastProvider != currentProvider || metadata.lastProviderEndpoint != endpointString) {
            AppLog.dictation.log("Provider changed for prompt \(promptID): \(lastProvider) → \(currentProvider), clearing history")
            clearHistory(for: promptID)
            return true
        }
        return false
    }

    /// Update provider information in metadata
    func updateProvider(for promptID: UUID, provider: String, endpoint: URL) {
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            var metadata = self.loadMetadata(for: promptID)
            metadata.lastProvider = provider
            metadata.lastProviderEndpoint = endpoint.absoluteString
            metadata.updatedAt = Date()
            self.saveMetadata(metadata, for: promptID)
        }
    }

    // MARK: - Private Helpers

    private func loadMetadata(for promptID: UUID) -> ConversationHistoryMetadata {
        let metadataFile = conversationsDir.appendingPathComponent("\(promptID.uuidString)_metadata.json")
        guard FileManager.default.fileExists(atPath: metadataFile.path),
              let data = try? Data(contentsOf: metadataFile) else {
            return ConversationHistoryMetadata()
        }
        do {
            return try decoder.decode(ConversationHistoryMetadata.self, from: data)
        } catch {
            AppLog.dictation.error("Failed to decode metadata for prompt \(promptID): \(error)")
            return ConversationHistoryMetadata()
        }
    }

    private func saveMetadata(_ metadata: ConversationHistoryMetadata, for promptID: UUID) {
        let metadataFile = conversationsDir.appendingPathComponent("\(promptID.uuidString)_metadata.json")
        do {
            let data = try encoder.encode(metadata)
            try data.write(to: metadataFile, options: .atomic)
        } catch {
            AppLog.dictation.error("Failed to save metadata for prompt \(promptID): \(error)")
        }
    }

    private func saveMessages(_ messages: [PromptConversationMessage], for promptID: UUID) {
        let messagesFile = conversationsDir.appendingPathComponent("\(promptID.uuidString)_messages.json")
        do {
            let data = try encoder.encode(messages)
            try data.write(to: messagesFile, options: .atomic)
        } catch {
            AppLog.dictation.error("Failed to save messages for prompt \(promptID): \(error)")
        }
    }

    private func updateMetadata(for promptID: UUID) {
        var metadata = loadMetadata(for: promptID)
        metadata.updatedAt = Date()
        saveMetadata(metadata, for: promptID)
    }
}
