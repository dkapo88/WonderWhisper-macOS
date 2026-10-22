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
  /// Whether the middle of `start..<end` falls inside one of the ranges.
  func covers(start: TimeInterval, end: TimeInterval) -> Bool {
    let middle = (start + end) / 2
    return contains { $0.contains(middle) }
  }
}
