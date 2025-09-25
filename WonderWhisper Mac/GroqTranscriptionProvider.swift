import Foundation
import OSLog
import os.signpost

final class GroqTranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "GroqFile-SP")
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        // For Groq file uploads, avoid preprocessing if the source is already a compressed format
        // (preprocessing expands to large WAV and hurts upload latency). Allow opt-in override.
        let ext = fileURL.pathExtension.lowercased()
        let isCompressed = ["mp3","m4a","aac","ogg","opus","flac"].contains(ext)
        let allowPreprocCompressed = UserDefaults.standard.bool(forKey: "groq.file.preprocessCompressed")
        let applyPreprocessing = AudioPreprocessor.isEnabled && (!isCompressed || allowPreprocCompressed)
        let inputURL = applyPreprocessing ? AudioPreprocessor.processIfEnabled(fileURL) : fileURL

        // Cache lookup keyed by whether preprocessing actually applied
        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: applyPreprocessing),
           let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }

        // Memory-map audio to reduce peak memory and speed up reads
        let fileData = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        let mime = mimeType(for: inputURL.pathExtension.lowercased())

        return try await transcribeData(
            data: fileData,
            filename: inputURL.lastPathComponent,
            mimeType: mime,
            settings: settings,
            cacheKey: TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: applyPreprocessing)
        )
    }
    
    // New primary transcription method that works with Data objects
    func transcribeData(data: Data, filename: String, mimeType: String, settings: TranscriptionSettings, cacheKey: TranscriptionCacheKey? = nil) async throws -> String {
        // Pre-warm connection during upload preparation for faster subsequent requests
        GroqHTTPClient.preWarmConnection(to: settings.endpoint)
        
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        var fields: [String: String] = ["model": settings.model]
        // Optional: tighten decoding by providing language if known (prefer explicit override)
        if let forced = UserDefaults.standard.string(forKey: "transcription.language"), !forced.isEmpty {
            fields["language"] = forced
        } else if let lang = Locale.preferredLanguages.first?.split(separator: "-").first {
            fields["language"] = String(lang)
        }
        fields["temperature"] = "0"
        // Provide a prompt to improve vocabulary/spelling handling
        if let prompt = buildGroqWhisperPrompt(), !prompt.isEmpty {
            fields["prompt"] = prompt
        }

        // Signpost around upload+response to measure wall-clock
        let signpostID = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "GroqFileUpload", signpostID: signpostID, "filename=%{public}s model=%{public}s bytes=%{public}lu", filename, settings.model, UInt(data.count))
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

    // Compose a concise Whisper prompt from user-configured prompt + vocabulary/spellings
    private func buildGroqWhisperPrompt() -> String? {
        let defaults = UserDefaults.standard
        // User-provided short hint
        let rawUser = (defaults.string(forKey: "transcription.prompt") ?? "")
        let userPrompt = sanitizeFreeText(rawUser, maxLen: 200)
        // Vocabulary and spelling -> convert to a compact, clean terms list
        let rawVocab = defaults.string(forKey: "vocab.custom") ?? ""
        let rawSpelling = defaults.string(forKey: "vocab.spelling") ?? ""
        let terms = compactTerms(fromVocab: rawVocab, spelling: rawSpelling, maxTerms: 20)
        var parts: [String] = []
        if !userPrompt.isEmpty { parts.append(userPrompt) }
        if !terms.isEmpty { parts.append("Preferred terms: " + terms.joined(separator: ", ") + ".") }
        let combined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty { return nil }
        return String(combined.prefix(350))
    }

    // Remove XML/markup and compress whitespace; limit length
    private func sanitizeFreeText(_ s: String, maxLen: Int) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\n\r\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxLen { t = String(t.prefix(maxLen)) }
        return t
    }

    // Extract a safe, short list of target terms from vocab/spelling
    private func compactTerms(fromVocab vocab: String, spelling: String, maxTerms: Int) -> [String] {
        func scrub(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "[\\[\\]{}]", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return t
        }
        var candidates: [String] = []
        let v = scrub(vocab)
        if !v.isEmpty {
            let splits = v.split(whereSeparator: { ",;\n".contains($0) })
            for s in splits {
                let t = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2 && t.count <= 40 { candidates.append(t) }
            }
        }
        // Parse spelling pairs like "foo -> Foo" and take the right side as the preferred form
        let sp = scrub(spelling)
        if !sp.isEmpty {
            for line in sp.components(separatedBy: ["\n"]) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let seps = ["->", "=>", "="]
                if let sep = seps.first(where: { trimmed.contains($0) }) {
                    let parts = trimmed.components(separatedBy: sep)
                    if parts.count >= 2 {
                        let rhs = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if rhs.count >= 2 && rhs.count <= 40 { candidates.append(rhs) }
                    }
                } else {
                    // If no arrow, treat the token as-is
                    if trimmed.count >= 2 && trimmed.count <= 40 { candidates.append(trimmed) }
                }
            }
        }
        // Deduplicate and cap
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates {
            let key = c.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                out.append(c)
            }
            if out.count >= maxTerms { break }
        }
        return out
    }
}
