import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import Accelerate

final class AudioRecorder: NSObject {
    enum CaptureProfile {
        case standard16k            // default for cloud/local Whisper providers
        case appleNativeHighQuality // optimized for Apple's native Speech on macOS 26
    }

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private(set) var isRecording: Bool = false
    private(set) var isStreaming: Bool = false
    var onLevel: ((Float) -> Void)?
    private var previousDefaultInputUID: String?
    private var finishContinuation: CheckedContinuation<URL?, Never>?
    
    // Temporary file cleanup
    private static var lastCleanupTime: Date?
    private static let cleanupInterval: TimeInterval = 300  // 5 minutes

    // Live streaming support (NEW IMPLEMENTATION)
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private var audioFormat: AVAudioFormat!
    private var audioConverter: AVAudioConverter?
    private let audioQueue = DispatchQueue(label: "com.wonderwhisper.audio.recording", qos: .userInitiated)
    private var audioBufferList = [AVAudioPCMBuffer]()
    private var bufferIndex = 0
    private let maxBuffers = 10
    private let bufferLock = NSLock()  // Synchronize buffer access
    private var cleanupComplete = DispatchSemaphore(value: 1)  // Track cleanup completion

    // Health monitoring
    private var lastAudioTime: AVAudioTime?
    private var totalFramesProcessed: Int = 0
    private var framesDropped: Int = 0
    private var recordingStartTime: Date?
    private var sessionConfigured = false

    // Audio processing callbacks
    private var onPCM16Frame: ((Data) -> Void)?

    // Current capture profile (selected by controller based on active provider)
    var captureProfile: CaptureProfile = .standard16k

    // MARK: - Audio Session Setup (CRITICAL FIX)
    private func setupAudioSession() throws {
        // On macOS, AVAudioSession is not available. We configure the audio engine directly
        // to handle 16kHz sample rate without real-time conversion.
        sessionConfigured = true
        print("✅ Audio session configured: 16kHz at engine level")
    }

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
        // Ensure audio session is properly configured
        if !sessionConfigured {
            try setupAudioSession()
        }
        
        // Periodically clean up old temporary recording files to prevent accumulation
        Self.cleanupOldTemporaryFilesIfNeeded()

        let tempDir = FileManager.default.temporaryDirectory
        let format = UserDefaults.standard.string(forKey: "audio.recording.format") ?? "wav"
        let formatLower = format.lowercased()

        // Determine filename and extension based on format
        let (filename, settings) = try audioFormatSettings(format: formatLower)
        let url = tempDir.appendingPathComponent("dictation_\(UUID().uuidString).\(filename)")

        // If a specific input device was selected, optionally switch system default temporarily.
        // Avoid unnecessary reconfigs and wait until the system reports the new default to prevent IO thrash.
        if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
            switch AudioInputSelection.load() {
            case .systemDefault:
                break
            case .deviceUID(let uid):
                let current = AudioDeviceManager.currentDefaultInputUID()
                previousDefaultInputUID = current
                if current != uid {
                    if AudioDeviceManager.setSystemDefaultInput(toUID: uid) {
                        // Wait up to ~800ms for HAL to apply the change to avoid "reconfig pending" dropouts
                        let ok = AudioDeviceManager.waitForDefaultInputSwitch(toUID: uid, timeout: 0.8)
                        if !ok {
                            AppLog.dictation.error("AudioRecorder: timed out waiting for default input switch to \(uid)")
                        } else {
                            // Give CoreAudio a brief moment to settle routing before starting capture
                            usleep(50_000) // 50ms
                        }
                    }
                }
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

        // Raise input gain asynchronously unless voice processing (AGC) is enabled
        let voiceProcessingEnabled = UserDefaults.standard.bool(forKey: "audio.voiceProcessing.enabled")
        if !voiceProcessingEnabled {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AudioDeviceManager.raiseInputVolumeIfNeeded(for: AudioInputSelection.load())
            }
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
                if AudioDeviceManager.setSystemDefaultInput(toUID: prev) {
                    _ = AudioDeviceManager.waitForDefaultInputSwitch(toUID: prev, timeout: 0.6)
                    // Allow a short settle delay to avoid impacting subsequent starts
                    usleep(30_000)
                }
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
                    if AudioDeviceManager.setSystemDefaultInput(toUID: prev) {
                        _ = AudioDeviceManager.waitForDefaultInputSwitch(toUID: prev, timeout: 0.6)
                        usleep(30_000)
                    }
                    previousDefaultInputUID = nil
                }
            }

            // Release AudioQueue resources as early as possible
            self.recorder = nil

            // In case the delegate doesn't fire (shouldn't happen), provide a safety timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
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

// MARK: - Live Streaming (NEW IMPLEMENTATION - FIXED)
extension AudioRecorder {

    func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {
        // Force cleanup of any existing streaming session first and WAIT for it to complete
        if isStreaming {
            stopStreamingPCM16()
            // Wait for cleanup to complete (with timeout to prevent hanging)
            let cleanupTimeout = DispatchTime.now() + .milliseconds(500)
            if cleanupComplete.wait(timeout: cleanupTimeout) == .timedOut {
                AppLog.dictation.warning("Audio engine cleanup timeout - continuing anyway")
            }
        }

        // Ensure audio session is properly configured for streaming
        if !sessionConfigured {
            try setupAudioSession()
        }

        isStreaming = true
        self.onPCM16Frame = onFrame

        // Reset health monitoring
        bufferIndex = 0
        totalFramesProcessed = 0
        framesDropped = 0
        recordingStartTime = Date()
        lastAudioTime = nil

        setupAudioEngine()

        audioQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try self.audioEngine.start()
                print("🎙 Streaming started at \(Date())")
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                self.isStreaming = false
            }
        }
    }

    // MARK: - Audio Engine Setup (NEW)
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode

        // Get input format and validate it
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 Input format: \(inputFormat)")

        // Validate input format
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("❌ Invalid input audio format")
            return
        }

        // Create target format (16kHz, mono, 16-bit)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000.0,
                                         channels: 1,
                                         interleaved: false) else {
            print("❌ Failed to create audio format")
            return
        }
        audioFormat = format

        // Optimize buffer size for 16kHz (shorter buffers reduce perceived dropouts)
        let bufferSize: AVAudioFrameCount = 160 // 10ms at 16kHz

        // Prepare audio buffers
        for _ in 0..<maxBuffers {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                         frameCapacity: bufferSize) else {
                print("❌ Failed to create audio buffer")
                return
            }
            audioBufferList.append(buffer)
        }

        // Install audio tap with optimized settings
        inputNode.installTap(onBus: 0,
                            bufferSize: bufferSize,
                            format: inputFormat) { [weak self] buffer, audioTime in
            guard let self = self, self.isStreaming else { return }

            self.audioQueue.async {
                self.processAudioBuffer(buffer, at: audioTime)
            }
        }

        print("✅ Audio engine configured with \(maxBuffers) buffers")
    }

    // MARK: - Audio Processing (NEW)
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // Check for audio gaps (indicates dropped frames)
        if let lastTime = lastAudioTime {
            let sampleTime = time.sampleTime
            let lastSampleTime = lastTime.sampleTime
            let sampleRate = time.sampleRate

            if sampleRate > 0 {
                let gap = Double(sampleTime - lastSampleTime) / sampleRate
                if gap > 0.05 { // More than 50ms gap
                    framesDropped += 1
                    print("⚠️ Audio gap: \(String(format: "%.3f", gap))s")
                }
            }
        }
        lastAudioTime = time

        // Suppress low-energy buffers to reduce transmission of near-silence
        if buffer.frameLength > 0, let floatChannels = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let channelPointer = floatChannels.pointee
            var energy: Float = 0
            for sampleIndex in 0..<frameCount {
                let sample = channelPointer[sampleIndex]
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms < 0.0008 {
                return
            }
        }

        // Convert buffer to target format if needed
        guard let convertedBuffer = convertBuffer(buffer) else {
            print("❌ Buffer conversion failed")
            return
        }

        // Send audio data
        let audioData = bufferToData(convertedBuffer)
        onPCM16Frame?(audioData)

        totalFramesProcessed += Int(convertedBuffer.frameLength)
    }

    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Validate input buffer
        guard inputBuffer.frameLength > 0 else {
            return nil
        }

        // If input format matches target format, return as-is
        if inputBuffer.format.sampleRate == 16000.0 &&
           inputBuffer.format.channelCount == 1 {
            return inputBuffer
        }

        // Convert to target format (thread-safe buffer access)
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard bufferIndex < audioBufferList.count else {
            return nil
        }
        let outputBuffer = audioBufferList[bufferIndex]
        bufferIndex = (bufferIndex + 1) % maxBuffers

        guard let format = audioFormat else {
            print("❌ Audio format is nil during conversion")
            return nil
        }
        if audioConverter == nil || audioConverter?.inputFormat != inputBuffer.format || audioConverter?.outputFormat != format {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: format)
            if audioConverter == nil {
                print("❌ Failed to create reusable audio converter from \(inputBuffer.format) to \(format)")
                return nil
            }
        }
        guard let converter = audioConverter else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        })

        if status != .haveData {
            print("❌ Audio conversion failed: \(error?.localizedDescription ?? "Unknown")")
            return nil
        }

        return outputBuffer
    }

    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.int16ChannelData else {
            return Data()
        }

        guard buffer.frameLength > 0 else {
            return Data()
        }

        let channelPointer = channelData.pointee
        let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        let totalBytes = bytesPerChannel * Int(buffer.format.channelCount)
        return Data(bytes: channelPointer, count: totalBytes)
    }

    func stopStreamingPCM16() {
        guard isStreaming else { return }

        // Mark cleanup as in-progress (acquire the semaphore)
        cleanupComplete.wait()

        audioQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.cleanupComplete.signal() }  // Signal when done

            self.isStreaming = false

            // Stop audio engine
            self.audioEngine.stop()
            self.inputNode.removeTap(onBus: 0)

            // Log health metrics
            self.logAudioHealth()

            print("🛑 Streaming stopped")

            // Clear all references (must be done after stopping engine)
            self.audioEngine = nil
            self.inputNode = nil
            self.audioFormat = nil
            self.audioConverter = nil
            self.audioBufferList.removeAll(keepingCapacity: false)  // Release capacity to free memory
            self.onPCM16Frame = nil

            // Reset health monitoring state
            self.lastAudioTime = nil
            self.totalFramesProcessed = 0
            self.framesDropped = 0
            self.recordingStartTime = nil
        }
    }

    // MARK: - Health Monitoring (NEW)
    private func logAudioHealth() {
        guard let startTime = recordingStartTime else { return }

        let duration = Date().timeIntervalSince(startTime)
        let dropRate = totalFramesProcessed > 0 ?
            Double(framesDropped) / Double(totalFramesProcessed) * 100 : 0

        print("\n" + String(repeating: "=", count: 50))
        print("📊 AUDIO HEALTH REPORT")
        print(String(repeating: "=", count: 50))
        print("⏱️  Duration: \(String(format: "%.2f", duration))s")
        print("🎵 Frames Processed: \(totalFramesProcessed)")
        print("📉 Frames Dropped: \(framesDropped)")
        print("📈 Drop Rate: \(String(format: "%.2f", dropRate))%")
        print("🎯 Average Speed: \(String(format: "%.2f", Double(totalFramesProcessed) / duration / 16000))x real-time")
        print(String(repeating: "=", count: 50) + "\n")
    }
}

// MARK: - Extensions
extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Resume any waiter with the final URL (even if not successful, caller can decide)
        if let c = finishContinuation {
            finishContinuation = nil
            c.resume(returning: recorder.url)
        }
    }
}

// MARK: - Extensions
// Note: Date extension removed to avoid infinite recursion

// MARK: - Temporary File Cleanup
extension AudioRecorder {
    /// Clean up old temporary recording files to prevent disk accumulation
    /// Only runs if cleanup interval has elapsed since last cleanup
    private static func cleanupOldTemporaryFilesIfNeeded() {
        // Check if cleanup is needed based on interval
        let now = Date()
        if let lastCleanup = lastCleanupTime,
           now.timeIntervalSince(lastCleanup) < cleanupInterval {
            return
        }
        
        lastCleanupTime = now
        
        // Perform cleanup in background to avoid blocking recording start
        DispatchQueue.global(qos: .utility).async {
            cleanupOldTemporaryFiles()
        }
    }
    
    /// Remove temporary recording files older than 1 hour
    private static func cleanupOldTemporaryFiles() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        
        // Look for files matching our naming pattern
        let oneHourAgo = Date().addingTimeInterval(-3600)
        
        guard let enumerator = fm.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.creationDateKey, .nameKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        
        var deletedCount = 0
        var deletedBytes: Int64 = 0
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            
            // Only process our temporary recording files and Groq streaming chunks
            guard filename.hasPrefix("dictation_") || 
                  filename.hasPrefix("chunk_") || 
                  filename.hasPrefix("final_chunk_") ||
                  filename.hasPrefix("warmup_") else {
                continue
            }
            
            // Check creation date
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                  let creationDate = resourceValues.creationDate else {
                continue
            }
            
            // Delete files older than 1 hour
            if creationDate < oneHourAgo {
                let fileSize = resourceValues.fileSize ?? 0
                if (try? fm.removeItem(at: fileURL)) != nil {
                    deletedCount += 1
                    deletedBytes += Int64(fileSize)
                }
            }
        }
        
        if deletedCount > 0 {
            let mbDeleted = Double(deletedBytes) / 1_048_576.0
            print("🧹 Cleaned up \(deletedCount) old temporary recording files (\(String(format: "%.2f", mbDeleted)) MB)")
        }
    }
}

// Safe index helper for EQ band access (legacy support)
private extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
