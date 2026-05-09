import Foundation
import OSLog
import os.signpost

final class XAITranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(
        subsystem: "com.danekapoor.hermeswhisper",
        category: "XAI-STT-SP"
    )
    private let client: XAIHTTPClient

    init(client: XAIHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
        let language: String?
        let duration: Double?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        guard let mimeType = Self.mimeType(for: ext) else {
            throw ProviderError.networkError("xAI Speech-to-Text does not support .\(ext) audio")
        }

        let language = Self.language(for: settings)
        let cacheKey = TranscriptionCache.shared.key(
            for: fileURL,
            provider: "xai",
            model: settings.model,
            language: language,
            preprocessing: false
        )
        if let key = cacheKey, let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }

        let data = try Data(contentsOf: fileURL)
        let file = XAIHTTPClient.MultipartFile(
            fieldName: "file",
            filename: fileURL.lastPathComponent,
            mimeType: mimeType,
            data: data
        )
        var fields: [(String, String)] = []
        if let language {
            fields.append(("format", "true"))
            fields.append(("language", language))
        }

        let signpostID = OSSignpostID(log: spLog)
        os_signpost(
            .begin,
            log: spLog,
            name: "XAITranscription",
            signpostID: signpostID,
            "bytes=%{public}lu mime=%{public}s",
            UInt(data.count),
            mimeType
        )
        AppLog.dictation.log(
            "xAI transcription start bytes=\(data.count, privacy: .public) mime=\(mimeType, privacy: .public)"
        )

        let t0 = Date()
        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            file: file,
            timeout: settings.timeout,
            context: settings.context
        )
        let elapsed = Date().timeIntervalSince(t0)
        os_signpost(.end, log: spLog, name: "XAITranscription", signpostID: signpostID, "elapsed=%.3f", elapsed)
        AppLog.dictation.log(
            "xAI transcription response bytes=\(responseData.count, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s"
        )

        let decoded = try JSONDecoder().decode(Response.self, from: responseData)
        guard let text = decoded.text else {
            throw ProviderError.decodingFailed
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = cacheKey {
            TranscriptionCache.shared.store(key, result: trimmed)
        }
        return trimmed
    }

    private static func language(for settings: TranscriptionSettings) -> String? {
        let candidate = settings.language ?? UserDefaults.standard.string(forKey: "transcription.language")
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            return nil
        }
        return trimmed
    }

    private static func mimeType(for fileExtension: String) -> String? {
        switch fileExtension {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "aac": return "audio/aac"
        case "mp4": return "audio/mp4"
        case "m4a": return "audio/mp4"
        case "mkv": return "video/x-matroska"
        default: return nil
        }
    }
}
