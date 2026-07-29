import Foundation
import OSLog

final class OpenRouterLLMProvider {
    private let client: OpenRouterHTTPClient
    private let routingPrefProvider: () -> String // returns "latency" or "throughput"
    private static let log = OSLog(subsystem: AppConfig.bundleIdentifier, category: "OpenRouterLLM")

    init(client: OpenRouterHTTPClient, routingPrefProvider: @escaping () -> String = { AppConfig.defaults.string(forKey: "llm.openrouter.routing") ?? "latency" }) {
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

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let code: Int?
            let message: String
        }

        let error: APIError
    }

    func process(text: String, userPrompt: String, settings: LLMSettings, imageAttachment: LLMImageAttachment?) async throws -> String {
        let startTime = Date()
        let hasImage = imageAttachment != nil
        // The gateway travels with the model: a `vercel:` prefix routes to the Vercel AI
        // Gateway (prefix stripped on the wire), anything else uses `settings.endpoint`.
        let route = AppConfig.llmRoute(for: settings.model)
        let endpoint = settings.model.hasPrefix(AppConfig.vercelModelPrefix)
            ? route.endpoint
            : settings.endpoint
        var typed: [OpenRouterHTTPClient.ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            typed.append(.init(role: "system", text: system, attachment: nil))
        }
        typed.append(.init(role: "user", text: text, attachment: imageAttachment))
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typed.append(.init(role: "user", text: userPrompt, attachment: nil))
        }

        let (provider, reasoning) = Self.gatewayRequestOptions(
            endpoint: endpoint,
            routingPref: routingPrefProvider(),
            reasoningMode: settings.openRouterReasoning
        )

        let req = OpenRouterHTTPClient.ChatRequest(
            model: route.requestModel,
            messages: typed,
            temperature: settings.temperature,
            provider: provider,
            reasoning: reasoning
        )

        // Use extended timeout for multimodal requests (image + text)
        // Image requests take longer due to base64 encoding and vision model processing
        let effectiveTimeout = hasImage ? max(settings.timeout * 1.5, 120) : settings.timeout

        os_log("LLM request started - model: %{public}@, has_image: %{public}@, timeout: %.0fs, detail_level: %{public}@, reasoning: %{public}@",
               log: OpenRouterLLMProvider.log,
               type: .debug,
               settings.model,
               hasImage ? "yes" : "no",
               effectiveTimeout,
               imageAttachment?.detail.rawValue ?? "none",
               settings.openRouterReasoning.rawValue)

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
            let aggregated = try await client.postChat(
                to: endpoint,
                body: req,
                timeout: effectiveTimeout
            )
            let elapsed = Date().timeIntervalSince(startTime)
            os_log("LLM request completed in %.2fs", log: OpenRouterLLMProvider.log, type: .debug, elapsed)
            return try Self.decodeContent(from: aggregated)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            os_log("LLM request failed after %.2fs: %{public}@", log: OpenRouterLLMProvider.log, type: .error, elapsed, error.localizedDescription)
            throw error
        }
    }

    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        try await process(
            text: text,
            userPrompt: userPrompt,
            settings: settings,
            imageAttachment: nil
        )
    }

    private static func reasoningOptions(for mode: OpenRouterReasoningMode) -> OpenRouterHTTPClient.ChatRequest.ReasoningOptions? {
        switch mode {
        case .omit:
            return nil
        case .off:
            return .disabled
        case .minimal, .low, .medium:
            return .init(effort: mode.rawValue, exclude: true)
        }
    }

    /// The gateway-dependent request fields, as one pure decision so it is testable.
    /// Vercel AI Gateway speaks the same OpenAI-compatible protocol with the same
    /// `provider/model` IDs, but OpenRouter's `provider.sort` routing and `reasoning`
    /// objects are not part of its schema, so both are omitted there.
    /// Routing: "auto" (default) sends no provider preference on OpenRouter either.
    static func gatewayRequestOptions(
        endpoint: URL,
        routingPref: String,
        reasoningMode: OpenRouterReasoningMode
    ) -> (provider: OpenRouterHTTPClient.ChatRequest.ProviderOptions?,
          reasoning: OpenRouterHTTPClient.ChatRequest.ReasoningOptions?) {
        guard endpoint.host != "ai-gateway.vercel.sh" else { return (nil, nil) }
        let provider: OpenRouterHTTPClient.ChatRequest.ProviderOptions?
        switch routingPref.lowercased() {
        case "throughput", "latency":
            provider = .init(sort: routingPref.lowercased())
        default:
            provider = nil
        }
        return (provider, reasoningOptions(for: reasoningMode))
    }

    static func decodeContent(from data: Data) throws -> String {
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
           let content = decoded.choices.first?.message.content {
            return extractFormattedText(from: content)
        }
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw ProviderError.http(
                status: decoded.error.code ?? 500,
                body: decoded.error.message
            )
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return extractFormattedText(from: content)
        }
        throw ProviderError.decodingFailed
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
