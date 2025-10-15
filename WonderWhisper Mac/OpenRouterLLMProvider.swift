import Foundation

final class OpenRouterLLMProvider: LLMProvider {
    private let client: OpenRouterHTTPClient
    private let routingPrefProvider: () -> String // returns "latency" or "throughput"

    init(client: OpenRouterHTTPClient, routingPrefProvider: @escaping () -> String = { UserDefaults.standard.string(forKey: "llm.openrouter.routing") ?? "latency" }) {
        self.client = client
        self.routingPrefProvider = routingPrefProvider
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
        var typed: [OpenRouterHTTPClient.ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            typed.append(.init(role: "system", text: system, attachment: nil))
        }
        typed.append(.init(role: "user", text: text, attachment: imageAttachment))
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typed.append(.init(role: "user", text: userPrompt, attachment: nil))
        }

        // Apply routing preference via provider.sort per OpenRouter docs (latency|throughput|price)
        let pref = routingPrefProvider().lowercased()
        let sort: String
        switch pref {
        case "throughput": sort = "throughput"
        case "price": sort = "price"
        default: sort = "latency"
        }
        let provider = OpenRouterHTTPClient.ChatRequest.ProviderOptions(sort: sort)

        let req = OpenRouterHTTPClient.ChatRequest(model: settings.model, messages: typed, temperature: 0.2, stream: settings.streaming ? true : nil, provider: provider)
        if settings.streaming {
            let aggregated = try await client.postChatStream(to: settings.endpoint, body: req, timeout: settings.timeout)
            return Self.extractFormattedText(from: aggregated)
        } else {
            let data = try await client.postChat(to: settings.endpoint, body: req, timeout: settings.timeout)
            if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data), let content = decoded.choices.first?.message.content {
                return Self.extractFormattedText(from: content)
            }
            // Fallback dynamic parse
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = json["choices"] as? [[String: Any]], let first = choices.first, let message = first["message"] as? [String: Any], let content = message["content"] as? String {
                return Self.extractFormattedText(from: content)
            }
            throw ProviderError.decodingFailed
        }
    }

    private static func extractFormattedText(from response: String) -> String {
        if let o = response.range(of: "<FORMATTED_TEXT>", options: .caseInsensitive),
           let c = response.range(of: "</FORMATTED_TEXT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
