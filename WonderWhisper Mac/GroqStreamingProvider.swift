import Foundation
import AVFoundation
import OSLog

/// GroqStreamingProvider implements chunked audio upload for faster transcription results.
/// Since Groq doesn't support WebSocket streaming like Deepgram/AssemblyAI,
/// this provider chunks audio into multi‑second segments with overlap and uploads them progressively.
///
/// Key behavior (tunable via UserDefaults):
/// - groq.stream.chunkSeconds (Double): default 6.0s, 2.0–15.0s
/// - groq.stream.overlapSeconds (Double): default 1.2s, 0.5–4.0s
/// - groq.stream.maxInflight (Int): default 1 (sequential uploads)
/// - groq.stream.promptTrailChars (Int): default 200 (80–600)
///
/// Larger chunks + overlap dramatically improve boundary accuracy versus sub‑second micro‑chunks
/// while keeping latency acceptable for dictation scenarios. Transcript merging performs
/// punctuation‑insensitive overlap removal.
final class GroqStreamingProvider: TranscriptionProvider {
    private let client: GroqHTTPClient

    // Chunking configuration
    // Use multi‑second chunks with overlap for accuracy; configurable via UserDefaults("groq.stream.chunkSeconds")
    // Default 6.0s chunks with 1.2s overlap (tunable via UserDefaults).
    private var chunkDurationSeconds: Double = {
        let d = UserDefaults.standard.double(forKey: "groq.stream.chunkSeconds")
        return d > 0 ? max(2.0, min(15.0, d)) : 6.0
    }()
    private var overlapDurationSeconds: Double = {
        let d = UserDefaults.standard.double(forKey: "groq.stream.overlapSeconds")
        return d > 0 ? max(0.5, min(4.0, d)) : 1.2
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
    private var chunker: Chunker

    init(client: GroqHTTPClient) {
        self.client = client
        let initialChunkBytes = Int(chunkDurationSeconds * Double(bytesPerSecond))
        let initialOverlapBytes = Int(overlapDurationSeconds * Double(bytesPerSecond))
        self.chunker = Chunker(chunkSizeBytes: initialChunkBytes, overlapBytes: initialOverlapBytes)
        // Limit concurrent uploads to reduce prompt staleness; default sequential
        let maxInflight = UserDefaults.standard.integer(forKey: "groq.stream.maxInflight")
        let bounded = max(1, min(3, maxInflight == 0 ? 1 : maxInflight))
        self.limiter = RateLimiter(max: bounded)
    }

    // Actor responsible for safely accumulating PCM data and emitting full chunks
    private actor Chunker {
        private var buffer = Data()
        private var counter: Int = 0
        private var prevTail = Data()
        private var chunkSize: Int
        private var overlapSize: Int

        init(chunkSizeBytes: Int, overlapBytes: Int) {
            self.chunkSize = max(1, chunkSizeBytes)
            self.overlapSize = max(0, min(chunkSizeBytes / 2, overlapBytes))
        }

        func reconfigure(chunkSizeBytes: Int, overlapBytes: Int) {
            self.chunkSize = max(1, chunkSizeBytes)
            self.overlapSize = max(0, min(chunkSizeBytes / 2, overlapBytes))
            buffer.removeAll(keepingCapacity: false)
            prevTail.removeAll(keepingCapacity: false)
            counter = 0
        }

        func reset() {
            buffer.removeAll(keepingCapacity: false)
            prevTail.removeAll(keepingCapacity: false)
            counter = 0
        }

        // Append data and return any full chunks ready for upload
        func append(_ data: Data) -> [(number: Int, payload: Data)] {
            guard !data.isEmpty else { return [] }
            buffer.append(data)
            var out: [(Int, Data)] = []
            while buffer.count >= chunkSize {
                let core = buffer.prefix(chunkSize)
                buffer.removeFirst(chunkSize)
                var payload = Data()
                if !prevTail.isEmpty { payload.append(prevTail) }
                payload.append(core)
                prevTail = Data(core.suffix(overlapSize))
                counter += 1
                out.append((counter, payload))
            }
            return out
        }

        // Return remaining buffer as a final chunk if it meets a minimal threshold
        func flushRemainder(minBytes: Int) -> (number: Int, payload: Data)? {
            let totalBytes = prevTail.count + buffer.count
            guard totalBytes > minBytes else { return nil }
            var payload = Data()
            if !prevTail.isEmpty { payload.append(prevTail) }
            payload.append(buffer)
            buffer = Data()
            prevTail = Data()
            counter += 1
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

        // Re-read runtime tunables and reconfigure chunker
        self.chunkDurationSeconds = {
            let d = UserDefaults.standard.double(forKey: "groq.stream.chunkSeconds")
            return d > 0 ? max(2.0, min(15.0, d)) : 6.0
        }()
        self.overlapDurationSeconds = {
            let d = UserDefaults.standard.double(forKey: "groq.stream.overlapSeconds")
            return d > 0 ? max(0.5, min(4.0, d)) : 1.2
        }()
        await chunker.reconfigure(
            chunkSizeBytes: Int(chunkDurationSeconds * Double(bytesPerSecond)),
            overlapBytes: Int(overlapDurationSeconds * Double(bytesPerSecond))
        )

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
                let maxPromptChars = promptChars > 0 ? max(80, min(600, promptChars)) : 200
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
        await acc.clearChunkResults()  // Explicitly clear accumulated data
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
        if let acc = accumulator {
            await acc.clearChunkResults()  // Explicitly clear accumulated data
        }
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
            let maxPromptChars = promptChars > 0 ? max(80, min(600, promptChars)) : 200
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
        // Only provide trailing context prompt to improve chunk boundary accuracy
        let tail = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow a bit more trailing context for boundary accuracy
        let tailSafe = tail.isEmpty ? nil : String(tail.prefix(200))
        if let tailSafe {
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
            guard let nextRaw = chunkResults[key] else { continue }
            if combined.isEmpty {
                combined = nextRaw
                prevTokens = tokens(combined)
                continue
            }
            // Use helper to merge with overlap-aware dedupe
            let merged = OverlapDeduper.merge(prev: combined, next: nextRaw, maxK: 24)
            combined = merged.trimmingCharacters(in: .whitespacesAndNewlines)
            prevTokens = tokens(combined)
        }
        AppLog.dictation.log("GroqStreaming: Assembled transcript from \(sorted.count) chunks")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Clear chunk results to free memory after session ends
    func clearChunkResults() {
        chunkResults.removeAll(keepingCapacity: false)
        finalChunkNumber = nil
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
