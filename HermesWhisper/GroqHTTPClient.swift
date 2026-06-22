import Foundation
import OSLog
import os.signpost

struct GroqHTTPClient {
    let apiKeyProvider: () -> String?
    static let spLog = OSLog(subsystem: AppConfig.bundleIdentifier, category: "Network-SP")

    // Connection pre-warming for faster subsequent requests
    static func preWarmConnection(to url: URL) {
        Task {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 5.0
                // Warm both the default session (used for JSON chat) and the priority session (used in some uploads)
                let req1 = request
                let req2 = request
                async let warm1: (Data, URLResponse) = session.data(for: req1)
                async let warm2: (Data, URLResponse) = prioritySession.data(for: req2)
                _ = try await warm1
                _ = try await warm2
            } catch {
                // Ignore pre-warming errors
            }
        }
    }

    static let session: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 10, maxConnections: 8)
        cfg.timeoutIntervalForResource = 30
        cfg.connectionProxyDictionary = nil // Direct connections
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    // Pre-warmed session for critical requests
    static let prioritySession: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 8, maxConnections: 4)
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    static let http2Session: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 10, maxConnections: 8)
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    static let http2PrioritySession: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 8, maxConnections: 4)
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    static var http2DebugLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "network.http2.debug")
    }

    private func authHeader() throws -> String {
        guard let rawKey = apiKeyProvider() else { throw ProviderError.missingAPIKey }
        let key = KeychainService.normalizedSecret(rawKey)
        guard !key.isEmpty else { throw ProviderError.missingAPIKey }
        guard KeychainService.isPlausibleGroqAPIKey(key) else {
            throw ProviderError.invalidAPIKey("Expected a Groq key beginning with gsk_ and no whitespace.")
        }
        return "Bearer \(key)"
    }

    struct MultipartFile {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data

        // Convenience initializer for direct Data upload
        init(fieldName: String, filename: String, mimeType: String, data: Data) {
            self.fieldName = fieldName
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    func postMultipart(to url: URL, fields: [String: String], files: [MultipartFile], timeout: TimeInterval, context: String? = nil) async throws -> Data {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST Multipart [\(context ?? "-", privacy: .public)] to \(url.absoluteString, privacy: .public) with \(files.count, privacy: .public) file(s) req=\(reqId, privacy: .public)")
        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        os_signpost(.event, log: Self.spLog, name: "HW.net.upload.prepare", "req=%{public}@ bytes=%{public}ld files=%{public}ld", reqId, totalBytes, files.count)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        // Pre-reserve capacity to minimize reallocations during multipart assembly
        let filesBytes = files.reduce(0) { $0 + $1.data.count }
        let estimatedOverhead = (fields.count * 128) + (files.count * 512) + 1024
        body.reserveCapacity(filesBytes + estimatedOverhead)

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br, lzfse", forHTTPHeaderField: "Accept-Encoding")
        request.networkServiceType = .voice

        request.httpBody = body

        AppLog.network.log("Multipart body ready req=\(reqId, privacy: .public) bytes=\(body.count, privacy: .public) timeout=\(timeout, format: .fixed(precision: 1), privacy: .public)s")
        return try await performWithRetry(request: request, start: start, context: context)
    }
}

// MARK: - URLSession delegate + retry wrapper
// MARK: - URLSession delegate + retry wrapper
final class GroqURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = GroqURLSessionDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let tx = metrics.transactionMetrics.last else { return }
        let proto = tx.networkProtocolName ?? "<unknown>"
        let dns = tx.domainLookupEndDate?.timeIntervalSince(tx.domainLookupStartDate ?? tx.fetchStartDate ?? Date())
        let connect = tx.connectEndDate?.timeIntervalSince(tx.connectStartDate ?? tx.domainLookupEndDate ?? tx.fetchStartDate ?? Date())
        let tls = tx.secureConnectionEndDate?.timeIntervalSince(tx.secureConnectionStartDate ?? tx.connectStartDate ?? tx.fetchStartDate ?? Date())
        let req = tx.request
        let reqId = req.value(forHTTPHeaderField: "X-WW-Request-ID") ?? "?"
        let ctx = req.value(forHTTPHeaderField: "X-WW-Context") ?? "-"
        let ttfb = tx.responseStartDate?.timeIntervalSince(tx.requestStartDate ?? tx.fetchStartDate ?? Date())
        let transfer = tx.responseEndDate?.timeIntervalSince(tx.responseStartDate ?? tx.responseEndDate ?? Date())
        let expectH2 = req.value(forHTTPHeaderField: "X-WW-Expect-H2") == "1"
        if expectH2 && proto.lowercased() != "h2" {
            AppLog.network.error("HTTP/2 expected but negotiated \(proto) req=\(reqId) ctx=\(ctx)")
        } else if expectH2 && GroqHTTPClient.http2DebugLoggingEnabled {
            AppLog.network.log("HTTP/2 upload confirmed proto=\(proto) req=\(reqId)")
        }
        AppLog.network.log("Metrics req=\(reqId) ctx=\(ctx) proto=\(proto) dns=\(dns ?? -1)s connect=\(connect ?? -1)s tls=\(tls ?? -1)s ttfb=\(ttfb ?? -1)s transfer=\(transfer ?? -1)s")
    }
}

private func performWithRetry(request: URLRequest, start: Date, context: String?, maxAttempts: Int = 3) async throws -> Data {
    var attempt = 0
    var lastError: Error?
    while attempt < maxAttempts {
        attempt += 1
        let spId = OSSignpostID(log: GroqHTTPClient.spLog)
        os_signpost(.begin, log: GroqHTTPClient.spLog, name: "HW.net.request", signpostID: spId, "attempt=%ld ctx=%{public}@ path=%{public}@", attempt, context ?? "-", request.url?.lastPathComponent ?? "<url>")
        do {
            let (data, response) = try await dataWithAttemptTimeout(for: request, session: GroqHTTPClient.session)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let status = http.statusCode
                if status == 429 {
                    var delay: Double = 1.0
                    if let ra = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(ra) {
                        delay = max(0.1, min(10.0, seconds))
                    }
                    AppLog.network.error("HTTP 429 for \(request.url?.absoluteString ?? "<url>", privacy: .public) attempt=\(attempt, privacy: .public) retrying in \(delay, format: .fixed(precision: 2), privacy: .public)s")
                    os_signpost(.end, log: GroqHTTPClient.spLog, name: "HW.net.request", signpostID: spId)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                AppLog.network.error("HTTP \(status, privacy: .public) for \(request.url?.absoluteString ?? "<url>", privacy: .public) attempt=\(attempt, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s body=\(body.prefix(1000), privacy: .public)")
                throw ProviderError.http(status: status, body: body)
            }
            AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1), privacy: .public) for \(request.url?.lastPathComponent ?? "<url>", privacy: .public) attempt=\(attempt, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
            os_signpost(.end, log: GroqHTTPClient.spLog, name: "HW.net.request", signpostID: spId)
            return data
        } catch {
            lastError = error
            let nsErr = error as NSError
            let code = nsErr.code
            let domain = nsErr.domain
            let diagnostic = (error as? ProviderError)?.diagnosticDescription ?? "\(nsErr.domain) code=\(nsErr.code) \(nsErr.localizedDescription)"
            AppLog.network.error("Attempt \(attempt, privacy: .public) failed req=\(request.value(forHTTPHeaderField: "X-WW-Request-ID") ?? "?", privacy: .public) ctx=\(context ?? "-", privacy: .public) error=\(diagnostic, privacy: .public)")
            let shouldRetry = (domain == NSURLErrorDomain) && (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotFindHost || code == NSURLErrorCannotConnectToHost)
            os_signpost(.end, log: GroqHTTPClient.spLog, name: "HW.net.request", signpostID: spId)
            if attempt >= maxAttempts || !shouldRetry { break }
            let base: Double = 0.6
            let backoff = pow(2.0, Double(attempt - 1)) * base
            let jitter = Double.random(in: 0...(base * 0.5))
            let delay = backoff + jitter
            AppLog.network.log("Retrying in \(String(format: "%.2f", delay))s (attempt \(attempt+1)/\(maxAttempts))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    throw lastError ?? ProviderError.notImplemented
}

// Enforce per-attempt wall-clock timeout regardless of CFNetwork internals.
private func dataWithAttemptTimeout(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
    let timeout = max(1.0, request.timeoutInterval)
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
            return try await session.data(for: request)
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Attempt timed out after \(Int(timeout))s"])
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "No result"])
        }
        return result
    }
}
