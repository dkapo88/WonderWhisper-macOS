import Foundation

/// The user's speaking level for the microphone gate: the 80th percentile of the last 3,000
/// speech-like frames (about 30 s of sound clearly above the room noise), kept as a 1 dB
/// histogram. A percentile over many frames cannot be pinned by one loud bump, recovers on
/// its own when the user speaks more quietly, and quiet voices elsewhere in the room only
/// move it once they make up most of the recent sound.
struct MeetingSpeakingLevelEstimator {
  static let windowFrames = 3_000
  static let learningFrames = 30
  static let percentile = 0.8
  private static let lowestLevel = -100
  private static let binCount = 100

  private var histogram = [Int](repeating: 0, count: binCount)
  private var ring = [UInt8](repeating: 0, count: windowFrames)
  private var ringStart = 0
  private(set) var count = 0
  private(set) var level: Float?

  var isLearned: Bool { count >= Self.learningFrames }

  mutating func add(_ frameLevel: Float) {
    let bin = UInt8(
      min(max(Int(frameLevel.rounded(.down)) - Self.lowestLevel, 0), Self.binCount - 1)
    )
    if count == Self.windowFrames {
      histogram[Int(ring[ringStart])] -= 1
      ring[ringStart] = bin
      ringStart = (ringStart + 1) % Self.windowFrames
    } else {
      ring[(ringStart + count) % Self.windowFrames] = bin
      count += 1
    }
    histogram[Int(bin)] += 1
    level = percentileLevel()
  }

  private func percentileLevel() -> Float {
    let target = max(1, Int((Double(count) * Self.percentile).rounded(.up)))
    var seen = 0
    for (bin, binCount) in histogram.enumerated() {
      seen += binCount
      if seen >= target {
        return Float(bin + Self.lowestLevel) + 0.5
      }
    }
    return Float(Self.binCount - 1 + Self.lowestLevel) + 0.5
  }
}
