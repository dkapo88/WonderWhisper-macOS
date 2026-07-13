import Foundation
import OSLog

struct OpenRouterHTTPClient {
    let apiKeyProvider: () -> String?
    static let log = OSLog(subsystem: AppConfig.bundleIdentifier, category: "OpenRouter")

    static let session: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 15, maxConnections: 8)
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private func authHeader() throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ProviderError.missingAPIKey }
        return "Bearer \(key)"
    }

    // Fetch full model information from OpenRouter
    func fetchModels() async throws -> [OpenRouterModel] {
        var req = URLRequest(url: AppConfig.openrouterModels, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        // Authorization is optional for /models; include if we have a key
        if let key = apiKeyProvider(), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(AppConfig.openrouterTitle, forHTTPHeaderField: "X-Title")
        req.setValue(AppConfig.openrouterReferer, forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.networkError("No HTTP response") }
        guard (200...299).contains(http.statusCode) else { throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>") }
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenRouterModelsResponse.self, from: data)
        return response.data
    }

    func fetchTranscriptionModels() async throws -> [OpenRouterModel] {
        guard var components = URLComponents(url: AppConfig.openrouterModels, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "output_modalities", value: "transcription")]
        guard let url = components.url else { throw ProviderError.invalidURL }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        if let key = apiKeyProvider(), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(AppConfig.openrouterTitle, forHTTPHeaderField: "X-Title")
        req.setValue(AppConfig.openrouterReferer, forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<no body>"
            )
        }

        let response = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        return response.data
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            struct ContentBlock: Encodable {
                struct ImageURL: Encodable { let url: String; let detail: String? }
                let type: String
                let text: String?
                let image_url: ImageURL?
            }

            enum Content: Encodable {
                case text(String)
                case blocks([ContentBlock])

                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let value):
                        try container.encode(value)
                    case .blocks(let parts):
                        try container.encode(parts)
                    }
                }
            }

            let role: String
            let content: Content

            init(role: String, text: String, attachment: LLMImageAttachment?) {
                self.role = role
                if let attachment {
                    var blocks: [ContentBlock] = []
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.init(type: "text", text: text, image_url: nil))
                    }
                    let base64 = attachment.data.base64EncodedString()
                    let url = "data:\(attachment.mimeType);base64,\(base64)"
                    let imageURL = ContentBlock.ImageURL(url: url, detail: attachment.detail.rawValue)
                    blocks.append(.init(type: "image_url", text: nil, image_url: imageURL))
                    self.content = .blocks(blocks)
                } else {
                    self.content = .text(text)
                }
            }
        }
        struct ProviderOptions: Encodable { let sort: String }
        struct ReasoningOptions: Encodable {
            static let disabled = ReasoningOptions(effort: "none", enabled: nil, exclude: true)

            let effort: String?
            let enabled: Bool?
            let exclude: Bool?

            init(effort: String? = nil, enabled: Bool? = nil, exclude: Bool? = nil) {
                self.effort = effort
                self.enabled = enabled
                self.exclude = exclude
            }
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let provider: ProviderOptions?
        let reasoning: ReasoningOptions?

        init(
            model: String,
            messages: [Message],
            temperature: Double,
            provider: ProviderOptions?,
            reasoning: ReasoningOptions? = nil
        ) {
            self.model = model
            self.messages = messages
            self.temperature = temperature
            self.provider = provider
            self.reasoning = reasoning
        }
    }

    // Non-streaming chat
    func postChat(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.openrouterTitle, forHTTPHeaderField: "X-Title")
        req.setValue(AppConfig.openrouterReferer, forHTTPHeaderField: "Referer")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)
        let (data, resp) = try await Self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return data
    }

    struct TranscriptionRequest: Encodable {
        struct InputAudio: Encodable {
            let data: String
            let format: String
        }

        let input_audio: InputAudio
        let model: String
        let language: String?
        let temperature: Double?
    }

    func postTranscription(to url: URL, body: TranscriptionRequest, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.openrouterTitle, forHTTPHeaderField: "X-Title")
        req.setValue(AppConfig.openrouterReferer, forHTTPHeaderField: "Referer")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await Self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<no body>"
            )
        }
        return data
    }

}
