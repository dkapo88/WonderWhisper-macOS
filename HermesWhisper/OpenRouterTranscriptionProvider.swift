import Foundation
import OSLog
import os.signpost

final class OpenRouterTranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(
        subsystem: "com.danekapoor.hermeswhisper",
        category: "OpenRouterSTT-SP"
    )
    private let client: OpenRouterHTTPClient

    init(client: OpenRouterHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        guard let format = Self.audioFormat(for: ext) else {
            throw ProviderError.networkError("OpenRouter transcription does not support .\(ext) audio")
        }

        let language = Self.language(for: settings)
        let cacheKey = TranscriptionCache.shared.key(
            for: fileURL,
            provider: "openrouter",
            model: settings.model,
            language: language,
            preprocessing: false
        )
        if let key = cacheKey, let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }

        let data = try Data(contentsOf: fileURL)
        let body = OpenRouterHTTPClient.TranscriptionRequest(
            input_audio: .init(data: data.base64EncodedString(), format: format),
            model: settings.model,
            language: language,
            temperature: 0
        )

        let signpostID = OSSignpostID(log: spLog)
        os_signpost(
            .begin,
            log: spLog,
            name: "OpenRouterTranscription",
            signpostID: signpostID,
            "model=%{public}s bytes=%{public}lu format=%{public}s",
            settings.model,
            UInt(data.count),
            format
        )
        AppLog.dictation.log(
            "OpenRouter transcription start model=\(settings.model, privacy: .public) bytes=\(data.count, privacy: .public) format=\(format, privacy: .public)"
        )

        let t0 = Date()
        let responseData = try await client.postTranscription(
            to: settings.endpoint,
            body: body,
            timeout: settings.timeout
        )
        let dt = Date().timeIntervalSince(t0)
        os_signpost(.end, log: spLog, name: "OpenRouterTranscription", signpostID: signpostID, "elapsed=%.3f", dt)
        AppLog.dictation.log(
            "OpenRouter transcription response bytes=\(responseData.count, privacy: .public) elapsed=\(dt, format: .fixed(precision: 3), privacy: .public)s"
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

    private static func audioFormat(for fileExtension: String) -> String? {
        switch fileExtension {
        case "mp3": return "mp3"
        case "m4a": return "m4a"
        case "flac": return "flac"
        case "ogg", "opus": return "ogg"
        case "webm": return "webm"
        case "aac": return "aac"
        case "wav": return "wav"
        default: return nil
        }
    }

    private static func language(for settings: TranscriptionSettings) -> String? {
        let candidate = settings.language ?? UserDefaults.standard.string(forKey: "transcription.language")
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            return nil
        }
        return trimmed
    }
}
