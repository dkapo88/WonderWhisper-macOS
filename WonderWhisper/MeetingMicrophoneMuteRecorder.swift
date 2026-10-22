import Foundation

/// Remembers when the user muted the meeting microphone, on the meeting's timeline. Capture
/// marks each microphone chunk as it arrives, so the live gate and later recovery from the
/// saved audio silence exactly the same stretches.
final class MeetingMicrophoneMuteRecorder: @unchecked Sendable {
  /// Chunks closer than this join one range.
  static let joinTolerance: TimeInterval = 0.15

  private let lock = NSLock()
  private var muted = false
  private var recordedRanges: [MeetingTimeRange]

  init(ranges: [MeetingTimeRange] = []) {
    recordedRanges = ranges
  }

  var isMuted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return muted
  }

  func setMuted(_ muted: Bool) {
    lock.lock()
    defer { lock.unlock() }
    self.muted = muted
  }

  var ranges: [MeetingTimeRange] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRanges
  }

  /// Notes a microphone chunk as captured (timeline times). Returns whether it is muted.
  @discardableResult
  func observe(start: TimeInterval, end: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard muted, end > start else { return muted }
    if let last = recordedRanges.last,
       start <= last.end + Self.joinTolerance,
       start >= last.start {
      recordedRanges[recordedRanges.count - 1].end = max(last.end, end)
    } else {
      recordedRanges.append(MeetingTimeRange(start: start, end: end))
    }
    return true
  }

  /// Whether a chunk at these timeline times was captured while muted.
  func covers(start: TimeInterval, end: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return recordedRanges.covers(start: start, end: end)
  }
}
