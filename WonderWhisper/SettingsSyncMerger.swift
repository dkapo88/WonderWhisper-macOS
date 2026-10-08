import Foundation

/// Pure per-key last-writer-wins merge between this Mac and the cloud document.
enum SettingsSyncMerger {
  /// This Mac's view of one setting: its current value and when it last changed.
  struct LocalEntry: Equatable {
    var value: SettingsSyncValue?
    var modifiedAt: Date
  }

  struct Result: Equatable {
    /// Cloud values that are newer than this Mac's; nil means remove the local key.
    var applyLocally: [String: SettingsSyncValue?] = [:]
    /// The document to store in iCloud after the merge.
    var document: SettingsSyncDocument
    /// True when `document` differs from what is in iCloud and must be written.
    var documentChanged = false
    /// Per key: the value fingerprint and timestamp this Mac now agrees with.
    var agreed: [String: SettingsSyncLocalRecord] = [:]
  }

  static func merge(
    local: [String: LocalEntry],
    remote: SettingsSyncDocument?,
    deviceID: String
  ) -> Result {
    var result = Result(document: remote ?? SettingsSyncDocument())
    if remote == nil { result.documentChanged = true }

    for key in local.keys.sorted() {
      guard let mine = local[key] else { continue }
      let myFingerprint = SettingsSyncValue.fingerprint(of: mine.value)

      guard let theirs = result.document.entries[key] else {
        // Never seen in the cloud. Absent locally too means nothing to record.
        guard mine.value != nil else { continue }
        result.document.entries[key] = SettingsSyncDocument.Entry(
          value: mine.value,
          modifiedAt: mine.modifiedAt,
          deviceID: deviceID
        )
        result.documentChanged = true
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: myFingerprint,
          modifiedAt: mine.modifiedAt
        )
        continue
      }

      let theirFingerprint = SettingsSyncValue.fingerprint(of: theirs.value)
      if myFingerprint == theirFingerprint {
        // Same value on both sides: nothing to write, nothing to apply.
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: theirFingerprint,
          modifiedAt: theirs.modifiedAt
        )
        continue
      }

      if isNewer(mine.modifiedAt, deviceID, than: theirs.modifiedAt, theirs.deviceID) {
        result.document.entries[key] = SettingsSyncDocument.Entry(
          value: mine.value,
          modifiedAt: mine.modifiedAt,
          deviceID: deviceID
        )
        result.documentChanged = true
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: myFingerprint,
          modifiedAt: mine.modifiedAt
        )
      } else {
        result.applyLocally[key] = .some(theirs.value)
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: theirFingerprint,
          modifiedAt: theirs.modifiedAt
        )
      }
    }
    return result
  }

  /// Later timestamp wins; an exact tie is broken by device ID so every Mac picks the same side.
  static func isNewer(
    _ lhsDate: Date,
    _ lhsDevice: String,
    than rhsDate: Date,
    _ rhsDevice: String
  ) -> Bool {
    if lhsDate != rhsDate { return lhsDate > rhsDate }
    return lhsDevice > rhsDevice
  }
}

/// What this Mac last agreed with the cloud for one key: used to spot local edits between syncs.
struct SettingsSyncLocalRecord: Codable, Equatable {
  /// Fingerprint of the value, nil when the key was absent.
  var fingerprint: String?
  var modifiedAt: Date
}
