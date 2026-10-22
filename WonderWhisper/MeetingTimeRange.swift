import Foundation

/// A span on a meeting's timeline, in seconds from the start of the recording.
struct MeetingTimeRange: Codable, Equatable, Sendable {
  var start: TimeInterval
  var end: TimeInterval

  func contains(_ time: TimeInterval) -> Bool {
    time >= start && time < end
  }
}

extension Array where Element == MeetingTimeRange {
  /// The ranges cut off at `time` (ranges starting after it dropped), for a resumed meeting
  /// whose earlier run ended there, possibly mid-mute after a crash.
  func ending(by time: TimeInterval) -> [MeetingTimeRange] {
    compactMap { range in
      guard range.start < time else { return nil }
      return MeetingTimeRange(start: range.start, end: Swift.min(range.end, time))
    }
  }

  /// Whether the middle of `start..<end` falls inside one of the ranges.
  func covers(start: TimeInterval, end: TimeInterval) -> Bool {
    let middle = (start + end) / 2
    return contains { $0.contains(middle) }
  }
}
