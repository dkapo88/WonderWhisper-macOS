import Foundation
import AVFoundation
import OSLog

/// GroqStreamingProvider implements chunked audio upload for faster transcription results.
/// Since Groq doesn't support WebSocket streaming like Deepgram/AssemblyAI,
/// this provider chunks audio into small segments and uploads them progressively.
final class GroqStreamingProvider: TranscriptionProvider {
    private let client: GroqHTTPClient

    // Chunking configuration
    // Default to ~0.8s chunks for lower latency; configurable via UserDefaults("groq.stream.chunkSeconds")
    private let chunkDurationSeconds: Double = {
        let d = UserDefaults.standard.double(forKey: "groq.stream.chunkSeconds")
        // Clamp between 0.4s and 2.0s to avoid too-small or too-large requests
        return d > 0 ? max(0.4, min(2.0, d)) : 0.8
    }()
    private let sampleRate: Double = 16_000.0       // 16kHz for optimal Groq performance
    private let bytesPerSecond: Int = 32_000        // 16kHz * 2 bytes per sample

    // Live streaming state
    private var isStreaming: Bool = false
    private var accumulator: GroqTranscriptAccumulator?
    private var currentSettings: TranscriptionSettings?
    private let uploadQueue = DispatchQueue(label: "groq.upload.queue", qos: .userInitiated)
    private let uploads = UploadTaskBag()
    private let limiter: RateLimiter

    // Serialize audio buffering/chunking to avoid data races
    private let chunker: Chunker

    init(client: GroqHTTPClient) {
        self.client = client
        self.chunker = Chunker(chunkSizeBytes: Int(chunkDurationSeconds * Double(bytesPerSecond)))
        // Limit concurrent uploads to reduce network contention; configurable via UserDefaults("groq.stream.maxInflight")
        let maxInflight = UserDefaults.standard.integer(forKey: "groq.stream.maxInflight")
        let bounded = max(1, min(4, maxInflight == 0 ? 3 : maxInflight))
        self.limiter = RateLimiter(max: bounded)
    }

    // Actor responsible for safely accumulating PCM data and emitting full chunks
    private actor Chunker {
        private var buffer = Data()
        private var counter: Int = 0
        private let chunkSize: Int

        init(chunkSizeBytes: Int) { self.chunkSize = max(1, chunkSizeBytes) }

        func reset() {
            buffer.removeAll(keepingCapacity: false)
            counter = 0
        }

        // Append data and return any full chunks ready for upload
        func append(_ data: Data) -> [(number: Int, payload: Data)] {
            guard !data.isEmpty else { return [] }
            buffer.append(data)
            var out: [(Int, Data)] = []
            while buffer.count >= chunkSize {
                let payload = buffer.prefix(chunkSize)
                buffer.removeFirst(chunkSize)
                counter += 1
                out.append((counter, Data(payload)))
            }
            return out
        }

        // Return remaining buffer as a final chunk if it meets a minimal threshold
        func flushRemainder(minBytes: Int) -> (number: Int, payload: Data)? {
            guard buffer.count > minBytes else { return nil }
            counter += 1
            let payload = buffer
            buffer = Data()
            return (counter, payload)
        }
    }

    // MARK: - TranscriptionProvider Implementation

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        // For file-based transcription, fall back to original GroqTranscriptionProvider behavior
        let provider = GroqTranscriptionProvider(client: client)
        return try await provider.transcribe(fileURL: fileURL, settings: settings)
    }

    // MARK: - Streaming Interface (matches Deepgram/AssemblyAI pattern)

    /// Update transcription settings for the streaming session
    func updateSettings(_ settings: TranscriptionSettings) {
        currentSettings = settings
        AppLog.dictation.log("GroqStreaming: Settings updated - model: \(settings.model), endpoint: \(settings.endpoint)")
        // Pre-warm connection for faster uploads
        GroqHTTPClient.preWarmConnection(to: settings.endpoint)
    }

    /// Begin a streaming transcription session
    func beginRealtime() async throws {
        // Clean up any existing session first
        if isStreaming {
            AppLog.dictation.log("GroqStreaming: Cleaning up existing session before starting new one")
            _ = try? await endRealtime()
            // Give some time for cleanup
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        AppLog.dictation.log("GroqStreaming: Beginning chunked streaming session")

        // Reset state completely
        await chunker.reset()
        accumulator = nil
        // Don't reset currentSettings - they should have been set via updateSettings() before beginRealtime()

        // Initialize new session
        isStreaming = true
        accumulator = GroqTranscriptAccumulator(client: client)

        AppLog.dictation.log("GroqStreaming: Session initialized")

        // Kick off a non-blocking warmup request to reduce cold-start latency on first chunk
        if let settings = currentSettings {
            Task.detached { [weak self] in
                guard let self = self else { return }
                let dur = UserDefaults.standard.double(forKey: "groq.stream.warmupSeconds")
                let warmSec = dur > 0 ? max(0.15, min(0.6, dur)) : 0.30
                let silentSamples = Int(warmSec * self.sampleRate)
                let silence = Data(count: silentSamples * 2) // PCM16 zeros
                do {
                    let wav = try self.createWAVFile(from: silence)
                    _ = try await self.uploadChunkToGroq(wavData: wav, filename: "warmup_\(Int(Date().timeIntervalSince1970)).wav", settings: settings, prompt: nil)
                    AppLog.dictation.log("GroqStreaming: Warmup completed (\(warmSec, format: .fixed(precision: 2))s silence)")
                } catch {
                    AppLog.dictation.log("GroqStreaming: Warmup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Feed PCM16 audio data to the streaming session
    func feedPCM16(_ data: Data) async throws {
        guard isStreaming, let acc = accumulator else {
            AppLog.dictation.log("GroqStreaming: Received data but not streaming, ignoring")
            return
        }

        guard !data.isEmpty else {
            return
        }

        // Append and extract any full chunks in a thread-safe manner
        let ready = await chunker.append(data)
        for (number, payload) in ready {
            AppLog.dictation.log("GroqStreaming: Queuing chunk \(number) with \(payload.count) bytes")
            let uploadTask = Task { [weak self, weak acc] in
                await self?.limiter.acquire()
                defer { Task { await self?.limiter.release() } }
                await self?.uploadChunk(payload, chunkNumber: number, accumulator: acc)
                return ()
            }
            await uploads.add(uploadTask)
        }
        await uploads.compact()
    }

    /// End the streaming session and return final transcript
    func endRealtime() async throws -> String {
        guard isStreaming, let acc = accumulator else {
            AppLog.dictation.log("GroqStreaming: Not streaming, returning empty transcript")
            return ""
        }

        AppLog.dictation.log("GroqStreaming: Ending streaming session")
        isStreaming = false

        // Prefer allowing in-flight uploads to finish (bounded by limiter max)
        let waitStart = Date()
        while await limiter.current() > 0 {
            if Date().timeIntervalSince(waitStart) > 2.0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Upload any remaining audio in buffer as final chunk if we have meaningful data
        let minFlushBytes = Int(0.25 * chunkDurationSeconds * Double(bytesPerSecond)) // ~25% of chunk size
        if let remainder = await chunker.flushRemainder(minBytes: minFlushBytes) {
            AppLog.dictation.log("GroqStreaming: Uploading final chunk with \(remainder.payload.count) bytes")
            do {
                let wavData = try createWAVFile(from: remainder.payload)
                let filename = "final_chunk_\(remainder.number)_\(Int(Date().timeIntervalSince1970)).wav"
                guard let settings = currentSettings else {
                    AppLog.dictation.error("GroqStreaming: No settings available for final chunk")
                    return ""
                }
                let promptChars = UserDefaults.standard.integer(forKey: "groq.stream.promptTrailChars")
                let maxPromptChars = promptChars > 0 ? max(40, min(400, promptChars)) : 120
                let prompt = await acc.tailPrompt(maxChars: maxPromptChars)
                var transcript = try await uploadChunkToGroq(wavData: wavData, filename: filename, settings: settings, prompt: prompt)
                transcript = stripGroqThankYouSuffix(transcript)
                transcript = postprocessLocalIfRequested(transcript)
                await acc.addChunkResult(chunkNumber: remainder.number, transcript: transcript, isFinal: true)
            } catch {
                AppLog.dictation.error("GroqStreaming: Final chunk upload failed: \(error)")
            }
        }

        // Get final assembled transcript
        let finalTranscript = await acc.getFinalTranscript()

        // Clean up
        accumulator = nil
        await chunker.reset()

        AppLog.dictation.log("GroqStreaming: Session ended, transcript length: \(finalTranscript.count)")
        return finalTranscript
    }

    // Abort streaming session immediately without emitting transcript
    func abort() async {
        isStreaming = false
        await uploads.cancelAll()
        await chunker.reset()
        accumulator = nil
    }

    // MARK: - Private Chunk Upload Logic

    private func uploadChunk(_ chunkData: Data, chunkNumber: Int, accumulator: GroqTranscriptAccumulator?, isFinal: Bool = false) async {
        guard let acc = accumulator else { return }

        let chunkStart = Date()
        AppLog.dictation.log("GroqStreaming: Uploading chunk \(chunkNumber) (\(chunkData.count) bytes)")

        do {
            // Convert PCM16 data to WAV format for Groq upload
            let wavData = try createWAVFile(from: chunkData)

            // Create filename with chunk number for debugging
            let filename = "chunk_\(chunkNumber)_\(Int(Date().timeIntervalSince1970)).wav"

            // Optional trailing prompt from previous text to improve boundary accuracy
            let promptChars = UserDefaults.standard.integer(forKey: "groq.stream.promptTrailChars")
            let maxPromptChars = promptChars > 0 ? max(40, min(400, promptChars)) : 120
            let prompt = await acc.tailPrompt(maxChars: maxPromptChars)

            // Upload to Groq
            guard let settings = currentSettings else {
                AppLog.dictation.error("GroqStreaming: No settings available for chunk \(chunkNumber). This should not happen.")
                // Create default settings as fallback
                let fallbackSettings = TranscriptionSettings(
                    endpoint: AppConfig.groqAudioTranscriptions,
                    model: AppConfig.defaultTranscriptionModel,
                    timeout: 30
                )
                var transcript = try await uploadChunkToGroq(wavData: wavData, filename: filename, settings: fallbackSettings, prompt: prompt)
                transcript = stripGroqThankYouSuffix(transcript)
                transcript = postprocessLocalIfRequested(transcript)
                await acc.addChunkResult(chunkNumber: chunkNumber, transcript: transcript, isFinal: isFinal)
                return
            }
            var transcript = try await uploadChunkToGroq(wavData: wavData, filename: filename, settings: settings, prompt: prompt)
            transcript = stripGroqThankYouSuffix(transcript)
            transcript = postprocessLocalIfRequested(transcript)

            // Add to accumulator
            await acc.addChunkResult(chunkNumber: chunkNumber, transcript: transcript, isFinal: isFinal)

            let elapsed = Date().timeIntervalSince(chunkStart)
            AppLog.dictation.log("GroqStreaming: Chunk \(chunkNumber) completed in \(elapsed, format: .fixed(precision: 3))s: \"\(transcript.prefix(50))\"")

        } catch {
            AppLog.dictation.error("GroqStreaming: Chunk \(chunkNumber) failed: \(error.localizedDescription)")
            await acc.addChunkResult(chunkNumber: chunkNumber, transcript: "", isFinal: isFinal)
        }
    }

    private func uploadChunkToGroq(wavData: Data, filename: String, settings: TranscriptionSettings, prompt: String?) async throws -> String {
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: filename,
            mimeType: "audio/wav",
            data: wavData
        )

        var fields: [String: String] = [
            "model": settings.model,
            "temperature": "0"
        ]

        // Add language if available (prefer explicit override)
        if let forced = UserDefaults.standard.string(forKey: "transcription.language"), !forced.isEmpty {
            fields["language"] = forced
        } else if let lang = Locale.preferredLanguages.first?.split(separator: "-").first {
            fields["language"] = String(lang)
        }
        // Provide a composed prompt: user-configured + vocabulary + trailing context
        let basePrompt = buildGroqWhisperPrompt()
        // Keep trailing context small and safe
        let tail = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tailSafe = tail.isEmpty ? nil : String(tail.prefix(120))
        if let base = basePrompt, !base.isEmpty, let tailSafe {
            let combined = (base + " " + tailSafe).trimmingCharacters(in: .whitespacesAndNewlines)
            fields["prompt"] = String(combined.prefix(400))
        } else if let base = basePrompt, !base.isEmpty {
            fields["prompt"] = base
        } else if let tailSafe {
            fields["prompt"] = tailSafe
        }

        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: 30.0, // Shorter timeout for chunks
            context: "groq-chunk"
        )

        // Parse response (same as GroqTranscriptionProvider)
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try structured decoding fallback
        if let decoded = try? JSONDecoder().decode(GroqTranscriptionResponse.self, from: responseData),
           let text = decoded.text {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw ProviderError.decodingFailed
    }

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

    // MARK: - Audio Format Conversion

    private func createWAVFile(from pcm16Data: Data) throws -> Data {

        // WAV header for PCM16, 16kHz, mono
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = numChannels * bitsPerSample / 8

        var wavData = Data()

        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        let fileSize: UInt32 = UInt32(36 + pcm16Data.count)
        wavData.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)

        // Format chunk
        wavData.append("fmt ".data(using: .ascii)!)
        let fmtSize: UInt32 = 16
        wavData.append(withUnsafeBytes(of: fmtSize.littleEndian) { Data($0) })
        let audioFormat: UInt16 = 1 // PCM
        wavData.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // Data chunk
        wavData.append("data".data(using: .ascii)!)
        let dataSize: UInt32 = UInt32(pcm16Data.count)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(pcm16Data)

        return wavData
    }

    // Groq hallucination filter: strip exact trailing "Thank you." if present
    private func stripGroqThankYouSuffix(_ s: String) -> String {
        if s.hasSuffix("Thank you.") { return String(s.dropLast(10)) }
        return s
    }

    // Optional local post-processing to make streaming output raw for LLM formatting
    private func postprocessLocalIfRequested(_ s: String) -> String {
        var t = s
        let strip = UserDefaults.standard.bool(forKey: "groq.stream.stripPunctuationLocal")
        let lower = UserDefaults.standard.bool(forKey: "groq.stream.lowercaseLocal")
        if strip {
            let set = CharacterSet.punctuationCharacters.union(.symbols)
            t = t.components(separatedBy: set).joined(separator: " ")
        }
        if lower { t = t.lowercased() }
        // Collapse whitespace
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

// MARK: - Response Structure

private struct GroqTranscriptionResponse: Decodable {
    let text: String?
}

// MARK: - Transcript Accumulator

private actor GroqTranscriptAccumulator {
    private var chunkResults: [Int: String] = [:]
    private var finalChunkNumber: Int?
    private let client: GroqHTTPClient


    init(client: GroqHTTPClient) {
        self.client = client
    }

    /// Return trailing combined text (up to maxChars) to use as a prompt for the next chunk
    func tailPrompt(maxChars: Int) -> String {
        let sorted = chunkResults.keys.sorted()
        let texts = sorted.compactMap { chunkResults[$0] }
        let combined = texts.joined(separator: " ")
        if combined.count <= maxChars { return combined }
        return String(combined.suffix(maxChars))
    }


    func addChunkResult(chunkNumber: Int, transcript: String, isFinal: Bool) {
        chunkResults[chunkNumber] = transcript
        if isFinal {
            finalChunkNumber = chunkNumber
        }

        AppLog.dictation.log("GroqStreaming: Added chunk \(chunkNumber) result (final: \(isFinal)): \"\(transcript.prefix(30))\"")
    }

    func getFinalTranscript() -> String {
        // Overlap-aware merge: reduce duplicate boundary words
        let sorted = chunkResults.keys.sorted()
        var combined = ""
        var prevTokens: [String] = []
        func tokens(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        for key in sorted {
            guard var next = chunkResults[key] else { continue }
            if combined.isEmpty {
                combined = next
                prevTokens = tokens(combined)
                continue
            }
            let nextTokens = tokens(next)
            var drop = 0
            let maxK = min(8, prevTokens.count, nextTokens.count)
            if maxK >= 3 {
                for m in stride(from: maxK, through: 3, by: -1) {
                    if Array(prevTokens.suffix(m)) == Array(nextTokens.prefix(m)) {
                        drop = m
                        break
                    }
                }
            }
            if drop > 0 {
                let words = next.split(whereSeparator: { $0.isWhitespace })
                next = words.count > drop ? words.dropFirst(drop).joined(separator: " ") : ""
            }
            combined = combined.isEmpty ? next : (next.isEmpty ? combined : combined + " " + next)
            prevTokens = tokens(combined)
        }
        AppLog.dictation.log("GroqStreaming: Assembled transcript from \(sorted.count) chunks")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Thread-safe bag for upload tasks
private actor UploadTaskBag {
    private var tasks: Set<Task<Void, Never>> = []
    func add(_ task: Task<Void, Never>) { tasks.insert(task) }
    func compact() { tasks = tasks.filter { !$0.isCancelled } }
    func cancelAll() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
    }
}

// Simple async rate limiter for bounding in-flight uploads
private actor RateLimiter {
    private let max: Int
    private var inFlight: Int = 0
    init(max: Int) { self.max = max }
    func acquire() async {
        while inFlight >= max {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        inFlight += 1
    }
    func release() { inFlight = Swift.max(0, inFlight - 1) }
    func current() -> Int { inFlight }
}
