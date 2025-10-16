import Foundation
import OSLog
import os.signpost

final class OpenAITranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "OpenAIFile-SP")
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    private struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        let isCompressed = ["mp3", "m4a", "aac", "ogg", "opus", "flac", "wav", "mp4", "mpeg", "mpga", "webm"].contains(ext)
        let allowPreprocCompressed = UserDefaults.standard.bool(forKey: "openai.file.preprocessCompressed")
        let applyPreprocessing = AudioPreprocessor.isEnabled && (!isCompressed || allowPreprocCompressed)
        let inputURL = applyPreprocessing ? AudioPreprocessor.processIfEnabled(fileURL) : fileURL

        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "openai", model: settings.model, language: nil, preprocessing: applyPreprocessing),
           let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }

        // Prefer heap-backed Data to avoid mmapped file lifetime quirks during fresh recordings
        let fileData = try Data(contentsOf: inputURL)
        let mime = mimeType(for: ext)
        let cacheKey = TranscriptionCache.shared.key(for: inputURL, provider: "openai", model: settings.model, language: nil, preprocessing: applyPreprocessing)

        return try await transcribeData(
            data: fileData,
            filename: inputURL.lastPathComponent,
            mimeType: mime,
            settings: settings,
            cacheKey: cacheKey
        )
    }

    func transcribeData(
        data: Data,
        filename: String,
        mimeType: String,
        settings: TranscriptionSettings,
        cacheKey: TranscriptionCacheKey? = nil
    ) async throws -> String {
        GroqHTTPClient.preWarmConnection(to: settings.endpoint)

        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: filename,
            mimeType: mimeType,
            data: data
        )

        var fields: [String: String] = [
            "model": settings.model,
            "response_format": "json"
        ]

        if let forced = UserDefaults.standard.string(forKey: "transcription.language"), !forced.isEmpty {
            fields["language"] = forced
        }

        let signpostID = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "OpenAIFileUpload", signpostID: signpostID, "filename=%{public}s model=%{public}s bytes=%{public}lu", filename, settings.model, UInt(data.count))
        let t0 = Date()

        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: settings.timeout,
            context: settings.context
        )
        let dt = Date().timeIntervalSince(t0)
        os_signpost(.end, log: spLog, name: "OpenAIFileUpload", signpostID: signpostID, "elapsed=%.3f", dt)

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: text)
            }
            return text
        }

        if let decoded = try? Self.sharedDecoder.decode(Response.self, from: responseData), let text = decoded.text {
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: text)
            }
            return text
        }

        throw ProviderError.decodingFailed
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "mp4": return "video/mp4"
        case "mpeg", "mpga": return "audio/mpeg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    private static let sharedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
