import Foundation
import OSLog

final class OpenRouterLLMProvider: LLMProvider {
    private let client: OpenRouterHTTPClient
    private let routingPrefProvider: () -> String // returns "latency" or "throughput"
    private static let log = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "OpenRouterLLM")

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
        let startTime = Date()
        let hasImage = imageAttachment != nil

        var typed: [OpenRouterHTTPClient.ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            typed.append(.init(role: "system", text: system, attachment: nil))
        }
        typed.append(.init(role: "user", text: text, attachment: imageAttachment))
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typed.append(.init(role: "user", text: userPrompt, attachment: nil))
        }

        // Apply routing preference via provider.sort per OpenRouter docs (latency|throughput|price)
        // "auto" (default) sends no provider preferences
        let pref = routingPrefProvider().lowercased()
        let provider: OpenRouterHTTPClient.ChatRequest.ProviderOptions?
        
        switch pref {
        case "throughput": 
            provider = .init(sort: "throughput")
        case "latency": 
            provider = .init(sort: "latency")
        default: 
            provider = nil
        }

        let req = OpenRouterHTTPClient.ChatRequest(model: settings.model, messages: typed, temperature: settings.temperature, stream: settings.streaming ? true : nil, provider: provider)

        // Use extended timeout for multimodal requests (image + text)
        // Image requests take longer due to base64 encoding and vision model processing
        let effectiveTimeout = hasImage ? max(settings.timeout * 1.5, 120) : settings.timeout

        os_log("LLM request started - model: %{public}@, has_image: %{public}@, timeout: %.0fs, detail_level: %{public}@",
               log: OpenRouterLLMProvider.log,
               type: .debug,
               settings.model,
               hasImage ? "yes" : "no",
               effectiveTimeout,
               imageAttachment?.detail.rawValue ?? "none")

        if hasImage, let imageData = imageAttachment?.data {
            let imageSizeKB = Double(imageData.count) / 1024.0
            let base64Size = (imageData.count * 4 / 3) / 1024  // Approximate base64 overhead
            os_log("Image details - size: %.1f KB, base64 payload: ~%d KB",
                   log: OpenRouterLLMProvider.log,
                   type: .debug,
                   imageSizeKB,
                   base64Size)
        }

        do {
            if settings.streaming {
                let aggregated = try await client.postChatStream(to: settings.endpoint, body: req, timeout: effectiveTimeout)
                let elapsed = Date().timeIntervalSince(startTime)
                os_log("LLM streaming completed in %.2fs", log: OpenRouterLLMProvider.log, type: .debug, elapsed)
                return Self.extractFormattedText(from: aggregated)
            } else {
                let aggregated = try await client.postChat(to: settings.endpoint, body: req, timeout: effectiveTimeout)
                let elapsed = Date().timeIntervalSince(startTime)
                os_log("LLM request completed in %.2fs", log: OpenRouterLLMProvider.log, type: .debug, elapsed)
                if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: aggregated), let content = decoded.choices.first?.message.content {
                    return Self.extractFormattedText(from: content)
                }
                // Fallback dynamic parse
                if let json = try? JSONSerialization.jsonObject(with: aggregated) as? [String: Any], let choices = json["choices"] as? [[String: Any]], let first = choices.first, let message = first["message"] as? [String: Any], let content = message["content"] as? String {
                    return Self.extractFormattedText(from: content)
                }
                throw ProviderError.decodingFailed
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            os_log("LLM request failed after %.2fs: %{public}@", log: OpenRouterLLMProvider.log, type: .error, elapsed, error.localizedDescription)
            throw error
        }
    }

    private static func extractFormattedText(from response: String) -> String {
        // Try OUTPUT tag first
        if let o = response.range(of: "<OUTPUT>", options: .caseInsensitive),
           let c = response.range(of: "</OUTPUT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback to legacy FORMATTED_TEXT tag for backward compatibility
        if let o = response.range(of: "<FORMATTED_TEXT>", options: .caseInsensitive),
           let c = response.range(of: "</FORMATTED_TEXT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
