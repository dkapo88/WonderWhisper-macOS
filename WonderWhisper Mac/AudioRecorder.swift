import Foundation
import AVFoundation

final class AudioRecorder: NSObject {
    enum CaptureProfile {
        case standard16k            // default for cloud/local Whisper providers
        case appleNativeHighQuality // optimized for Apple's native Speech on macOS 26
    }
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private(set) var isRecording: Bool = false
    var onLevel: ((Float) -> Void)?
    private var previousDefaultInputUID: String?
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    // Live streaming support (AVAudioEngine)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmAccumulator = Data()
    private var isStreaming: Bool = false
    private let streamQueue = DispatchQueue(label: "audio.stream.queue", qos: .userInitiated)
    private var onPCM16Frame: ((Data) -> Void)?
    
    // Memory recording removed due to unreliable output
    // Current capture profile (selected by controller based on active provider)
    var captureProfile: CaptureProfile = .standard16k

    // MARK: - Audio Format Configuration
    private func audioFormatSettings(format: String) throws -> (filename: String, settings: [String: Any]) {
        // When capturing for Apple's native Speech (Tahoe), prefer a high-quality,
        // uncompressed 48 kHz mono WAV so the transcriber avoids resampling and
        // keeps high‑frequency cues for better accuracy.
        if captureProfile == .appleNativeHighQuality {
            return ("wav", [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false
            ])
        }
        switch format {
        case "mp3":
            // Note: macOS doesn't natively support MP3 recording via AVAudioRecorder
            // Fall back to AAC with aggressive compression for similar file sizes
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000 // Aggressive AAC compression = ~2 KB/s, similar to MP3
            ])
        case "ogg":
            // Note: macOS doesn't natively support OGG recording via AVAudioRecorder
            // Fall back to AAC with very low bitrate for similar compression
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000 // Aggressive AAC compression = ~2 KB/s
            ])
        case "aac":
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000 // Original 32 kbps = ~4 KB/s
            ])
        default: // "wav"
            return ("wav", [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
        }
    }

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let format = UserDefaults.standard.string(forKey: "audio.recording.format") ?? "wav"
        let formatLower = format.lowercased()
        
        // Determine filename and extension based on format
        let (filename, settings) = try audioFormatSettings(format: formatLower)
        let url = tempDir.appendingPathComponent("dictation_\(UUID().uuidString).\(filename)")

        // Recording settings optimized for speech transcription at 16kHz mono

        // If a specific input device was selected, optionally switch system default temporarily
        if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
            switch AudioInputSelection.load() {
            case .systemDefault:
                break
            case .deviceUID(let uid):
                previousDefaultInputUID = AudioDeviceManager.currentDefaultInputUID()
                _ = AudioDeviceManager.setSystemDefaultInput(toUID: uid)
            }
        }

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        guard recorder?.prepareToRecord() == true else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "prepareToRecord failed"])
        }
        recorder?.record()
        isRecording = true
        startLevelUpdates()
        // Raise input gain asynchronously to avoid delaying recording start
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AudioDeviceManager.raiseInputVolumeIfNeeded(for: AudioInputSelection.load())
        }
        return url
    }

    func stopRecording() -> URL? {
        guard isRecording, let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        isRecording = false
        stopLevelUpdates()
        // Restore previous default input device if we changed it
        if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
            if let prev = previousDefaultInputUID {
                _ = AudioDeviceManager.setSystemDefaultInput(toUID: prev)
                previousDefaultInputUID = nil
            }
        }
        self.recorder = nil // release AudioQueue promptly to avoid device reconfig contention
        return url
    }

    // Wait until AVAudioRecorder flushes and finishes writing before returning the URL
    func stopRecordingAndWait() async -> URL? {
        guard isRecording, let recorder else { return nil }
        let url = recorder.url
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            finishContinuation = cont
            self.recorder?.stop()
            isRecording = false
            stopLevelUpdates()
            // Restore previous default input device if we changed it
            if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
                if let prev = previousDefaultInputUID {
                    _ = AudioDeviceManager.setSystemDefaultInput(toUID: prev)
                    previousDefaultInputUID = nil
                }
            }
            // Release AudioQueue resources as early as possible
            self.recorder = nil
            // In case the delegate doesn't fire (shouldn't happen), provide a safety timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                if let c = self.finishContinuation {
                    self.finishContinuation = nil
                    AppLog.dictation.log("AudioRecorder: delegate did not fire in time, resuming with URL after safety timeout")
                    c.resume(returning: url)
                }
            }
        }
    }

    private func startLevelUpdates() {
        stopLevelUpdates()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self, let r = self.recorder else { return }
            r.updateMeters()
            let avg = r.averagePower(forChannel: 0)
            let peak = r.peakPower(forChannel: 0)
            // Use the more reactive of the two
            let level = max(Self.normalize(power: avg), Self.normalize(power: peak))
            self.onLevel?(level)
        }
        if let t = levelTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
        onLevel?(0)
    }

    private static func normalize(power: Float) -> Float {
        // Map dB (-160..0) to 0..1, with floor at -50 dB for better responsiveness
        let minDb: Float = -50
        let clamped = max(power, minDb)
        let range = minDb * -1
        let norm = (clamped + range) / range // 0..1 linear
        // Slight easing to emphasize small signals
        return pow(norm, 1.1)
    }
}

// Memory recording extension removed - was causing unreliable transcription output

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Resume any waiter with the final URL (even if not successful, caller can decide)
        if let c = finishContinuation { finishContinuation = nil; c.resume(returning: recorder.url) }
    }
}

// MARK: - Live Streaming (PCM16 16 kHz mono)
extension AudioRecorder {
    func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {
        // Force cleanup of any existing streaming session first
        if isStreaming {
            stopStreamingPCM16()
            // Give audio system time to fully clean up
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        isStreaming = true
        self.onPCM16Frame = onFrame

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Get input format and validate it
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid input audio format"])
        }

        // Connect input to main mixer with volume muted to drive the engine without monitoring
        engine.mainMixerNode.outputVolume = 0
        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not create target audio format"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        self.converter = converter
        pcmAccumulator.removeAll(keepingCapacity: true)

        // Stream chunk size: default 30ms at 16kHz; configurable via UserDefaults("audio.stream.chunkMs")
        let configuredMs = UserDefaults.standard.integer(forKey: "audio.stream.chunkMs")
        let chunkMs = configuredMs > 0 ? configuredMs : 30
        // samplesPerMs at 16kHz = 16; bytesPerSample (Int16) = 2
        let chunkBytes = chunkMs * 16 * 2

        do {
            engine.prepare()
            input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self, let converter = self.converter, self.isStreaming else { return }
                // Prepare output buffer with a reasonable capacity
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(1600)) else { return }
                outBuffer.frameLength = 0

                let status = converter.convert(to: outBuffer, error: nil, withInputFrom: { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                })

                if status == .haveData, let channel = outBuffer.int16ChannelData {
                    let samples = channel[0]
                    let frames = Int(outBuffer.frameLength)
                    let bytes = UnsafeBufferPointer(start: samples, count: frames)
                    let data = Data(buffer: bytes)
                    self.pcmAccumulator.append(data)

                    while self.pcmAccumulator.count >= chunkBytes {
                        let chunk = self.pcmAccumulator.prefix(chunkBytes)
                        self.pcmAccumulator.removeFirst(chunkBytes)
                        let chunkData = Data(chunk)
                        self.streamQueue.async { [onFrame] in
                            onFrame(chunkData)
                        }
                    }
                }
            }
            
            try engine.start()
            AppLog.dictation.log("AudioRecorder: engine.start OK; input sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
        } catch {
            // Log OSStatus if available for diagnostics (-10877 etc.)
            let ns = error as NSError
            AppLog.dictation.error("AudioRecorder: engine.start failed domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            // Clean up on failure
            isStreaming = false
            self.engine?.stop()
            if let input = self.engine?.inputNode { input.removeTap(onBus: 0) }
            self.engine = nil
            self.converter = nil
            throw error
        }
    }

    func stopStreamingPCM16() {
        guard isStreaming else { return }
        isStreaming = false

        // Remove tap first to avoid callbacks during engine teardown
        if let input = self.engine?.inputNode {
            input.removeTap(onBus: 0)
        }

        // Then stop the engine
        self.engine?.stop()

        // Clear all references
        engine = nil
        converter = nil
        pcmAccumulator.removeAll()
        onPCM16Frame = nil
    }
}
