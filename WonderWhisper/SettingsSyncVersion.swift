import Foundation

/// Immutable identity of a genuine edit or explicit sync choice. Relays keep this version.
struct SettingsSyncVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
  var counter: Int64
  var writer: String

  init(_ counter: Int64, _ writer: String) {
    self.counter = counter
    self.writer = writer
  }

  static func < (lhs: SettingsSyncVersion, rhs: SettingsSyncVersion) -> Bool {
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.writer < rhs.writer
  }

  /// Nil at the ceiling: a version must never be reused.
  func successor(writer: String) -> SettingsSyncVersion? {
    guard counter < SettingsSyncDocument.maxCounter else { return nil }
    return SettingsSyncVersion(counter + 1, writer)
  }

  var description: String { "(\(counter),\(writer))" }
}
