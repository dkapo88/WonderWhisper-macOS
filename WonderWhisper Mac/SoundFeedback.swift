import Foundation
import AVFoundation

/// Generates simple, clean two-tone audio feedback for recording start/stop
final class SoundFeedback {
  private static let sampleRate: Double = 44100
  private static let toneDuration: Double = 0.06  // 60ms per tone - short and crisp
  private static let toneGap: Double = 0.01       // 10ms gap between tones
  
  // Frequencies for the two tones
  private static let lowFreq: Double = 600   // Low tone (E5)
  private static let highFreq: Double = 800  // High tone (G#5)
  
  /// Play start sound: low → high (ascending)
  static func playStart() {
    playTwoTone(firstFreq: lowFreq, secondFreq: highFreq, volume: 0.15)
  }
  
  /// Play stop sound: high → low (descending)
  static func playStop() {
    playTwoTone(firstFreq: highFreq, secondFreq: lowFreq, volume: 0.25)
  }
  
  private static func playTwoTone(firstFreq: Double, secondFreq: Double, volume: Float) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let buffer = generateTwoToneBuffer(firstFreq: firstFreq, secondFreq: secondFreq) else { return }
      
      let player = AVAudioPlayerNode()
      let engine = AVAudioEngine()
      
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      
      do {
        try engine.start()
        player.volume = volume
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

