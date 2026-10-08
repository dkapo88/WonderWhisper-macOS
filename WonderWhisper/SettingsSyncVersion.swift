import Foundation

/// The identity of one genuine edit: an ordering epoch, a Lamport counter, and the device that
/// made the edit.
///
/// Invariant: a version is created only when a Mac observes a genuine local edit (or carries
/// out an explicit choice: first enable, Repair, Reset Sync Ordering) and is never changed
/// afterwards. Everything received, merged, agreed, persisted or re-uploaded keeps its original
/// version, so a Mac that merely relays another Mac's value can never make it look newer.
///
/// The epoch is normally 0. "Reset Sync Ordering" (the recovery when counters reach
/// `SettingsSyncDocument.maxCounter`) starts a new epoch, which orders above everything before.
struct SettingsSyncVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
  var epoch: Int64 = 0
  var counter: Int64
  var writer: String

  init(_ counter: Int64, _ writer: String, epoch: Int64 = 0) {
    self.epoch = epoch
    self.counter = counter
    self.writer = writer
  }

  private enum CodingKeys: String, CodingKey {
    case epoch
    case counter
    case writer
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    epoch = try container.decodeIfPresent(Int64.self, forKey: .epoch) ?? 0
    counter = try container.decode(Int64.self, forKey: .counter)
    writer = try container.decode(String.self, forKey: .writer)
  }

  /// Epoch first, then counter; equal counters (concurrent edits) are ordered by writer ID,
  /// the same way on every Mac.
  static func < (lhs: SettingsSyncVersion, rhs: SettingsSyncVersion) -> Bool {
    if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.writer < rhs.writer
  }

  /// The next version this Mac may create after `self`, or nil when the counter would pass
  /// `SettingsSyncDocument.maxCounter` (versions are never reused; the user must reset).
  func successor(writer: String) -> SettingsSyncVersion? {
    guard counter < SettingsSyncDocument.maxCounter else { return nil }
    return SettingsSyncVersion(counter + 1, writer, epoch: epoch)
  }

  var description: String {
    epoch == 0 ? "(\(counter),\(writer))" : "(e\(epoch):\(counter),\(writer))"
  }
}
