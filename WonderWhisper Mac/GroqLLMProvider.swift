import Foundation

final class GroqLLMProvider: LLMProvider {
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
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
                    case .text(let text):
                        try container.encode(text)
                    case .blocks(let blocks):
                        try container.encode(blocks)
                    }
                }
            }

            let role: String
            let content: Content

            init(role: String, text: String, attachment: LLMImageAttachment?) {
                self.role = role
                if let attachment {
                    var items: [ContentBlock] = []
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(.init(type: "text", text: text, image_url: nil))
                    }
                    let base64 = attachment.data.base64EncodedString()
                    let url = "data:\(attachment.mimeType);base64,\(base64)"
                    items.append(.init(type: "image_url", text: nil, image_url: .init(url: url, detail: attachment.detail.rawValue)))
                    self.content = .blocks(items)
                } else {
                    self.content = .text(text)
                }
            }
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool?
        // Groq OSS reasoning controls (conditionally included for GPT-OSS models)
        let reasoning_effort: String?
        let include_reasoning: Bool?
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let role: String; let content: String }
            let index: Int
            let message: Message
        }
        let choices: [Choice]
    }

    func process(text: String, userPrompt: String, settings: LLMSettings, imageAttachment: LLMImageAttachment?) async throws -> String {
        var typedMessages: [ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            typedMessages.append(.init(role: "system", text: system, attachment: nil))
        }
        // The 'text' here is the structured context message (<TRANSCRIPT>... etc.)
        typedMessages.append(.init(role: "user", text: text, attachment: imageAttachment))
        // Optional user addendum
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typedMessages.append(.init(role: "user", text: userPrompt, attachment: nil))
        }

        let isGptOss = settings.model.contains("gpt-oss")
        let req = ChatRequest(
            model: settings.model,
            messages: typedMessages,
            temperature: settings.temperature,
            stream: settings.streaming ? true : nil,
            reasoning_effort: isGptOss ? "low" : nil,
            include_reasoning: isGptOss ? false : nil
        )
        if settings.streaming {
            // Use streaming to reduce time-to-first-token; aggregate full content before returning
            let aggregated = try await client.postJSONEncodableStream(to: settings.endpoint, body: req, timeout: settings.timeout)
            return Self.extractFormattedText(from: aggregated)
        } else {
            let data = try await client.postJSONEncodable(to: settings.endpoint, body: req, timeout: settings.timeout)
            // Prefer typed decode first for performance
            if let decoded = try? Self.sharedDecoder.decode(ChatResponse.self, from: data),
               let content = decoded.choices.first?.message.content {
                return Self.extractFormattedText(from: content)
            }
            // Fallback dynamic parse for resiliency
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return Self.extractFormattedText(from: content)
            }
            throw ProviderError.decodingFailed
        }
    }

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static func extractFormattedText(from response: String) -> String {
        // Case-insensitive extraction of content between <FORMATTED_TEXT> tags without allocating a full lowercased copy
        if let o = response.range(of: "<FORMATTED_TEXT>", options: .caseInsensitive),
           let c = response.range(of: "</FORMATTED_TEXT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
