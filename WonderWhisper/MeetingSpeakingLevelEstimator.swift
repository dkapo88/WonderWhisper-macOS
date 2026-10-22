import Foundation

/// The user's speaking level for the microphone gate: the 80th percentile of the speech-like
/// frames heard in the last `memory` seconds, kept as a 1 dB histogram. A percentile over many
/// frames cannot be pinned by one loud bump, and because old frames expire the level follows
/// the user down within `memory` seconds when they get quieter (another microphone, gain, or
/// distance). Once learned it is kept through silences: it only changes when there is new
/// speech-like sound to learn from. A level backed by at least a second of speech near it only
/// drops by more than `largeDrop` once `largeDropFrames` frames support the drop, so a short
/// phrase from someone quieter in the room cannot re-teach it after the user has listened in
/// silence for a while; a level set by a brief bump drops straight away.
struct MeetingSpeakingLevelEstimator {
  static let learningFrames = 30
  static let percentile = 0.8
  static let framesPerSecond = 100
  /// Frames within 5 dB of the level that make it established.
  static let establishedSupport = 100
  private static let lowestLevel = -100
  private static let binCount = 100

  let memory: TimeInterval
  let largeDrop: Float
  let largeDropFrames: Int
  private let capacity: Int
  private var histogram = [Int](repeating: 0, count: binCount)
  private var bins: [UInt8]
  private var times: [TimeInterval]
  private var start = 0
  private(set) var count = 0
  private(set) var level: Float?
  private var levelSupport = 0

  init(memory: TimeInterval, largeDrop: Float, largeDropFrames: Int) {
    self.memory = memory
    self.largeDrop = largeDrop
    self.largeDropFrames = largeDropFrames
    capacity = max(Self.learningFrames, Int(memory * Double(Self.framesPerSecond)))
    bins = [UInt8](repeating: 0, count: capacity)
    times = [TimeInterval](repeating: 0, count: capacity)
  }

  var isLearned: Bool { level != nil }

  mutating func add(_ frameLevel: Float, at time: TimeInterval) {
    expire(before: time - memory)
    let bin = UInt8(
      min(max(Int(frameLevel.rounded(.down)) - Self.lowestLevel, 0), Self.binCount - 1)
    )
    if count == capacity {
      histogram[Int(bins[start])] -= 1
      start = (start + 1) % capacity
      count -= 1
    }
    let index = (start + count) % capacity
    bins[index] = bin
    times[index] = time
    count += 1
    histogram[Int(bin)] += 1
    guard count >= Self.learningFrames else { return }
    let candidate = percentileLevel()
    if let level, candidate < level - largeDrop,
       levelSupport >= Self.establishedSupport, count < largeDropFrames {
      return
    }
    level = candidate
    levelSupport = framesNear(candidate)
  }

  /// Forgets everything, for a new stretch of recording that may use another microphone.
  mutating func reset() {
    self = Self(memory: memory, largeDrop: largeDrop, largeDropFrames: largeDropFrames)
  }

  private mutating func expire(before cutoff: TimeInterval) {
    while count > 0, times[start] < cutoff {
      histogram[Int(bins[start])] -= 1
      start = (start + 1) % capacity
      count -= 1
    }
  }

  private func framesNear(_ level: Float) -> Int {
    let center = Int(level.rounded(.down)) - Self.lowestLevel
    let range = max(0, center - 5)...min(Self.binCount - 1, center + 5)
    return histogram[range].reduce(0, +)
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
