import Foundation
import OSLog
import os.signpost

final class GroqTranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(subsystem: AppConfig.bundleIdentifier, category: "GroqFile-SP")
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        let cacheKey = TranscriptionCache.shared.key(
            for: fileURL,
            provider: "groq",
            model: settings.model,
            language: nil,
            preprocessing: false
        )
        if let cacheKey, let cached = TranscriptionCache.shared.lookup(cacheKey) {
            return cached
        }
        let fileData = try Data(contentsOf: fileURL)

        let apiModel = Self.apiModel(for: settings.model)
        return try await transcribeData(
            data: fileData,
            filename: fileURL.lastPathComponent,
            mimeType: mimeType(for: ext),
            settings: TranscriptionSettings(
                endpoint: settings.endpoint,
                model: apiModel,
                timeout: settings.timeout,
                language: settings.language,
                vocabularyTerms: settings.vocabularyTerms,
                context: settings.context
            ),
            cacheKey: cacheKey
        )
    }
    
    // New primary transcription method that works with Data objects
    func transcribeData(data: Data, filename: String, mimeType: String, settings: TranscriptionSettings, cacheKey: TranscriptionCacheKey? = nil) async throws -> String {
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        var fields: [String: String] = ["model": settings.model]
        // Optional: tighten decoding by providing language if known (prefer explicit override)
        if !Self.isAutoLanguage(settings.language) {
            if let forced = Self.normalizedLanguage(settings.language) {
                fields["language"] = forced
            } else if let forced = Self.normalizedLanguage(UserDefaults.standard.string(forKey: "transcription.language")) {
                fields["language"] = forced
            } else if let lang = Locale.preferredLanguages.first?.split(separator: "-").first {
                fields["language"] = String(lang)
            }
        }
        fields["temperature"] = "0"

        // Signpost around upload+response to measure wall-clock
        let signpostID = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "GroqFileUpload", signpostID: signpostID, "filename=%{public}s model=%{public}s bytes=%{public}lu", filename, settings.model, UInt(data.count))
        AppLog.dictation.log("Groq file upload start model=\(settings.model, privacy: .public) filename=\(filename, privacy: .public) bytes=\(data.count, privacy: .public) mime=\(mimeType, privacy: .public)")
        let t0 = Date()
        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: settings.timeout,
            context: settings.context
        )
        let dt = Date().timeIntervalSince(t0)
        os_signpost(.end, log: spLog, name: "GroqFileUpload", signpostID: signpostID, "elapsed=%.3f", dt)
        AppLog.dictation.log("Groq file upload response bytes=\(responseData.count, privacy: .public) elapsed=\(dt, format: .fixed(precision: 3), privacy: .public)s")

        if UserDefaults.standard.bool(forKey: "groq.file.debugResponse"),
           let snippet = String(data: responseData.prefix(2048), encoding: .utf8) {
            AppLog.dictation.log("Groq raw response (first 2KB): \(snippet)")
        }
        
        // Many OpenAI-compatible transcription endpoints return {"text": "..."}
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            let filtered = stripGroqThankYouSuffix(text)
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: filtered)
            }
            return filtered
        }
        
        // Try strict decoding fallback with a shared decoder
        if let decoded = try? Self.sharedDecoder.decode(Response.self, from: responseData), let t = decoded.text {
            let filtered = stripGroqThankYouSuffix(t)
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: filtered)
            }
            return filtered
        }
        
        throw ProviderError.decodingFailed
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        return trimmed
    }

    private static func isAutoLanguage(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto"
    }

    private static func apiModel(for storedModel: String) -> String {
        if storedModel == "groq-streaming" {
            return AppConfig.defaultTranscriptionModel
        }
        return storedModel
    }

    // Groq hallucination filter: strip exact trailing "Thank you." if present
    private func stripGroqThankYouSuffix(_ s: String) -> String {
        if s.hasSuffix("Thank you.") { return String(s.dropLast(10)) }
        return s
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4" // m4a container
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

}
