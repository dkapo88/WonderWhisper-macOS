import Foundation

/// Remembers when the user muted the meeting microphone, on the meeting's timeline. Capture
/// marks each microphone chunk as it arrives, so the live gate and later recovery from the
/// saved audio silence exactly the same stretches.
final class MeetingMicrophoneMuteRecorder: @unchecked Sendable {
  /// The end saved for a mute that is still on, so a crash mid-mute keeps the rest of that
  /// recording muted (JSON cannot hold infinity). Clamped to the run's end on resume.
  static let openEnd: TimeInterval = 1_000_000_000

  private let lock = NSLock()
  private var muted = false
  private var recordedRanges: [MeetingTimeRange]
  /// Whether the last observed chunk was muted: only consecutive muted chunks join one range.
  private var lastObservationMuted = false
  private var lastObservedEnd: TimeInterval?

  /// `runStart` is where this recording run starts on the meeting timeline (a resume's
  /// offset): a mute pressed before its first chunk starts there, never earlier.
  init(ranges: [MeetingTimeRange] = [], runStart: TimeInterval = 0) {
    recordedRanges = ranges
    self.runStart = runStart
  }

  private let runStart: TimeInterval

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
    guard end > start else { return muted }
    defer {
      lastObservationMuted = muted
      lastObservedEnd = max(lastObservedEnd ?? end, end)
    }
    guard muted else { return false }
    if lastObservationMuted, let last = recordedRanges.last, start >= last.start {
      recordedRanges[recordedRanges.count - 1].end = max(last.end, end)
    } else {
      recordedRanges.append(MeetingTimeRange(start: start, end: end))
    }
    return true
  }

  /// The ranges to save while recording: a mute that is still on runs to `openEnd`, so
  /// recovery after a crash leaves it muted.
  var persistableRanges: [MeetingTimeRange] {
    lock.lock()
    defer { lock.unlock() }
    guard muted else { return recordedRanges }
    var ranges = recordedRanges
    if lastObservationMuted, !ranges.isEmpty {
      ranges[ranges.count - 1].end = Self.openEnd
    } else {
      ranges.append(MeetingTimeRange(start: lastObservedEnd ?? runStart, end: Self.openEnd))
    }
    return ranges
  }

  /// Whether a chunk at these timeline times was captured while muted.
  func covers(start: TimeInterval, end: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return recordedRanges.covers(start: start, end: end)
  }
}
