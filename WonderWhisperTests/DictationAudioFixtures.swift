import AVFoundation
import Foundation

/// Synthetic audio for dictation tests (no microphone, no models).
enum DictationAudioFixtures {
  static let sampleRate = 16_000.0

  /// Amplitude whose sine has the given RMS level in dBFS (full scale 1.0).
  static func sineAmplitude(forRMSdBFS level: Double) -> Float {
    Float(pow(10, level / 20) * 2.0.squareRoot())
  }

  static func sine(seconds: Double, rmsDBFS: Double, frequency: Double = 440, offset: Float = 0) -> [Float] {
    let count = Int(seconds * sampleRate)
    let amplitude = sineAmplitude(forRMSdBFS: rmsDBFS)
    return (0..<count).map { index in
      offset + amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
  }

  static func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * sampleRate))
  }

  /// Writes 16-bit mono PCM, like the dictation backup recording.
  @discardableResult
  static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double = sampleRate) throws -> URL {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
          let channel = buffer.floatChannelData?[0] else {
      throw CocoaError(.fileWriteUnknown)
    }
    for (index, sample) in samples.enumerated() { channel[index] = sample }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if !samples.isEmpty { try file.write(from: buffer) }
    return url
  }

  static func temporaryURL(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ww-test-\(name).wav")
  }
}
