import Foundation

public enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case http(status: Int, body: String)
    case decodingFailed
    case notImplemented
    case networkError(String)
    case connectionFailed
    case invalidAPIKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not available"
        case .invalidURL: return "Invalid URL"
        case .http(let status, let body): return "HTTP error (\(status)): \(body)"
        case .decodingFailed: return "Response decoding failed"
        case .notImplemented: return "Not implemented"
        case .networkError(let message): return "Network error: \(message)"
        case .connectionFailed: return "WebSocket connection failed"
        case .invalidAPIKey(let message): return "Invalid API key: \(message)"
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .missingAPIKey:
            return "missingAPIKey"
        case .invalidURL:
            return "invalidURL"
        case .http(let status, let body):
            return "http status=\(status) body=\(body.prefix(1000))"
        case .decodingFailed:
            return "decodingFailed"
        case .notImplemented:
            return "notImplemented"
        case .networkError(let message):
            return "networkError message=\(message)"
        case .connectionFailed:
            return "connectionFailed"
        case .invalidAPIKey(let message):
            return "invalidAPIKey message=\(message)"
        }
    }
}

public struct TranscriptionSettings {
    public let endpoint: URL
    public let model: String
    public let timeout: TimeInterval
    public let language: String?
    public let vocabularyTerms: [String]
    // Optional context label to help diagnose where requests originate (e.g., "hotkey", "reprocess")
    public let context: String?
    public init(endpoint: URL,
                model: String,
                timeout: TimeInterval = 180,
                language: String? = nil,
                vocabularyTerms: [String] = [],
                context: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.language = language
        self.vocabularyTerms = vocabularyTerms
        self.context = context
    }
}

enum VoiceVocabularyKeyterms {
    static let maxTerms = 100
    static let maxCharactersPerTerm = 50

    static func terms(customVocabulary: String, spellingCorrections: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        func add(_ raw: String) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxCharactersPerTerm else { return }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return }
            result.append(term)
        }

        let separators = CharacterSet(charactersIn: ",\n\r")
        for item in customVocabulary.components(separatedBy: separators) {
            add(item)
            if result.count >= maxTerms { return result }
        }

        for line in spellingCorrections.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "->")
            guard parts.count >= 2 else { continue }
            add(parts[1...].joined(separator: "->"))
            if result.count >= maxTerms { return result }
        }

        return result
    }
}

public protocol TranscriptionProvider {
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String
}

public struct LLMSettings {
    public let endpoint: URL
    public let model: String
    public let systemPrompt: String?
    public let timeout: TimeInterval
    public let streaming: Bool
    public let temperature: Double
    public let openRouterReasoning: OpenRouterReasoningMode
    public init(endpoint: URL, model: String, systemPrompt: String? = nil, timeout: TimeInterval = 60, streaming: Bool = false, temperature: Double = 0.2, openRouterReasoning: OpenRouterReasoningMode = .omit) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.timeout = timeout
        self.streaming = streaming
        self.temperature = temperature
        self.openRouterReasoning = openRouterReasoning
    }
}

public enum OpenRouterReasoningMode: String, CaseIterable, Codable, Hashable {
    case omit
    case off
    case minimal
    case low
    case medium

    public var displayName: String {
        switch self {
        case .omit: return "Omit"
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        }
    }

    public var detail: String {
        switch self {
        case .omit:
            return "Send no reasoning field for broad model compatibility."
        case .off:
            return "Request reasoning off where the model/provider supports effort none."
        case .minimal:
            return "Use the smallest supported thinking level, useful for Gemini thinking models."
        case .low:
            return "Allow a small reasoning budget."
        case .medium:
            return "Allow the provider's normal medium reasoning mode."
        }
    }
}

public struct LLMImageAttachment {
    public enum Detail: String {
        case auto
        case low
        case medium
        case high
    }

    public let data: Data
    public let mimeType: String
    public let detail: Detail
    public let filename: String?

    public init(data: Data, mimeType: String, detail: Detail = .high, filename: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.detail = detail
        self.filename = filename
    }
}

public protocol LLMProvider {
    func process(text: String, userPrompt: String, settings: LLMSettings, imageAttachment: LLMImageAttachment?) async throws -> String
}

public extension LLMProvider {
    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        try await process(text: text, userPrompt: userPrompt, settings: settings, imageAttachment: nil)
    }
}
