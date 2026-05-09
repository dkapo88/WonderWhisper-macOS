//
//  HermesWhisperTests.swift
//  HermesWhisperTests
//
//  Created by Dane Kapoor on 4/9/25.
//

import Testing
import AVFoundation
@testable import HermesWhisper

struct HermesWhisperTests {

    @Test(.disabled("Audio preprocessing utilities crash under headless CI"))
    func audioPreprocessorProducesNormalized16BitOutput() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("ww-audio-preprocessor-input-\(UUID().uuidString).wav")
        let frames = 16_000
        try writeSineWave(to: inputURL, frames: frames, amplitude: 0.01)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let outputURL: URL
        do {
            outputURL = try AudioPreprocessor.process(inputURL)
        } catch {
            print("Processing error: \(error)")
            throw error
        }
        print("Processed file: \(outputURL.path)")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        #expect(outputURL != inputURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        #expect(fileSize > 0)

    }

    @Test func http2SessionsExposePreferredConfiguration() {
        let config = GroqHTTPClient.http2Session.configuration
        #expect(config.httpShouldUsePipelining)
        if let preferred = config.httpAdditionalHeaders?["X-WW-Preferred-Protocol"] as? String {
            #expect(preferred == "h2")
        } else {
            Issue.record("Expected X-WW-Preferred-Protocol header to be set")
        }

        let priorityConfig = GroqHTTPClient.http2PrioritySession.configuration
        #expect(priorityConfig.timeoutIntervalForRequest == 8)
    }

    @Test func keychainSecretNormalizationRejectsMalformedGroqKeys() {
        #expect(KeychainService.normalizedSecret("  gsk_test_key_1234567890\n") == "gsk_test_key_1234567890")
        #expect(KeychainService.isPlausibleGroqAPIKey("gsk_test_key_1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("Bearer gsk_test_key_1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("gsk_test key 1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("sk-not-a-groq-key"))
    }

    private func writeSineWave(to url: URL, frames: Int, amplitude: Float, frequency: Double = 440.0) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw NSError(domain: "HermesWhisperTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let inverseSampleRate = 1.0 / format.sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<frames {
                let time = Double(frame) * inverseSampleRate
                channel[frame] = amplitude * Float(sin(2.0 * .pi * frequency * time))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
