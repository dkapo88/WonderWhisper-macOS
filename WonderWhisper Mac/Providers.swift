import Foundation

public enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case http(status: Int, body: String)
    case decodingFailed
    case notImplemented
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not available"
        case .invalidURL: return "Invalid URL"
        case .http(let status, let body): return "HTTP error (\(status)): \(body)"
        case .decodingFailed: return "Response decoding failed"
        case .notImplemented: return "Not implemented"
        case .networkError(let message): return "Network error: \(message)"
        }
    }
}

public struct TranscriptionSettings {
    public let endpoint: URL
    public let model: String
    public let timeout: TimeInterval
    // Optional context label to help diagnose where requests originate (e.g., "hotkey", "reprocess")
    public let context: String?
    public init(endpoint: URL, model: String, timeout: TimeInterval = 180, context: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.context = context
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
    public init(endpoint: URL, model: String, systemPrompt: String? = nil, timeout: TimeInterval = 60, streaming: Bool = false) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.timeout = timeout
        self.streaming = streaming
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
