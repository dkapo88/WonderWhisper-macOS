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
                    var parts: [ContentBlock] = []
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parts.append(.init(type: "text", text: text, image_url: nil))
                    }
                    let base64 = attachment.data.base64EncodedString()
                    let url = "data:\(attachment.mimeType);base64,\(base64)"
                    let imageURL = ContentBlock.ImageURL(url: url, detail: attachment.detail.rawValue)
                    parts.append(.init(type: "image_url", text: nil, image_url: imageURL))
                    self.content = .blocks(parts)
                } else {
                    self.content = .text(text)
                }
            }
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool?
        let reasoning_effort: String?
    }

    // Build a URLSession configured for the given timeout and protocol preference.
    private func makeSession(timeout: TimeInterval, http2: Bool) -> URLSession {
        let cfg = NetworkConfiguration.createConfiguration(timeout: max(1.0, timeout), maxConnections: 8)
        cfg.timeoutIntervalForResource = max(2.0, timeout * 2)
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }

    // Non-streaming chat (with retry + HTTP/2 fallback for flaky networks)
    func postChat(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)

        // Use global protocol preference via NetworkConfiguration
        let session = makeSession(timeout: timeout, http2: false) // Protocol preference is applied by NetworkConfiguration

        var attempt = 0
        var lastError: Error?
        while attempt < 3 {
            attempt += 1
            let reqId = UUID().uuidString
            var attemptReq = req
            attemptReq.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
            attemptReq.setValue("cerebras.chat", forHTTPHeaderField: "X-WW-Context")

            do {
                AppLog.network.log("Cerebras chat attempt=\(attempt)")
                let (data, resp) = try await dataWithAttemptTimeout_Cerebras(for: attemptReq, session: session)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
                }
                return data
            } catch {
                lastError = error
                let ns = error as NSError
                let code = ns.code
                let domain = ns.domain
                AppLog.network.error("Cerebras chat attempt=\(attempt) error=\(ns.localizedDescription) domain=\(domain) code=\(code)")
                let transient = (domain == NSURLErrorDomain) && (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotConnectToHost || code == NSURLErrorCannotFindHost || code == NSURLErrorNotConnectedToInternet)
                if attempt >= 3 || !transient { break }
                let base: Double = 0.6
                let backoff = pow(2.0, Double(attempt - 1)) * base
                let jitter = Double.random(in: 0...(base * 0.5))
                let delay = backoff + jitter
                AppLog.network.log("Retrying Cerebras chat in \(String(format: "%.2f", delay))s (attempt \(attempt+1)/3)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? ProviderError.notImplemented
    }

    // Streaming chat (SSE) returns accumulated content, with retry + HTTP/2 fallback
    func postChatStream(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)

        // Use global protocol preference via NetworkConfiguration
        let session = makeSession(timeout: timeout, http2: false) // Protocol preference is applied by NetworkConfiguration

        var attempt = 0
        var lastError: Error?
        while attempt < 3 {
            attempt += 1
            let reqId = UUID().uuidString
            var attemptReq = req
            attemptReq.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
            attemptReq.setValue("cerebras.chat.sse", forHTTPHeaderField: "X-WW-Context")
            do {
                AppLog.network.log("Cerebras SSE attempt=\(attempt)")
                // Per-attempt wall-clock timeout
                let result: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        var aggregated = ""
                        let (bytes, response) = try await session.bytes(for: attemptReq)
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
                return result
            } catch {
                lastError = error
                let ns = error as NSError
                let code = ns.code
                let domain = ns.domain
                AppLog.network.error("Cerebras SSE attempt=\(attempt) error=\(ns.localizedDescription) domain=\(domain) code=\(code)")
                let transient = (domain == NSURLErrorDomain) && (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotConnectToHost || code == NSURLErrorCannotFindHost || code == NSURLErrorNotConnectedToInternet)
                if attempt >= 3 || !transient { break }
                let base: Double = 0.6
                let backoff = pow(2.0, Double(attempt - 1)) * base
                let jitter = Double.random(in: 0...(base * 0.5))
                let delay = backoff + jitter
                AppLog.network.log("Retrying Cerebras SSE in \(String(format: "%.2f", delay))s (attempt \(attempt+1)/3)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? ProviderError.notImplemented
    }
}

// MARK: - Local helpers (scoped to Cerebras)
private func dataWithAttemptTimeout_Cerebras(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
    let timeout = max(1.0, request.timeoutInterval)
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask { try await session.data(for: request) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Attempt timed out after \(Int(timeout))s"]) }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "No result"]) }
        return result
    }
}
