import Foundation
import AVFoundation
import Accelerate
import QuartzCore

enum AudioPreprocessor {
    // Feature flag: defaults write com.slumdev88.wonderwhisper.WonderWhisper-Mac audio.preprocess.enabled -bool YES
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audio.preprocess.enabled")
    }

    private static var debugLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audio.preprocess.debug")
    }
    
    // Smart preprocessing: only apply when beneficial based on audio quality analysis
    static var smartModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audio.preprocess.smart") // defaults to false for backward compatibility
    }

    // Apply simple, robust steps for ASR clarity:
    // - First‑order high‑pass at 90 Hz to remove rumble
    // - Light pre‑emphasis to improve consonant intelligibility
    // - RMS normalization to target ~ -20 dBFS with peak cap
    // Returns a new 16kHz mono Float32 WAV file URL.
    static func processIfEnabled(_ url: URL) -> URL {
        guard isEnabled else { return url }

        let start = CACurrentMediaTime()

        if smartModeEnabled {
            do {
                let quality = try analyzeAudioQuality(url)
                let decision = quality.needsProcessing
                if debugLoggingEnabled {
                    AppLog.dictation.log("AudioPreprocessor: smart analysis SNR=\(quality.snr, format: .fixed(precision: 2)) needsProcessing=\(decision)")
                }
                if decision {
                    let processed = try process(url)
                    if debugLoggingEnabled {
                        AppLog.dictation.log("AudioPreprocessor: processed in \(CACurrentMediaTime() - start, format: .fixed(precision: 4))s")
                    }
                    return processed
                } else {
                    return url
                }
            } catch {
                if debugLoggingEnabled {
                    AppLog.dictation.error("AudioPreprocessor: smart analysis failed \(error.localizedDescription)")
                }
                do {
                    let processed = try process(url)
                    if debugLoggingEnabled {
                        AppLog.dictation.log("AudioPreprocessor: processed (fallback) in \(CACurrentMediaTime() - start, format: .fixed(precision: 4))s")
                    }
                    return processed
                } catch {
                    return url
                }
            }
        } else {
            do {
                let processed = try process(url)
                if debugLoggingEnabled {
                    AppLog.dictation.log("AudioPreprocessor: processed (no smart) in \(CACurrentMediaTime() - start, format: .fixed(precision: 4))s")
                }
                return processed
            } catch {
                return url
            }
        }
    }
    
    // Analyze audio quality to determine if preprocessing is beneficial
    static func analyzeAudioQuality(_ url: URL) throws -> AudioQualityAnalysis {
        let decoded = try decodeToFloatMono16k(url: url)
        guard !decoded.isEmpty else {
            return AudioQualityAnalysis(needsProcessing: false, snr: 0, hasLowFrequencyNoise: false, peakLevel: 0)
        }

        let samples = decimateForAnalysis(decoded, maxSamples: 12_000)
        
        // Analyze key quality metrics
        let snr = estimateSNR(samples)
        let hasLowFreqNoise = detectLowFrequencyNoise(samples)
        var peakLevel: Float = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peakLevel, vDSP_Length(buf.count))
        }
        var rmsLevel: Float = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rmsLevel, vDSP_Length(buf.count))
        }
        
        let needsProcessing = snr < 15.0 ||  // Poor SNR
                             hasLowFreqNoise ||  // Low frequency rumble
                             peakLevel < 0.1 ||  // Very quiet audio
                             rmsLevel > 0.7      // Over-amplified audio
        
        return AudioQualityAnalysis(
            needsProcessing: needsProcessing,
            snr: snr,
            hasLowFrequencyNoise: hasLowFreqNoise,
            peakLevel: peakLevel
        )
    }
    
    struct AudioQualityAnalysis {
        let needsProcessing: Bool
        let snr: Float           // Signal-to-noise ratio estimate
        let hasLowFrequencyNoise: Bool
        let peakLevel: Float     // Peak amplitude level
    }
    
    // Estimate signal-to-noise ratio using spectral analysis
    private static func estimateSNR(_ samples: [Float]) -> Float {
        // Simple SNR estimation: ratio of signal power to noise floor
        // Take samples in quiet periods (low amplitude) as noise estimate
        let count = samples.count
        guard count > 0 else { return 0 }
        var magnitudes = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            magnitudes.withUnsafeMutableBufferPointer { dst in
                vDSP_vabs(base, 1, dst.baseAddress!, 1, vDSP_Length(count))
            }
        }
        magnitudes.sort()
        let quarter = max(1, count / 4)
        let noiseFloor = magnitudes.prefix(quarter).reduce(0, +) / Float(quarter)
        let signalLevel = magnitudes.suffix(quarter).reduce(0, +) / Float(quarter)
        
        guard noiseFloor > 0 else { return 40.0 } // Assume good SNR if no measurable noise
        let snr = 20 * log10(signalLevel / noiseFloor)
        return max(0, min(40, snr)) // Clamp to reasonable range
    }
    
    // Detect low-frequency noise/rumble
    private static func detectLowFrequencyNoise(_ samples: [Float]) -> Bool {
        // Simple high-pass filter to isolate low frequencies
        var filtered = samples
        applyHighPass(in: &filtered, cutoffHz: 120, sampleRate: 16_000)
        var originalRMS: Float = 0
        var filteredRMS: Float = 0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &originalRMS, vDSP_Length(buf.count))
        }
        filtered.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &filteredRMS, vDSP_Length(buf.count))
        }
        if originalRMS == 0 { return false }
        let energyReduction = (originalRMS - filteredRMS) / originalRMS
        return energyReduction > 0.15 // 15% energy in low frequencies indicates rumble
    }

    static func process(_ url: URL) throws -> URL {
        let sr: Double = 16_000
        var samples = try decodeToFloatMono16k(url: url)
        if samples.isEmpty { return url }

        applyHighPass(in: &samples, cutoffHz: 90, sampleRate: sr)
        applyPreEmphasis(in: &samples, coeff: 0.97)
        let appliedGain = normalizeRMS(in: &samples, targetRMS: 0.08, peakLimit: 0.98, maxGain: 8.0)

        let outURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_proc.wav")
        try writeInt16Mono16kWav(samples: samples, to: outURL)

        if debugLoggingEnabled {
            AppLog.dictation.log("AudioPreprocessor: wrote processed file gain=\(appliedGain, format: .fixed(precision: 3)) frames=\(samples.count)")
        }
        return outURL
    }

    // MARK: - DSP helpers
    private static func applyHighPass(in samples: inout [Float], cutoffHz: Double, sampleRate: Double) {
        guard !samples.isEmpty else { return }
        let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var yPrev: Float = 0
        var xPrev: Float = samples[0]
        for i in 0..<samples.count {
            let x = samples[i]
            let y = alpha * (yPrev + x - xPrev)
            samples[i] = y
            yPrev = y
            xPrev = x
        }
    }

    private static func applyPreEmphasis(in samples: inout [Float], coeff: Float) {
        guard samples.count > 1 else { return }
        let original = samples
        var result = samples
        result[0] = original[0]
        var minusCoeff = -coeff
        original.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            result.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                vDSP_vmsa(srcBase + 1, 1, srcBase, 1, &minusCoeff, dstBase + 1, 1, vDSP_Length(src.count - 1))
            }
        }
        samples = result
    }

    @discardableResult
    private static func normalizeRMS(in samples: inout [Float], targetRMS: Double, peakLimit: Double, maxGain: Double) -> Double {
        guard !samples.isEmpty else { return 1.0 }
        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(buf.count))
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buf.count))
        }
        if rms <= 0 { return 1.0 }
        var gain = Float(targetRMS) / rms
        if peak * gain > Float(peakLimit) {
            gain = Float(peakLimit) / max(peak, 1e-9)
        }
        gain = min(gain, Float(maxGain))
        if abs(gain - 1.0) < 1e-3 { return Double(gain) }
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &gain, base, 1, vDSP_Length(buf.count))
            var minVal: Float = -1
            var maxVal: Float = 1
            vDSP_vclip(base, 1, &minVal, &maxVal, base, 1, vDSP_Length(buf.count))
        }
        return Double(gain)
    }

    private static func decimateForAnalysis(_ samples: [Float], maxSamples: Int) -> [Float] {
        guard samples.count > maxSamples, maxSamples > 0 else { return samples }
        let stride = max(1, samples.count / maxSamples)
        var result = [Float]()
        result.reserveCapacity(maxSamples)
        var index = 0
        for _ in 0..<maxSamples where index < samples.count {
            result.append(samples[index])
            index += stride
        }
        return result
    }

    // MARK: - I/O
    private static func decodeToFloatMono16k(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioPreprocessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
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
            throw NSError(domain: "AudioPreprocessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Reader failed: \(String(describing: reader.error))"])
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
            throw reader.error ?? NSError(domain: "AudioPreprocessor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Reader failed"])
        }
        return samples
    }

    private static func writeInt16Mono16kWav(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = 16_000 * 2 // 2 seconds per write
        var scale: Float = Float(Int16.max)
        var clipped = [Float](repeating: 0, count: chunk)
        var scaled = [Float](repeating: 0, count: chunk)
        var int16Data = [Int16](repeating: 0, count: chunk)
        var writeError: Error?
        samples.withUnsafeBufferPointer { srcBuf in
            guard let srcBase = srcBuf.baseAddress else { return }
            var offset = 0
            while offset < samples.count {
                let n = min(chunk, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                clipped.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    var minVal: Float = -1
                    var maxVal: Float = 1
                    vDSP_vclip(srcBase + offset, 1, &minVal, &maxVal, dstBase, 1, vDSP_Length(n))
                }
                scaled.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    clipped.withUnsafeBufferPointer { src in
                        guard let clipBase = src.baseAddress else { return }
                        vDSP_vsmul(clipBase, 1, &scale, dstBase, 1, vDSP_Length(n))
                    }
                }
                int16Data.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    scaled.withUnsafeBufferPointer { src in
                        guard let scaleBase = src.baseAddress else { return }
                        vDSP_vfix16(scaleBase, 1, dstBase, 1, vDSP_Length(n))
                    }
                }
                int16Data.withUnsafeBufferPointer { ints in
                    if let dst = buffer.int16ChannelData?[0] {
                        dst.update(from: ints.baseAddress!, count: n)
                    }
                }
                do {
                    try file.write(from: buffer)
                } catch {
                    writeError = error
                    break
                }
                offset += n
            }
        }
        if let error = writeError { throw error }
    }
}
