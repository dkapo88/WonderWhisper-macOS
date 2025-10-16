import Foundation
import OSLog

final class OllamaLLMProvider: LLMProvider {
    private let client: OllamaHTTPClient
    
    init(client: OllamaHTTPClient) {
        self.client = client
    }
    
    func process(text: String, userPrompt: String, settings: LLMSettings, imageAttachment: LLMImageAttachment?) async throws -> String {
        var typedMessages: [OllamaHTTPClient.ChatRequest.Message] = []
        
        // Add system message if provided
        if let system = settings.systemPrompt, !system.isEmpty {
            typedMessages.append(.init(role: "system", text: system, attachment: nil))
        }
        
        // Add the structured context message with optional image attachment
        typedMessages.append(.init(role: "user", text: text, attachment: imageAttachment))
        
        // Add optional user addendum
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typedMessages.append(.init(role: "user", text: userPrompt, attachment: nil))
        }
        
        // Create request with temperature control
        let req = OllamaHTTPClient.ChatRequest(
            model: settings.model,
            messages: typedMessages,
            temperature: settings.temperature,
            stream: settings.streaming,  // Explicitly set to false when not streaming
            options: OllamaHTTPClient.ChatRequest.Options(
                temperature: settings.temperature,
                num_predict: nil
            )
        )
        
        if settings.streaming {
            // Use streaming to reduce time-to-first-token; aggregate full content before returning
            let aggregated = try await client.postChatStream(to: settings.endpoint, body: req, timeout: settings.timeout)
            return Self.extractFormattedText(from: aggregated)
        } else {
            // Non-streaming request
            let data = try await client.postChat(to: settings.endpoint, body: req, timeout: settings.timeout)
            
            // Try typed decode first for performance
            do {
                let decoded = try JSONDecoder().decode(OllamaHTTPClient.ChatResponse.self, from: data)
                return Self.extractFormattedText(from: decoded.message.content)
            } catch {
                AppLog.network.error("Ollama response decode error: \(error.localizedDescription)")
                if let responseStr = String(data: data, encoding: .utf8) {
                    AppLog.network.error("Response was: \(responseStr)")
                }
            }
            
            // Fallback dynamic parse for resiliency
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return Self.extractFormattedText(from: content)
            }
            
            throw ProviderError.decodingFailed
        }
    }
    
    private static func extractFormattedText(from response: String) -> String {
        // Case-insensitive extraction of content between <FORMATTED_TEXT> tags
        if let o = response.range(of: "<FORMATTED_TEXT>", options: .caseInsensitive),
           let c = response.range(of: "</FORMATTED_TEXT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
