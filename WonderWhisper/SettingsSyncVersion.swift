import Foundation

/// The identity of one genuine edit: a Lamport counter and the device that made the edit.
///
/// Invariant: a version is created only when a Mac observes a genuine local edit (or carries
/// out an explicit first-enable choice), and is never changed afterwards. Everything received,
/// merged, agreed, persisted or re-uploaded keeps its original version, so a Mac that merely
/// relays another Mac's value can never make it look newer than it is.
struct SettingsSyncVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
  var counter: Int64
  var writer: String

  init(_ counter: Int64, _ writer: String) {
    self.counter = counter
    self.writer = writer
  }

  /// Higher counter wins; equal counters (concurrent edits) are ordered by writer ID, the same
  /// way on every Mac.
  static func < (lhs: SettingsSyncVersion, rhs: SettingsSyncVersion) -> Bool {
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.writer < rhs.writer
  }

  var description: String { "(\(counter),\(writer))" }
}
