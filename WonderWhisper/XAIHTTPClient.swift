import Foundation
import OSLog
import os.signpost

struct XAIHTTPClient {
    struct MultipartFile {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    let apiKeyProvider: () -> String?

    private static let spLog = OSLog(
        subsystem: "com.danekapoor.hermeswhisper",
        category: "XAI-Network-SP"
    )

    private static let session: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 20, maxConnections: 4)
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    private func authHeader() throws -> String {
        guard let rawKey = apiKeyProvider() else { throw ProviderError.missingAPIKey }
        let key = KeychainService.normalizedSecret(rawKey)
        guard !key.isEmpty else { throw ProviderError.missingAPIKey }
        return "Bearer \(key)"
    }

    func postMultipart(
        to url: URL,
        fields: [(String, String)],
        file: MultipartFile,
        timeout: TimeInterval,
        context: String?
    ) async throws -> Data {
        let reqID = UUID().uuidString
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let estimatedOverhead = (fields.count * 128) + 512 + 1024
        body.reserveCapacity(file.data.count + estimatedOverhead)

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqID, forHTTPHeaderField: "X-WW-Request-ID")
        request.networkServiceType = .voice
        request.httpBody = body

        let signpostID = OSSignpostID(log: Self.spLog)
        os_signpost(
            .begin,
            log: Self.spLog,
            name: "XAIUpload",
            signpostID: signpostID,
            "req=%{public}s bytes=%{public}lu",
            reqID,
            UInt(body.count)
        )
        defer {
            os_signpost(.end, log: Self.spLog, name: "XAIUpload", signpostID: signpostID)
        }

        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<no body>"
            )
        }
        return data
    }
}
