import Foundation
import AVFoundation

/// Trailing silence for dictation audio sent to Parakeet (Unified and Ultra).
///
/// At 16 kHz the model gets `max(n, 24_000) + 6_400` samples: at least 1.5 s of input plus
/// 400 ms of trailing zeros, so a very short or abruptly ended utterance still decodes its last
/// word. FluidAudio pads each window to the model's shape but passes the true sample count on as
/// the valid length, so this padding has to be real audio. The saved recording is not changed.
enum ParakeetInputPadding {
  static let modelSampleRate = 16_000.0
  static let minimumSamples = 24_000
  static let trailingSilenceSamples = 6_400

  /// Padded length at 16 kHz.
  static func paddedSampleCount(forModelSamples samples: Int) -> Int {
    max(samples, minimumSamples) + trailingSilenceSamples
  }

  /// Padded length in frames at `sampleRate`, equivalent to `paddedSampleCount` at 16 kHz.
  static func paddedFrameCount(forFrames frames: Int, sampleRate: Double) -> Int {
    guard sampleRate > 0 else { return frames }
    if sampleRate == modelSampleRate { return paddedSampleCount(forModelSamples: frames) }
    let modelSamples = Int((Double(frames) * modelSampleRate / sampleRate).rounded(.up))
    let padded = paddedSampleCount(forModelSamples: modelSamples)
    return max(frames, Int((Double(padded) * sampleRate / modelSampleRate).rounded(.up)))
  }

  /// Reads `url` into a buffer in its processing format and appends zeros up to the padded
  /// length. Nil for an empty file.
  static func paddedBuffer(contentsOf url: URL) throws -> AVAudioPCMBuffer? {
    let file = try AVAudioFile(forReading: url)
    let frames = Int(file.length)
    guard frames > 0 else { return nil }
    let format = file.processingFormat
    let padded = paddedFrameCount(forFrames: frames, sampleRate: format.sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded)) else {
      return nil
    }
    try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
    let read = Int(buffer.frameLength)
    guard let channels = buffer.floatChannelData else { return buffer }
    for channel in 0..<Int(format.channelCount) {
      let pointer = channels[channel]
      for index in read..<padded { pointer[index] = 0 }
    }
    buffer.frameLength = AVAudioFrameCount(padded)
    return buffer
  }
}
