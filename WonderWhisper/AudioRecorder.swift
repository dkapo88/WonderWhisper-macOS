import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import Accelerate

final class AudioRecorder: NSObject {
    enum CaptureProfile {
        case standard16k            // default for cloud/local Whisper providers
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
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private let audioQueue = DispatchQueue(label: "com.wonderwhisper.audio.recording", qos: .userInitiated)
    private let audioQueueKey = DispatchSpecificKey<Void>()
    private var audioBufferList = [AVAudioPCMBuffer]()
    private var bufferIndex = 0
    private let maxBuffers = 10
    private let bufferLock = NSLock()  // Synchronize buffer access
    private var cleanupComplete = DispatchSemaphore(value: 1)  // Track cleanup completion

    // Audio processing callbacks
    private var onPCM16Frame: ((Data) -> Void)?

    // Current capture profile (selected by controller based on active provider)
    var captureProfile: CaptureProfile = .standard16k

    override init() {
        super.init()
        audioQueue.setSpecific(key: audioQueueKey, value: ())
    }

    // MARK: - Microphone Selection Override
    private func applyInputSelectionOverrideIfNeeded() {
        let selection = AudioInputSelection.load()
        switch selection {
        case .systemDefault:
            return
        case .deviceUID:
            guard let uid = AudioDeviceManager.resolvedInputUID(for: selection) else { return }
            let current = AudioDeviceManager.currentDefaultInputUID()
            if current != uid {
                previousDefaultInputUID = current
                if AudioDeviceManager.setSystemDefaultInput(toUID: uid) {
                    _ = AudioDeviceManager.waitForDefaultInputSwitch(toUID: uid, timeout: 1.0)
                    print("🎙️ Default input set to \(uid)")
                } else {
                    print("⚠️ Failed to set default input to \(uid)")
                }
            }
        }
    }

    private func restoreInputSelectionIfNeeded() {
        guard let prev = previousDefaultInputUID else { return }
        previousDefaultInputUID = nil
        if AudioDeviceManager.currentDefaultInputUID() != prev {
            _ = AudioDeviceManager.setSystemDefaultInput(toUID: prev)
            _ = AudioDeviceManager.waitForDefaultInputSwitch(toUID: prev, timeout: 1.0)
            print("🔁 Default input restored to \(prev)")
        }
    }

    // MARK: - Audio Format Configuration
    private func audioFormatSettings() -> (filename: String, settings: [String: Any]) {
        return ("wav", [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
    }

    func startRecording() throws -> URL {
        // Periodically clean up old temporary recording files to prevent accumulation
        Self.cleanupOldTemporaryFilesIfNeeded()

        let tempDir = FileManager.default.temporaryDirectory

        // Determine filename and extension based on format
        let (filename, settings) = audioFormatSettings()
        let url = tempDir.appendingPathComponent("dictation_\(UUID().uuidString).\(filename)")

        // Apply microphone selection override before starting recording
        applyInputSelectionOverrideIfNeeded()
        var shouldRestoreInputOverride = true
        defer {
            if shouldRestoreInputOverride {
                restoreInputSelectionIfNeeded()
            }
        }

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        guard recorder?.prepareToRecord() == true else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "prepareToRecord failed"
            ])
        }
        shouldRestoreInputOverride = false
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

        // Restore previous microphone selection
        restoreInputSelectionIfNeeded()

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

            // Restore previous microphone selection
            restoreInputSelectionIfNeeded()

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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.recorder != nil else { return }
            self.levelTimer?.invalidate()
            self.levelTimer = nil
            self.onLevel?(0)
            guard self.isRecording else { return }

            let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isRecording, let r = self.recorder else { return }
                r.updateMeters()
                let avg = r.averagePower(forChannel: 0)
                let peak = r.peakPower(forChannel: 0)
                let level = Self.visualMeterLevel(averagePower: avg, peakPower: peak)
                self.onLevel?(level)
            }
            self.levelTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopLevelUpdates() {
        DispatchQueue.main.async { [weak self] in
            self?.levelTimer?.invalidate()
            self?.levelTimer = nil
            self?.onLevel?(0)
        }
    }

    private static func visualMeterLevel(averagePower: Float, peakPower: Float) -> Float {
        let average = normalizeVisualPower(averagePower)
        let peak = normalizeVisualPower(peakPower)
        let blended = average * 0.55 + peak * 0.45
        return blended < 0.003 ? 0 : min(1, blended)
    }

    private static func normalizeVisualPower(_ power: Float) -> Float {
        let silenceFloor: Float = -62
        let speechCeiling: Float = -12
        guard power > silenceFloor else { return 0 }
        let clamped = min(max(power, silenceFloor), speechCeiling)
        let linear = (clamped - silenceFloor) / (speechCeiling - silenceFloor)
        return pow(linear, 0.85)
    }

    private static func visualMeterLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var sumSquares: Float = 0
        var peak: Float = 0

        if let channels = buffer.floatChannelData {
            let channel = channels.pointee
            for sampleIndex in 0..<frameCount {
                let value = abs(channel[sampleIndex])
                sumSquares += value * value
                peak = max(peak, value)
            }
        } else if let channels = buffer.int16ChannelData {
            let channel = channels.pointee
            let scale = Float(Int16.max)
            for sampleIndex in 0..<frameCount {
                let value = abs(Float(channel[sampleIndex]) / scale)
                sumSquares += value * value
                peak = max(peak, value)
            }
        } else {
            return 0
        }

        let rms = sqrtf(sumSquares / Float(frameCount))
        guard rms > 0 || peak > 0 else { return 0 }
        let avgDb = 20 * log10(max(rms, 0.000_001))
        let peakDb = 20 * log10(max(peak, 0.000_001))
        return visualMeterLevel(averagePower: avgDb, peakPower: peakDb)
    }
}

// MARK: - Live Streaming (NEW IMPLEMENTATION - FIXED)
extension AudioRecorder {

    func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {
        // Force cleanup of any existing streaming session first and WAIT for it to complete
        if isStreaming {
            stopStreamingPCM16()
        }

        // Apply microphone selection override before starting streaming
        applyInputSelectionOverrideIfNeeded()

        isStreaming = true
        self.onPCM16Frame = onFrame

        bufferIndex = 0

        setupAudioEngine()

        // Validate engine was set up successfully before starting
        guard let engine = audioEngine else {
            print("❌ Audio engine setup failed - cannot start streaming")
            isStreaming = false
            onPCM16Frame = nil
            restoreInputSelectionIfNeeded()
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Audio engine setup failed"
            ])
        }

        do {
            try engine.start()
            print("🎙 Streaming started at \(Date())")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            isStreaming = false
            teardownStreamingResources(logHealth: false)
            throw error
        }
    }

    // MARK: - Audio Engine Setup (NEW)
    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        audioEngine = engine
        let node = engine.inputNode
        inputNode = node

        // Get input format and validate it
        let inputFormat = node.outputFormat(forBus: 0)
        print("🎤 Input format: \(inputFormat)")

        // Validate input format
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("❌ Invalid input audio format")
            audioEngine = nil
            inputNode = nil
            return
        }

        print("🎤 Hardware input sample rate: \(inputFormat.sampleRate) Hz")

        // Streaming providers expect stable PCM16 mono audio. Groq chunking and WAV headers
        // are built around 16 kHz, and Soniox accepts 16 kHz PCM directly.
        let targetSampleRate = 16_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            print("❌ Failed to create audio format")
            audioEngine = nil
            inputNode = nil
            return
        }
        audioFormat = format
        audioConverter = AVAudioConverter(from: inputFormat, to: format)
        print("🎤 Streaming output sample rate: \(format.sampleRate) Hz")

        // Tap buffer size: ~100ms of hardware audio. xAI recommends 100ms PCM
        // frames, and AVAudioEngine may deliver larger buffers than requested, so
        // keep enough converted-frame capacity to avoid silent truncation.
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(inputFormat.sampleRate / 10)
        let nominalOutputFrames = Int(ceil(Double(bufferSize) * targetSampleRate / inputFormat.sampleRate))
        let outputBufferSize = AVAudioFrameCount(max(nominalOutputFrames + 256, 4_096))

        // Prepare audio buffers
        bufferLock.lock()
        audioBufferList.removeAll()
        for _ in 0..<maxBuffers {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: outputBufferSize) else {
                print("❌ Failed to create audio buffer")
                bufferLock.unlock()
                audioEngine = nil
                inputNode = nil
                audioFormat = nil
                return
            }
            audioBufferList.append(buffer)
        }
        bufferLock.unlock()

        // Install audio tap
        node.installTap(onBus: 0,
                            bufferSize: bufferSize,
                            format: inputFormat) { [weak self] buffer, audioTime in
            guard let self = self, self.isStreaming else { return }

            self.audioQueue.async {
                self.processAudioBuffer(buffer, at: audioTime)
            }
        }

        print("✅ Audio engine configured with \(maxBuffers) buffers at \(format.sampleRate) Hz")
    }

    // MARK: - Audio Processing (NEW)
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime) {
        onLevel?(Self.visualMeterLevel(from: buffer))

        // Suppress low-energy buffers to reduce transmission of near-silence (optional)
        // Use user default to control RMS gate; default to 0 (disabled) for reliability
        let rmsGate = UserDefaults.standard.float(forKey: "audio.streaming.rmsGate")
        if rmsGate > 0, buffer.frameLength > 0, let floatChannels = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let channelPointer = floatChannels.pointee
            var energy: Float = 0
            for sampleIndex in 0..<frameCount {
                let sample = channelPointer[sampleIndex]
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms < rmsGate {
                return
            }
        }

        let expectedOutputFrames = Int(
            ceil(Double(buffer.frameLength) * 16_000.0 / buffer.format.sampleRate)
        )

        // Convert buffer to target format if needed
        guard let convertedBuffer = convertBuffer(buffer) else {
            print("❌ Buffer conversion failed")
            return
        }
        if expectedOutputFrames > 0 {
            let frameDeficit = expectedOutputFrames - Int(convertedBuffer.frameLength)
            if frameDeficit > max(32, expectedOutputFrames / 20) {
                print("⚠️ Streaming conversion under-emitted: produced=\(convertedBuffer.frameLength) expected≈\(expectedOutputFrames)")
            }
        }

        // Send audio data
        let audioData = bufferToData(convertedBuffer)
        onPCM16Frame?(audioData)
    }

    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Validate input buffer
        guard inputBuffer.frameLength > 0 else {
            return nil
        }

        guard let format = audioFormat else {
            print("❌ Audio format is nil during conversion")
            return nil
        }

        // Fast Path: If input format matches target format EXACTLY, return as-is.
        if inputBuffer.format.sampleRate == format.sampleRate &&
           inputBuffer.format.channelCount == 1 &&
           inputBuffer.format.commonFormat == .pcmFormatInt16 {
            return inputBuffer
        }

        guard let converter = audioConverter else {
            print("❌ Audio converter is nil during conversion")
            return nil
        }

        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !audioBufferList.isEmpty else { return nil }

        let outputBuffer = audioBufferList[bufferIndex % audioBufferList.count]
        bufferIndex = (bufferIndex + 1) % audioBufferList.count
        outputBuffer.frameLength = 0

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            print("❌ Buffer conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
            return nil
        }

        guard outputBuffer.frameLength > 0 else {
            return nil
        }

        return outputBuffer
    }

    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.int16ChannelData else {
            print("⚠️ bufferToData: no int16ChannelData available")
            return Data()
        }

        guard buffer.frameLength > 0 else {
            print("⚠️ bufferToData: frameLength is 0")
            return Data()
        }

        let channelPointer = channelData.pointee
        let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        // For mono output, only use first channel
        return Data(bytes: channelPointer, count: bytesPerChannel)
    }

    func stopStreamingPCM16() {
        guard isStreaming || audioEngine != nil || inputNode != nil else { return }

        cleanupComplete.wait()
        defer { cleanupComplete.signal() }

        let cleanup = { [weak self] in
            self?.teardownStreamingResources(logHealth: true)
        }

        if DispatchQueue.getSpecific(key: audioQueueKey) != nil {
            cleanup()
        } else {
            audioQueue.sync(execute: cleanup)
        }
    }

    private func teardownStreamingResources(logHealth: Bool) {
        isStreaming = false

        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)

        if logHealth {
            print("🛑 Streaming stopped")
        }

        restoreInputSelectionIfNeeded()

        audioEngine = nil
        inputNode = nil
        audioFormat = nil
        audioConverter = nil
        bufferLock.lock()
        audioBufferList.removeAll(keepingCapacity: false)
        bufferLock.unlock()
        onPCM16Frame = nil
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
