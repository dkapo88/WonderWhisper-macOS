import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
import OSLog

final class ParakeetTranscriptionProvider: TranscriptionProvider {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var modelsDirectory: URL
    private let log = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Parakeet")
    // Idle unload after inactivity to balance memory and reliability
    private var idleUnloadTask: Task<Void, Never>?
    private let idleSeconds: TimeInterval = 300 // 5 minutes
    // Coalesce model loading to avoid duplicate work/logs
    private var loadTask: Task<Void, Error>?
    // Track which ASR model version is loaded to allow switching between v2 and v3
    private var loadedVersion: AsrModelVersion?
    // Track the loaded VAD threshold to allow dynamic updates for auto mode
    private var loadedVadThreshold: Double?
    
    // Raw mode: VoiceInk-style minimal processing (no preprocessing, no source hint, immediate cleanup)
    private var rawMode: Bool {
        (UserDefaults.standard.object(forKey: "parakeet.raw.mode") as? Bool) ?? false
    }

    init(modelsDirectory: URL? = nil) {
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            // Prefer any discovered existing install
            self.modelsDirectory = ParakeetManager.effectiveModelsDirectory
        }
    }

    // Public warm-up to preload models on recording start
    func warmUp() async {
        do {
            try await ensureModelsLoaded(version: preferredVersion())
            scheduleIdleUnload()
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] warmUp failed: \(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            AppLog.dictation.error("[Parakeet] warmUp failed: domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            // Sleep for idle window; cancel will abort
            try? await Task.sleep(nanoseconds: UInt64(self.idleSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            if let mgr = self.asrManager {
                self.log.notice("[Parakeet] Idle timeout (\(Int(self.idleSeconds))s) — unloading models")
                AppLog.dictation.log("[Parakeet] idle unload")
                await mgr.cleanup()
                self.asrManager = nil
            }
        }
    }

    private func ensureModelsLoaded(version: AsrModelVersion) async throws {
        if asrManager != nil, loadedVersion == version {
            // Already loaded with the requested version
            return
        }
        if let t = loadTask {
            // If a load is in-flight, await it then re-check
            try await t.value
            if asrManager != nil, loadedVersion == version { return }
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            try await self.performModelLoad(version: version)
        }
        try await loadTask?.value
    }

    private func performModelLoad(version: AsrModelVersion) async throws {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        // If models exist in a different known location, prefer that
        let discovered = ParakeetManager.effectiveModelsDirectory
        if discovered != modelsDirectory { modelsDirectory = discovered }
        log.notice("[Parakeet] ensureModelsLoaded dir=\(self.modelsDirectory.path, privacy: .public)")
        AppLog.dictation.log("[Parakeet] ensureModelsLoaded dir=\(self.modelsDirectory.path)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        log.notice("[Parakeet] dir contents count=\(contents.count, privacy: .public) items=\(String(describing: contents.prefix(5)), privacy: .public)")
        AppLog.dictation.log("[Parakeet] contents count=\(contents.count) items=\(String(describing: contents.prefix(5)))")
        let inv = ParakeetManager.inventory(at: modelsDirectory)
        log.notice("[Parakeet] compiled models=\(String(describing: inv.mlmodelc), privacy: .public) others=\(String(describing: inv.others.prefix(5)), privacy: .public)")
        AppLog.dictation.log("[Parakeet] compiled=\(String(describing: inv.mlmodelc)) others=\(String(describing: inv.others.prefix(5)))")
        let validation = ParakeetManager.validateModels(at: modelsDirectory)
        if !validation.ok {
            log.notice("[Parakeet] validation missing=\(String(describing: validation.missing), privacy: .public)")
            AppLog.dictation.error("[Parakeet] validation missing=\(String(describing: validation.missing))")
        }
        // Use selected model version (v2 or v3). FluidAudio 0.14.x defaults to the
        // stable int8 encoder; keep that for reliability over the newer int4 option.
        let models = try await AsrModels.downloadAndLoad(version: version)
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(models)
        self.loadedVersion = version
        let available = await mgr.isAvailable
        log.notice("[Parakeet] manager available=\(available, privacy: .public)")
        AppLog.dictation.log("[Parakeet] manager available=\(available)")
        asrManager = mgr
        scheduleIdleUnload()
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        try await ensureModelsLoaded(version: preferredVersion(for: settings))
        scheduleIdleUnload()
        guard let mgr = asrManager else { throw ProviderError.notImplemented }
        
        // Raw mode: VoiceInk-style minimal processing path
        if rawMode {
            AppLog.dictation.log("[Parakeet] Raw mode enabled - using VoiceInk-style minimal processing")
            return try await transcribeRawMode(mgr: mgr, fileURL: fileURL)
        }

        // Optional smart preprocessing (shared with Groq path)
        var cleanupURLs: [URL] = []
        var inputURL = fileURL
        // For Parakeet, external file-based preprocessing can compete with CoreAudio file finalization.
        // Keep it disabled by default; allow opt-in via UserDefaults key "parakeet.externalPreprocess".
        let allowExternalPreprocess = (UserDefaults.standard.object(forKey: "parakeet.externalPreprocess") as? Bool) ?? false
        if allowExternalPreprocess && AudioPreprocessor.isEnabled {
            AppLog.dictation.log("[Parakeet] External preprocess begin")
            let processed = AudioPreprocessor.processIfEnabled(fileURL)
            if processed != fileURL {
                inputURL = processed
                cleanupURLs.append(processed)
            }
            AppLog.dictation.log("[Parakeet] External preprocess end -> \(inputURL.lastPathComponent)")
        }

        defer {
            for url in cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        AppLog.dictation.log("[Parakeet] ASR begin file=\(inputURL.lastPathComponent)")
        let result: ASRResult
        do {
            let decoderLayers = await mgr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            result = try await mgr.transcribe(
                inputURL,
                decoderState: &decoderState,
                language: Self.fluidLanguage(for: settings.language)
            )
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] mgr.transcribe error=\(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            AppLog.dictation.error("[Parakeet] transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        AppLog.dictation.log("[Parakeet] ASR done")
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] result length=\(result.text.count) preview=\(String(preview))")
        // Keep models warm for subsequent transcriptions to avoid re-initialization errors
        let text = result.text
        scheduleIdleUnload()
        return text
    }

    private static func fluidLanguage(for code: String?) -> Language? {
        guard let code else { return nil }
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty, normalized != "auto" else { return nil }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return Language(rawValue: primary)
    }

    // Determine preferred ASR model version from settings or user defaults
    private func preferredVersion(for settings: TranscriptionSettings? = nil) -> AsrModelVersion {
        if let model = settings?.model.lowercased() {
            if model.contains("v2") { return .v2 }
            if model.contains("v3") { return .v3 }
        }
        let pref = (UserDefaults.standard.string(forKey: "parakeet.version") ?? "v3").lowercased()
        return (pref == "v2") ? .v2 : .v3
    }

    // MARK: - VAD (Silero) integration
    private func ensureVadManager(preferredThreshold: Double? = nil) async throws -> VadManager? {
        let desired = preferredThreshold ?? (UserDefaults.standard.object(forKey: "parakeet.vad.threshold") as? Double ?? 0.5)
        // If a manager exists and threshold hasn't changed materially, reuse it
        if let v = vadManager, let loaded = loadedVadThreshold, abs(loaded - desired) < 0.01 {
            return v
        }
        do {
            let cfg = VadConfig(
                defaultThreshold: Float(desired),
                debugMode: false,
                computeUnits: .cpuAndNeuralEngine
            )
            let v = try await VadManager(config: cfg)
            vadManager = v
            loadedVadThreshold = desired
            return v
        } catch {
            return nil
        }
    }

    // Returns trimmed samples if VAD finds speech; nil otherwise
    private func applyVADIfAvailable(_ samples: [Float]) async throws -> [Float]? {
        // Adaptive VAD threshold: use higher threshold for longer audio
        let audioDurationSeconds = Double(samples.count) / 16_000.0
        let baseThreshold = (UserDefaults.standard.object(forKey: "parakeet.vad.threshold") as? Double) ?? 0.5
        
        let adaptiveThreshold: Double
        if audioDurationSeconds > 20.0 {
            // Longer audio: use stricter threshold to filter background noise
            adaptiveThreshold = max(baseThreshold, 0.7)
            AppLog.dictation.log("[Parakeet] VAD using adaptive threshold \(String(format: "%.2f", adaptiveThreshold)) for long audio (\(String(format: "%.1f", audioDurationSeconds))s)")
        } else {
            adaptiveThreshold = baseThreshold
        }
        
        guard let vad = try await ensureVadManager(preferredThreshold: adaptiveThreshold) else { return nil }
        if samples.isEmpty { return nil }
        // Use 0.6 segmentation API for robust trimming
        var segCfg = VadSegmentationConfig.default
        // Tunable parameters via UserDefaults with safe clamps
        let minSpeech = max(0.05, min(1.0, (UserDefaults.standard.object(forKey: "parakeet.vad.minSpeech") as? Double ?? 0.25)))
        let minSilence = max(0.10, min(1.5, (UserDefaults.standard.object(forKey: "parakeet.vad.minSilence") as? Double ?? 0.35)))
        let padding = max(0.0, min(0.8, (UserDefaults.standard.object(forKey: "parakeet.vad.padding") as? Double ?? 0.10)))
        segCfg.minSpeechDuration = minSpeech
        segCfg.minSilenceDuration = minSilence
        segCfg.speechPadding = padding
        let segments = try await vad.segmentSpeech(samples, config: segCfg)
        guard let first = segments.first, let last = segments.last else { return nil }
        // Convert seconds to sample indices at 16kHz
        let sr = 16_000.0
        let startIdx = max(0, Int(first.startTime * sr))
        let endIdx = min(samples.count, Int(last.endTime * sr))
        guard endIdx > startIdx else { return nil }
        return Array(samples[startIdx..<endIdx])
    }

    // Decode arbitrary audio to mono 16k Float32 samples
    private static func decodeAudioToFloatMono16k(url: URL) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: url)
        let inFormat = inputFile.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "Parakeet", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create output audio format"
            ])
        }
        var samples: [Float] = []
        if inFormat == outFormat {
            // Fast path: read directly
            let capacity: AVAudioFrameCount = 4096
            while true {
                guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                    throw NSError(domain: "Parakeet", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"
                    ])
                }
                try inputFile.read(into: buf, frameCount: capacity)
                if buf.frameLength == 0 { break }
                guard let channelData = buf.floatChannelData else {
                    throw NSError(domain: "Parakeet", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Missing float channel data"
                    ])
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buf.frameLength)))
            }
        } else {
            // Convert
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio format conversion failed"])
            }
            let inputFrameCapacity: AVAudioFrameCount = 4096
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat,
                frameCapacity: inputFrameCapacity
            ) else {
                throw NSError(domain: "Parakeet", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate input PCM buffer"
                ])
            }
            while true {
                try inputFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
                if inputBuffer.frameLength == 0 { break }
                var inputDone = false
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outFormat,
                    frameCapacity: 8192
                ) else {
                    throw NSError(domain: "Parakeet", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to allocate output PCM buffer"
                    ])
                }
                let status = converter.convert(to: outputBuffer, error: nil, withInputFrom: { inNumPackets, outStatus in
                    if inputDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    outStatus.pointee = .haveData
                    inputDone = true
                    return inputBuffer
                })
                if status == .haveData {
                    guard let channelData = outputBuffer.floatChannelData else {
                        throw NSError(domain: "Parakeet", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Missing converted float channel data"
                        ])
                    }
                    samples.append(contentsOf: UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(outputBuffer.frameLength)
                    ))
                }
                inputBuffer.frameLength = 0
            }
        }
        return samples
    }

    private static func decodeFastPCM16(url: URL) throws -> [Float]? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 44 else { return nil }
        guard data[0...3] == Data([82, 73, 70, 70]) else { return nil }
        guard data[8...11] == Data([87, 65, 86, 69]) else { return nil }
        let fmtOffset = findChunkOffset(in: data, id: Data([102, 109, 116, 32]))
        guard fmtOffset >= 0 else { return nil }
        let fmtSize = Int(readUInt32(data, offset: fmtOffset + 4))
        guard fmtSize >= 16, fmtOffset + 8 + fmtSize <= data.count else { return nil }
        let fmtDataOffset = fmtOffset + 8
        let audioFormat = readUInt16(data, offset: fmtDataOffset)
        let channels = readUInt16(data, offset: fmtDataOffset + 2)
        let sampleRate = readUInt32(data, offset: fmtDataOffset + 4)
        let bitsPerSample = readUInt16(data, offset: fmtDataOffset + 14)
        // Accept standard PCM and WAVE_FORMAT_EXTENSIBLE when the packed payload is
        // mono 16-bit 16 kHz PCM. The subtype is omitted because this is only a fast path.
        guard (audioFormat == 1 || audioFormat == 0xFFFE),
              channels == 1,
              sampleRate == 16_000,
              bitsPerSample == 16 else { return nil }
        let dataOffset = findDataChunkOffset(in: data)
        guard dataOffset >= 0 else { return nil }
        let start = dataOffset + 8
        guard start <= data.count else { return nil }
        // Respect the declared WAV data chunk size to avoid reading trailing metadata
        let declaredDataSize = Int(readUInt32(data, offset: dataOffset + 4))
        let available = data.count - start
        let length = max(0, min(declaredDataSize, available))
        guard length > 0 else { return [] }
        let count = length / MemoryLayout<Int16>.size
        var result = [Float](repeating: 0, count: count)
        let clamp: (Float) -> Float = { min(max($0, -1.0), 1.0) }
        result.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let samples = base.advanced(by: start).assumingMemoryBound(to: Int16.self)
                for i in 0..<count {
                    let value = Float(Int16(littleEndian: samples[i])) / 32767.0
                    dst[i] = clamp(value)
                }
            }
        }
        return result
    }

    private static func findDataChunkOffset(in data: Data) -> Int {
        findChunkOffset(in: data, id: Data([100, 97, 116, 97]))
    }

    private static func findChunkOffset(in data: Data, id: Data) -> Int {
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data[offset..<(offset + 4)]
            let size = Int(readUInt32(data, offset: offset + 4))
            if chunkID == id { return offset }
            offset += 8 + size + (size % 2)
        }
        return -1
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return base.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee.littleEndian
        }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return base.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee.littleEndian
        }
    }

    private static func stats(samples: [Float]) -> (meanAbs: Double, peak: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum: Double = 0
        var peak: Double = 0
        for s in samples {
            let a = abs(Double(s))
            sum += a
            if a > peak { peak = a }
        }
        return (sum / Double(samples.count), peak)
    }

    // First-order high-pass filter
    private static func highPass(_ input: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
        guard !input.isEmpty else { return input }
        let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)
        var out = Array(repeating: Float(0), count: input.count)
        var yPrev = 0.0
        var xPrev = 0.0
        for i in 0..<input.count {
            let x = Double(input[i])
            let y = alpha * (yPrev + x - xPrev)
            out[i] = Float(y)
            yPrev = y
            xPrev = x
        }
        return out
    }

    // Simple pre-emphasis
    private static func preEmphasis(_ input: [Float], coeff: Float) -> [Float] {
        guard !input.isEmpty else { return input }
        var out = input
        var prev: Float = 0
        for i in 0..<out.count {
            let cur = out[i]
            out[i] = cur - coeff * prev
            prev = cur
        }
        return out
    }

    private static func normalizeRMS(_ input: [Float], targetRMS: Double, peakLimit: Double, maxGain: Double) -> [Float] {
        guard !input.isEmpty else { return input }
        // Compute RMS and peak
        var sumSq: Double = 0
        var peak: Double = 0
        for v in input {
            let d = Double(v)
            sumSq += d * d
            let a = abs(d)
            if a > peak { peak = a }
        }
        let rms = sqrt(sumSq / Double(input.count))
        if rms <= 0 { return input }
        var gain = targetRMS / rms
        // Respect peak limit
        if peak * gain > peakLimit { gain = peakLimit / max(peak, 1e-9) }
        gain = min(gain, maxGain)
        if abs(gain - 1.0) < 1e-3 { return input }
        var out = input
        for i in 0..<out.count {
            let v = Double(out[i]) * gain
            out[i] = Float(max(-1.0, min(1.0, v)))
        }
        return out
    }

    // Robust decode path using AVAssetReader
    // MARK: - Raw Mode (VoiceInk-style)
    
    /// Raw mode transcription: minimal processing like VoiceInk reference implementation
    /// - No preprocessing (no high-pass, no pre-emphasis, no RMS normalization)
    /// - No source hint parameter
    /// - Idle timeout (60s) instead of immediate cleanup (preserves rapid transcription support)
    /// - Simple WAV decoding starting at byte 44
    private func transcribeRawMode(mgr: AsrManager, fileURL: URL) async throws -> String {
        // Simple WAV decoding (VoiceInk-style)
        AppLog.dictation.log("[Parakeet] Raw mode: decoding audio")
        guard let samples = Self.decodeAudioRaw(url: fileURL) else {
            throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Raw mode: Failed to decode WAV audio"])
        }
        
        let stats = Self.stats(samples: samples)
        log.notice("[Parakeet] Raw mode samples=\(samples.count, privacy: .public) meanAbs=\(stats.meanAbs, format: .fixed(precision: 4)) peak=\(stats.peak, format: .fixed(precision: 4))")
        AppLog.dictation.log("[Parakeet] Raw mode: samples=\(samples.count) meanAbs=\(String(format: "%.4f", stats.meanAbs)) peak=\(String(format: "%.4f", stats.peak))")
        
        // Validate audio
        if samples.count < 16_000 {
            throw NSError(domain: "Parakeet", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Audio too short for ASR (need >= 1s)"])
        }
        if stats.meanAbs < 0.002 && stats.peak < 0.01 {
            throw NSError(domain: "Parakeet", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Audio appears near-silent; check microphone and input gain"])
        }
        
        // Raw mode always keeps the full capture; skip VAD entirely so long-form dictations stay intact
        var finalSamples = samples
        let audioDurationSeconds = Double(samples.count) / 16_000.0
        AppLog.dictation.log("[Parakeet] Raw mode: skipping VAD (duration: \(String(format: "%.1f", audioDurationSeconds))s)")
        
        if finalSamples.count + 16_000 <= 240_000 {
            finalSamples += [Float](repeating: 0, count: 16_000)
        }

        // Transcribe without source hint (VoiceInk-style for this pinned API)
        AppLog.dictation.log("[Parakeet] Raw mode: transcribing (no source hint)")
        let result: ASRResult
        do {
            let decoderLayers = await mgr.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            result = try await mgr.transcribe(finalSamples, decoderState: &decoderState)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] Raw mode transcribe error=\(ns.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] Raw mode error: \(ns.localizedDescription)")
            throw error
        }
        
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] Raw mode result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] Raw mode: result length=\(result.text.count) preview=\(String(preview))")
        
        // Schedule idle unload instead of immediate cleanup
        // Immediate cleanup breaks subsequent transcriptions by de-initializing the manager
        // The idle timeout (60s) provides the same benefits without breaking rapid-fire transcriptions
        AppLog.dictation.log("[Parakeet] Raw mode: scheduling idle unload (\(Int(self.idleSeconds))s)")
        scheduleIdleUnload()
        
        return result.text
    }
    
    /// Simple WAV decoder for raw mode (VoiceInk-style)
    /// Reads from byte 44 onwards, converts Int16 to Float32
    private static func decodeAudioRaw(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count >= 44 else { return nil }
        
        // Basic WAV validation
        guard data[0...3] == Data([82, 73, 70, 70]) else { return nil }  // "RIFF"
        guard data[8...11] == Data([87, 65, 86, 69]) else { return nil }  // "WAVE"
        
        // Simple conversion: skip header, convert Int16 → Float32
        let samples: [Float] = stride(from: 44, to: data.count, by: 2).compactMap { offset in
            guard offset + 1 < data.count else { return nil }
            let bytes = data[offset..<offset + 2]
            let short = bytes.withUnsafeBytes { $0.load(as: Int16.self).littleEndian }
            let float = Float(short) / 32767.0
            return max(-1.0, min(float, 1.0))  // Clamp to [-1, 1]
        }
        
        return samples.isEmpty ? nil : samples
    }
    
    /// VAD for raw mode: simple threshold 0.7 like VoiceInk
    private func applyVADRawMode(_ samples: [Float]) async throws -> [Float]? {
        let threshold = 0.7  // Fixed threshold like VoiceInk
        guard let vad = try? await ensureVadManager(preferredThreshold: threshold) else { return nil }
        if samples.isEmpty { return nil }
        
        var segCfg = VadSegmentationConfig.default
        segCfg.minSpeechDuration = 0.25
        segCfg.minSilenceDuration = 0.35
        segCfg.speechPadding = 0.10
        
        let segments = try await vad.segmentSpeech(samples, config: segCfg)
        guard let first = segments.first, let last = segments.last else { return nil }
        
        let sr = 16_000.0
        let startIdx = max(0, Int(first.startTime * sr))
        let endIdx = min(samples.count, Int(last.endTime * sr))
        guard endIdx > startIdx else { return nil }
        
        return Array(samples[startIdx..<endIdx])
    }
}
#else
final class ParakeetTranscriptionProvider: TranscriptionProvider {
    init(modelsDirectory: URL? = nil) {}
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        throw ProviderError.notImplemented
    }
}
#endif
