import Foundation
import AVFoundation

/// Generates simple, clean two-tone audio feedback for recording start/stop
final class SoundFeedback {
  private static let sampleRate: Double = 44100
  private static let toneDuration: Double = 0.06  // 60ms per tone - short and crisp
  private static let toneGap: Double = 0.01       // 10ms gap between tones
  private static let startBaseVolume: Float = 0.15
  private static let stopBaseVolume: Float = 0.25
  private static let chimeVolumeKey = "audio.chime.volume"
  private static var volumeScale: Float = {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: chimeVolumeKey) == nil { return 1.0 }
    let stored = defaults.double(forKey: chimeVolumeKey)
    return clampScale(Float(stored))
  }()
  
  // Frequencies for the two tones
  private static let lowFreq: Double = 600   // Low tone (E5)
  private static let highFreq: Double = 800  // High tone (G#5)
  
  /// Play start sound: low → high (ascending)
  static func playStart() {
    playTwoTone(firstFreq: lowFreq, secondFreq: highFreq, volume: effectiveVolume(for: startBaseVolume))
  }

  /// Play stop sound: high → low (descending)
  static func playStop() {
    playTwoTone(firstFreq: highFreq, secondFreq: lowFreq, volume: effectiveVolume(for: stopBaseVolume))
  }

  private static func playTwoTone(firstFreq: Double, secondFreq: Double, volume: Float) {
    let adjustedVolume = max(0, min(1, volume))
    guard adjustedVolume > 0.0001 else { return }

    DispatchQueue.global(qos: .userInitiated).async {
      guard let buffer = generateTwoToneBuffer(firstFreq: firstFreq, secondFreq: secondFreq) else { return }

      let player = AVAudioPlayerNode()
      let engine = AVAudioEngine()

      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      // Explicitly connect mainMixerNode to output to ensure audio is routed to speakers
      engine.connect(engine.mainMixerNode, to: engine.outputNode, format: buffer.format)

      do {
        try engine.start()
        player.volume = adjustedVolume
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()

        // Keep engine alive for the duration of playback
        let totalDuration = toneDuration * 2 + toneGap + 0.05
        Thread.sleep(forTimeInterval: totalDuration)

        player.stop()
        engine.stop()
      } catch {
        // Silent failure - audio feedback is non-critical
      }
    }
  }

  private static func effectiveVolume(for baseVolume: Float) -> Float {
    return baseVolume * volumeScale
  }

  static func setVolumeScale(_ scale: Double) {
    let clamped = clampScale(Float(scale))
    volumeScale = clamped
    UserDefaults.standard.set(Double(clamped), forKey: chimeVolumeKey)
  }

  static func currentVolumeScale() -> Double {
    Double(volumeScale)
  }

  @inline(__always)
  private static func clampScale(_ value: Float) -> Float {
    Float(max(0.0, min(1.0, value)))
  }
  
  private static func generateTwoToneBuffer(firstFreq: Double, secondFreq: Double) -> AVAudioPCMBuffer? {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    guard let format = format else { return nil }
    
    let totalSamples = Int((toneDuration * 2 + toneGap) * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else {
      return nil
    }
    buffer.frameLength = buffer.frameCapacity
    
    guard let samples = buffer.floatChannelData?[0] else { return nil }
    
    let tone1Samples = Int(toneDuration * sampleRate)
    let gapSamples = Int(toneGap * sampleRate)
    let tone2Samples = Int(toneDuration * sampleRate)
    
    var sampleIndex = 0
    
    // First tone with fade in/out envelope
    for i in 0..<tone1Samples {
      let t = Double(i) / sampleRate
      let envelope = envelopeFactor(sample: i, totalSamples: tone1Samples)
      let value = sin(2.0 * .pi * firstFreq * t) * envelope
      samples[sampleIndex] = Float(value)
      sampleIndex += 1
    }
    
    // Gap (silence)
    for _ in 0..<gapSamples {
      samples[sampleIndex] = 0
      sampleIndex += 1
    }
    
    // Second tone with fade in/out envelope
    for i in 0..<tone2Samples {
      let t = Double(i) / sampleRate
      let envelope = envelopeFactor(sample: i, totalSamples: tone2Samples)
      let value = sin(2.0 * .pi * secondFreq * t) * envelope
      samples[sampleIndex] = Float(value)
      sampleIndex += 1
    }
    
    return buffer
  }
  
  /// Simple fade in/out envelope to avoid clicks and make sound smooth
  private static func envelopeFactor(sample: Int, totalSamples: Int) -> Double {
    let fadeLength = min(totalSamples / 8, Int(0.005 * sampleRate)) // 5ms fade or 1/8 of tone
    
    if sample < fadeLength {
      // Fade in
      return Double(sample) / Double(fadeLength)
    } else if sample > totalSamples - fadeLength {
      // Fade out
      return Double(totalSamples - sample) / Double(fadeLength)
    } else {
      // Full volume
      return 1.0
    }
  }
}
