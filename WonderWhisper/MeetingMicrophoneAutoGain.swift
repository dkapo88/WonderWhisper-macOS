import Foundation

/// Brings a quiet meeting microphone up to a level the transcriber can hear. A built-in laptop
/// microphone at half input volume gives speech around -40 dBFS, and Grok returns no words at
/// all for that; the same audio 26 dB louder is transcribed in full.
///
/// Learns the user's speaking level (`MeetingSpeakingLevelEstimator`, from speech-like 10 ms
/// frames: well above the quietest frame of the last half second, as syllables are and steady
/// noise is not) and applies the gain that puts it at `targetLevel`, at most `maximumGain` and
/// never below 0 dB, so a loud microphone is left as it is. Until the level is learned the
/// loudest speech-like frame so far sets the gain. The gain drops at once and rises slowly, and
/// a soft limiter keeps boosted peaks from clipping.
struct MeetingMicrophoneAutoGain {
  /// Where the user's speaking level is put (dBFS of a 10 ms frame, 80th percentile).
  static let targetLevel: Float = -16
  static let maximumGain: Float = 30
  /// How far the loudest frame sits above the speaking level, for the gain before it is learned.
  static let loudestAboveLevel: Float = 8
  /// dB per 10 ms frame the gain may rise (10 dB a second).
  static let riseStep: Float = 0.1
  static let speechModulation: Float = 12
  static let quietestWindowFrames = 50
  static let lowestSpeechLevel: Float = -80
  static let limiterKnee: Float = 0.5

  private var estimator = MeetingSpeakingLevelEstimator(memory: 20, largeDrop: 20, largeDropFrames: 0)
  private var recentLevels: [Float] = []
  private var loudestSpeech: Float?
  /// The gain now applied, in dB; nil until speech has been heard.
  private(set) var gain: Float?

  /// Returns `samples` (starting at `startTime`) with the gain applied, frame by frame.
  mutating func process(_ samples: [Float], startTime: TimeInterval) -> [Float] {
    var result = samples
    let frame = MeetingMicrophoneGate.frameSampleCount
    for offset in stride(from: 0, to: samples.count, by: frame) {
      let end = min(offset + frame, samples.count)
      let time = startTime + Double(offset) / Double(MeetingMicrophoneGate.sampleRate)
      let previous = gain ?? 0
      let next = nextGain(for: samples[offset..<end], at: time)
      apply(from: previous, to: next, to: &result, range: offset..<end)
    }
    return result
  }

  private mutating func nextGain(for frame: ArraySlice<Float>, at time: TimeInterval) -> Float {
    // Exact silence (muted, or a microphone that has not started) teaches nothing: as the
    // quietest frame it would make room noise look like speech.
    guard frame.contains(where: { $0 != 0 }) else { return gain ?? 0 }
    let level = Self.level(of: frame)
    recentLevels.append(level)
    if recentLevels.count > Self.quietestWindowFrames { recentLevels.removeFirst() }
    let quietest = recentLevels.min() ?? level
    if level >= Self.lowestSpeechLevel, level >= quietest + Self.speechModulation {
      estimator.add(level, at: time)
      loudestSpeech = max(loudestSpeech ?? level, level)
    }
    guard let speakingLevel = estimator.level
      ?? loudestSpeech.map({ $0 - Self.loudestAboveLevel }) else { return gain ?? 0 }
    let wanted = min(Self.maximumGain, max(0, Self.targetLevel - speakingLevel))
    guard let current = gain else {
      gain = wanted
      return wanted
    }
    let updated = wanted < current ? wanted : min(wanted, current + Self.riseStep)
    gain = updated
    return updated
  }

  /// Ramps from the previous frame's gain to this one's across the frame, so a change does not
  /// click; boosted samples go through the limiter.
  private func apply(from previous: Float, to next: Float, to samples: inout [Float], range: Range<Int>) {
    guard previous > 0 || next > 0 else { return }
    let count = Float(max(1, range.count))
    for (step, index) in range.enumerated() {
      let decibels = previous + (next - previous) * Float(step + 1) / count
      guard decibels > 0 else { continue }
      samples[index] = Self.limit(samples[index] * pow(10, decibels / 20))
    }
  }

  /// Leaves samples under the knee alone and bends louder ones smoothly under full scale.
  static func limit(_ sample: Float) -> Float {
    let magnitude = abs(sample)
    guard magnitude > limiterKnee else { return sample }
    let room = 1 - limiterKnee
    let bent = limiterKnee + room * tanh((magnitude - limiterKnee) / room)
    return sample < 0 ? -bent : bent
  }

  private static func level(of frame: ArraySlice<Float>) -> Float {
    guard !frame.isEmpty else { return -120 }
    let mean = frame.reduce(0, +) / Float(frame.count)
    var power: Float = 0
    for sample in frame {
      let value = sample.isFinite ? sample - mean : 0
      power += value * value
    }
    return MeetingMicrophoneGate.decibels(power / Float(frame.count))
  }
}
