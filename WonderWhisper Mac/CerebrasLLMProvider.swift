import Foundation
import OSLog

final class CerebrasLLMProvider: LLMProvider {
    private let client: CerebrasHTTPClient

    init(client: CerebrasHTTPClient) {
        self.client = client
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let role: String; let content: String }
            let index: Int
            let message: Message
        }
        let choices: [Choice]
    }

    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        var messages: [CerebrasHTTPClient.ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: text))
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.init(role: "user", content: userPrompt))
        }

        let req = CerebrasHTTPClient.ChatRequest(
            model: settings.model,
            messages: messages,
            temperature: 0.2,
            stream: settings.streaming ? true : nil,
            reasoning_effort: settings.model.contains("gpt-oss") ? "low" : nil
        )

        if settings.streaming {
            do {
                let aggregated = try await client.postChatStream(to: settings.endpoint, body: req, timeout: settings.timeout)
                return Self.extractFormattedText(from: aggregated)
            } catch {
                let ns = error as NSError
                let transient = (ns.domain == NSURLErrorDomain) && (ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost || ns.code == NSURLErrorNotConnectedToInternet)
                if transient {
                    AppLog.network.error("Cerebras SSE failed transiently; falling back to non-streaming")
                    let nonStreamReq = CerebrasHTTPClient.ChatRequest(
                        model: req.model,
                        messages: req.messages,
                        temperature: req.temperature,
                        stream: nil,
                        reasoning_effort: req.reasoning_effort
                    )
                    let data = try await client.postChat(to: settings.endpoint, body: nonStreamReq, timeout: max(30, settings.timeout))
                    if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data), let content = decoded.choices.first?.message.content {
                        return Self.extractFormattedText(from: content)
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return Self.extractFormattedText(from: content)
                    }
                    throw ProviderError.decodingFailed
                } else {
                    throw error
                }
            }
        } else {
            let data = try await client.postChat(to: settings.endpoint, body: req, timeout: settings.timeout)
            if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data), let content = decoded.choices.first?.message.content {
                return Self.extractFormattedText(from: content)
            }
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

    private static func extractFormattedText(from response: String) -> String {
        if let o = response.range(of: "<FORMATTED_TEXT>", options: .caseInsensitive),
           let c = response.range(of: "</FORMATTED_TEXT>", options: .caseInsensitive) {
            let inner = response[o.upperBound..<c.lowerBound]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
