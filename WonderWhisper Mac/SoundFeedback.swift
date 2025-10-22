import Foundation
import AVFoundation
import OSLog

/// Generates simple, clean two-tone audio feedback for recording start/stop
final class SoundFeedback {
  private static let sampleRate: Double = 44100
  private static let toneDuration: Double = 0.06  // 60ms per tone - short and crisp
  private static let toneGap: Double = 0.01       // 10ms gap between tones
  private static let startBaseVolume: Float = 0.4  // Increased from 0.15 for better audibility
  private static let stopBaseVolume: Float = 0.5   // Increased from 0.25 for better audibility
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
    let vol = effectiveVolume(for: startBaseVolume)
    AppLog.dictation.debug("Playing start chime: baseVolume=\(startBaseVolume), volumeScale=\(volumeScale), effectiveVolume=\(vol)")
    playTwoTone(firstFreq: lowFreq, secondFreq: highFreq, volume: vol)
  }

  /// Play stop sound: high → low (descending)
  static func playStop() {
    let vol = effectiveVolume(for: stopBaseVolume)
    AppLog.dictation.debug("Playing stop chime: baseVolume=\(stopBaseVolume), volumeScale=\(volumeScale), effectiveVolume=\(vol)")
    playTwoTone(firstFreq: highFreq, secondFreq: lowFreq, volume: vol)
  }

  private static func playTwoTone(firstFreq: Double, secondFreq: Double, volume: Float) {
    let adjustedVolume = max(0, min(1, volume))
    AppLog.dictation.log("Chime: adjustedVolume=\(adjustedVolume)")
    
    guard adjustedVolume > 0.0001 else {
      AppLog.dictation.error("Chime: Volume too low (adjustedVolume=\(adjustedVolume)), aborting")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      AppLog.dictation.log("Chime: Starting async audio generation")
      
      guard let buffer = generateTwoToneBuffer(firstFreq: firstFreq, secondFreq: secondFreq, volume: adjustedVolume) else {
        AppLog.dictation.error("Chime: Failed to generate audio buffer")
        return
      }
      
      AppLog.dictation.log("Chime: Buffer generated successfully, samples=\(buffer.frameLength)")

      let player = AVAudioPlayerNode()
      let engine = AVAudioEngine()

      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      // Explicitly connect mainMixerNode to output to ensure audio is routed to speakers
      engine.connect(engine.mainMixerNode, to: engine.outputNode, format: buffer.format)

      do {
        AppLog.dictation.log("Chime: Starting audio engine")
        try engine.start()
        AppLog.dictation.log("Chime: Engine started, playing at volume \(adjustedVolume)")
        // Set player volume to 1.0 since volume is already embedded in the buffer
        player.volume = 1.0
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
        AppLog.dictation.log("Chime: Player started")

        // Keep engine alive for the duration of playback
        let totalDuration = toneDuration * 2 + toneGap + 0.05
        Thread.sleep(forTimeInterval: totalDuration)

        player.stop()
        engine.stop()
        AppLog.dictation.log("Chime: Playback completed successfully")
      } catch {
        // Log audio engine errors for debugging
        AppLog.dictation.error("Chime audio playback failed: \(error.localizedDescription)")
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
  
  private static func generateTwoToneBuffer(firstFreq: Double, secondFreq: Double, volume: Float) -> AVAudioPCMBuffer? {
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
    
    // First tone with fade in/out envelope and volume scaling
    for i in 0..<tone1Samples {
      let t = Double(i) / sampleRate
      let envelope = envelopeFactor(sample: i, totalSamples: tone1Samples)
      let value = sin(2.0 * .pi * firstFreq * t) * envelope * Double(volume)
      samples[sampleIndex] = Float(value)
      sampleIndex += 1
    }
    
    // Gap (silence)
    for _ in 0..<gapSamples {
      samples[sampleIndex] = 0
      sampleIndex += 1
    }
    
    // Second tone with fade in/out envelope and volume scaling
    for i in 0..<tone2Samples {
      let t = Double(i) / sampleRate
      let envelope = envelopeFactor(sample: i, totalSamples: tone2Samples)
      let value = sin(2.0 * .pi * secondFreq * t) * envelope * Double(volume)
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
