import Foundation
import OSLog

struct CerebrasHTTPClient {
    let apiKeyProvider: () -> String?
    static let log = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Cerebras")

    private func authHeader() throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ProviderError.missingAPIKey }
        return "Bearer \(key)"
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool?
    }

    // Non-streaming chat
    func postChat(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)
        let (data, resp) = try await GroqHTTPClient.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return data
    }

    // Streaming chat (SSE) returns accumulated content
    func postChatStream(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var aggregated = ""
                let (bytes, response) = try await GroqHTTPClient.session.bytes(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    var bodySample = ""
                    for try await line in bytes.lines {
                        bodySample += line + "\n"
                        if bodySample.count > 8192 { break }
                    }
                    throw ProviderError.http(status: http.statusCode, body: bodySample)
                }
                for try await line in bytes.lines {
                    if line.hasPrefix(":") { continue } // keepalive/comment
                    guard line.hasPrefix("data:") else { continue }
                    var payload = String(line.dropFirst(5)) // after "data:"
                    if payload.hasPrefix(" ") { payload.removeFirst() }
                    if payload == "[DONE]" { break }
                    if let data = payload.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = obj["choices"] as? [[String: Any]],
                       let first = choices.first {
                        if let delta = first["delta"] as? [String: Any], let part = delta["content"] as? String {
                            aggregated += part
                        } else if let msg = first["message"] as? [String: Any], let part = msg["content"] as? String {
                            aggregated += part
                        }
                    }
                }
                return aggregated
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1.0, timeout) * 1_000_000_000))
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Stream timed out after \(Int(timeout))s"]) }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "No stream result"]) }
            return result
        }
    }
}

