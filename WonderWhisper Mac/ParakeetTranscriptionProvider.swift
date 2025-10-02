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
    private let idleSeconds: TimeInterval = 600 // 10 minutes
    // Coalesce model loading to avoid duplicate work/logs
    private var loadTask: Task<Void, Error>?
    // Track which ASR model version is loaded to allow switching between v2 and v3
    private var loadedVersion: AsrModelVersion?

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
                mgr.cleanup()
                self.asrManager = nil
            }
        }
    }

    private func ensureModelsLoaded(version: AsrModelVersion) async throws {
        if let mgr = asrManager, loadedVersion == version {
            // Already loaded with the requested version
            _ = mgr // silence
            return
        }
        if let t = loadTask {
            // If a load is in-flight, await it then re-check
            try await t.value
            if let mgr = asrManager, loadedVersion == version { return }
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
        // Use selected model version (v2 or v3)
        var models = try await AsrModels.downloadAndLoad(version: version)

        #if canImport(FluidAudio)
        // Detect legacy preprocessor outputs and force a re-download once
        let outputKeys = Set(models.preprocessor.modelDescription.outputDescriptionsByName.keys)
        if !outputKeys.contains("length"), outputKeys.contains("melspectrogram_length") {
            log.notice("[Parakeet] Detected legacy Parakeet models (missing 'length'); forcing re-download")
            AppLog.dictation.log("[Parakeet] Legacy models detected; forcing re-download")
            models = try await AsrModels.downloadAndLoad()
        }
        #endif
        let mgr = AsrManager(config: .default)
        try await mgr.initialize(models: models)
        self.loadedVersion = version
        #if compiler(>=5.9)
        // Best-effort signal
        if let available = Mirror(reflecting: mgr).descendant("isAvailable") as? Bool {
            log.notice("[Parakeet] manager available=\(available, privacy: .public)")
            AppLog.dictation.log("[Parakeet] manager available=\(available)")
        }
        #endif
        asrManager = mgr
        scheduleIdleUnload()
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        try await ensureModelsLoaded(version: preferredVersion(for: settings))
        scheduleIdleUnload()
        guard let mgr = asrManager else { throw ProviderError.notImplemented }
        // Optional smart preprocessing (shared with Groq path)
        var inputURL = fileURL
        var preprocessingEnabled = false
        if AudioPreprocessor.isEnabled {
            let processed = AudioPreprocessor.processIfEnabled(fileURL)
            if processed != fileURL { preprocessingEnabled = true; inputURL = processed }
        }

        // Cache lookup (separate entries per model version and preprocessing state)
        let modelIdForCache = "\(settings.model)-\(preferredVersion(for: settings) == .v2 ? "v2" : "v3")"
        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "parakeet", model: modelIdForCache, language: nil, preprocessing: preprocessingEnabled),
           let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }
        var samples: [Float]
        let ext = inputURL.pathExtension.lowercased()
        if ["m4a","mp4","aac","alac","mov","m4b","m4p"].contains(ext),
           let alt = try? Self.decodeWithAssetReader(url: inputURL) {
            AppLog.dictation.log("[Parakeet] Preferred AVAssetReader path for compressed input: samples=\(alt.count)")
            samples = alt
        } else {
            do {
                samples = try Self.decodeAudioToFloatMono16k(url: inputURL)
            } catch {
                let ns = error as NSError
                AppLog.dictation.error("[Parakeet] AVAudioFile decode failed domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
                // Fallback: try AVAssetReader-based decode
                if let alt = try? Self.decodeWithAssetReader(url: inputURL) {
                    AppLog.dictation.log("[Parakeet] Fallback decode via AVAssetReader succeeded: samples=\(alt.count)")
                    samples = alt
                } else {
                    AppLog.dictation.error("[Parakeet] Fallback decode via AVAssetReader failed")
                    throw error
                }
            }
        }
        // Front-end conditioning (configurable via UserDefaults)
        let defaults = UserDefaults.standard
        // If app-level preprocessing already applied, skip internal steps to avoid double-processing
        if !preprocessingEnabled {
            let hpHz = defaults.object(forKey: "parakeet.highpass.hz") as? Int ?? 60
            if hpHz > 0 { samples = Self.highPass(samples, cutoffHz: Double(hpHz), sampleRate: 16_000) }
            let preEnabled = defaults.object(forKey: "parakeet.preemphasis") as? Bool ?? true
            if preEnabled { samples = Self.preEmphasis(samples, coeff: 0.97) }
            let targetRMS = defaults.object(forKey: "parakeet.rms.target") as? Double ?? 0.06
            samples = Self.normalizeRMS(samples, targetRMS: targetRMS, peakLimit: 0.5, maxGain: 8.0)
        }
        // Optional VAD pre-segmentation using FluidAudio Silero VAD (v0.4+)
        do {
            if (UserDefaults.standard.object(forKey: "parakeet.vad.enabled") as? Bool) ?? true {
                if let trimmed = try await applyVADIfAvailable(samples), trimmed.count >= 16_000 {
                    samples = trimmed
                }
            }
        } catch {
            // Non-fatal: proceed without VAD
        }
        let stats = Self.stats(samples: samples)
        log.notice("[Parakeet] transcribe samples=\(samples.count, privacy: .public) meanAbs=\(stats.meanAbs, format: .fixed(precision: 4)) peak=\(stats.peak, format: .fixed(precision: 4))")
        AppLog.dictation.log("[Parakeet] samples=\(samples.count) meanAbs=\(String(format: "%.4f", stats.meanAbs)) peak=\(String(format: "%.4f", stats.peak))")
        if samples.count < 16_000 {
            let err = NSError(domain: "Parakeet", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Audio too short for ASR (need >= 1s)"])
            log.notice("[Parakeet] rejecting: \(err.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] \(err.localizedDescription)")
            throw err
        }
        if stats.meanAbs < 0.002 && stats.peak < 0.01 {
            let err = NSError(domain: "Parakeet", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Audio appears near-silent; check microphone and input gain"])
            log.notice("[Parakeet] rejecting: \(err.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] \(err.localizedDescription)")
            throw err
        }
        let result: ASRResult
        do {
            // Provide source hint per 0.6 API
            result = try await mgr.transcribe(samples, source: .microphone)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] mgr.transcribe error=\(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            AppLog.dictation.error("[Parakeet] transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] result length=\(result.text.count) preview=\(String(preview))")
        // Keep models warm for subsequent transcriptions to avoid re-initialization errors
        let text = result.text
        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "parakeet", model: modelIdForCache, language: nil, preprocessing: preprocessingEnabled) {
            TranscriptionCache.shared.store(key, result: text)
        }
        scheduleIdleUnload()
        return text
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
    private func ensureVadManager() async throws -> VadManager? {
        if let v = vadManager { return v }
        do {
            let cfg = VadConfig(
                threshold: Float(UserDefaults.standard.object(forKey: "parakeet.vad.threshold") as? Double ?? 0.5),
                debugMode: false,
                computeUnits: .cpuAndNeuralEngine
            )
            let v = try await VadManager(config: cfg)
            vadManager = v
            return v
        } catch {
            return nil
        }
    }

    // Returns trimmed samples if VAD finds speech; nil otherwise
    private func applyVADIfAvailable(_ samples: [Float]) async throws -> [Float]? {
        guard let vad = try await ensureVadManager() else { return nil }
        if samples.isEmpty { return nil }
        // Use 0.6 segmentation API for robust trimming
        var segCfg = VadSegmentationConfig.default
        // Lightly-tuned defaults for single-speaker dictation
        segCfg.minSpeechDuration = 0.25
        segCfg.minSilenceDuration = 0.35
        segCfg.speechPadding = 0.1
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
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var samples: [Float] = []
        if inFormat == outFormat {
            // Fast path: read directly
            let capacity: AVAudioFrameCount = 4096
            while true {
                let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
                try inputFile.read(into: buf, frameCount: capacity)
                if buf.frameLength == 0 { break }
                let ptr = buf.floatChannelData![0]
                samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
            }
        } else {
            // Convert
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio format conversion failed"])
            }
            let inputFrameCapacity: AVAudioFrameCount = 4096
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputFrameCapacity)!
            while true {
                try inputFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
                if inputBuffer.frameLength == 0 { break }
                var inputDone = false
                let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)!
                let status = converter.convert(to: outputBuffer, error: nil, withInputFrom: { inNumPackets, outStatus in
                    if inputDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    outStatus.pointee = .haveData
                    inputDone = true
                    return inputBuffer
                })
                if status == .haveData, let ptr = outputBuffer.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength)))
                }
                inputBuffer.frameLength = 0
            }
        }
        return samples
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
    private static func decodeWithAssetReader(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "Parakeet", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "AssetReader failed to start: \(String(describing: reader.error))"])
        }
        var samples: [Float] = []
        while reader.status == .reading {
            if let sbuf = output.copyNextSampleBuffer(), let bbuf = CMSampleBufferGetDataBuffer(sbuf) {
                var length: Int = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(bbuf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer {
                    let count = length / MemoryLayout<Float>.size
                    let ptr = dataPointer.withMemoryRebound(to: Float.self, capacity: count) { $0 }
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                }
                CMSampleBufferInvalidate(sbuf)
            } else {
                break
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Parakeet", code: -4, userInfo: [NSLocalizedDescriptionKey: "AssetReader failed"])
        }
        return samples
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
