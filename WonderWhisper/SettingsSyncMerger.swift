import Foundation

/// Pure per-key last-writer-wins merge between this Mac and the cloud document.
enum SettingsSyncMerger {

  /// This Mac's view of one setting: its current value and when it last changed.
  struct LocalEntry: Equatable, Sendable {
    var value: SettingsSyncValue?
    var modifiedAt: Date
  }

  struct Result: Equatable, Sendable {
    /// Cloud values that are newer than this Mac's; nil means remove the local key.
    var applyLocally: [String: SettingsSyncValue?] = [:]
    /// The document to store in iCloud after the merge.
    var document: SettingsSyncDocument
    /// True when `document` differs from what is in iCloud and must be written.
    var documentChanged = false
    /// Per key: the value fingerprint and timestamp this Mac now agrees with.
    var agreed: [String: SettingsSyncLocalRecord] = [:]
  }

  /// - Parameter authoritative: "Replace iCloud with this Mac's settings". Every local value
  ///   (including absent ones, as resets) wins regardless of timestamps, and is stamped just
  ///   after the cloud entry it replaces so every other Mac also treats it as newest.
  static func merge(
    local: [String: LocalEntry],
    remote: SettingsSyncDocument?,
    deviceID: String,
    authoritative: Bool = false
  ) -> Result {
    var result = Result(document: remote ?? SettingsSyncDocument())
    if remote == nil { result.documentChanged = true }

    for key in local.keys.sorted() {
      guard var mine = local[key] else { continue }
      let myFingerprint = SettingsSyncValue.fingerprint(of: mine.value)

      guard let theirs = result.document.entries[key] else {
        // Never seen in the cloud. Absent locally too means nothing to record.
        guard mine.value != nil else { continue }
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
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

      if authoritative {
        let justAfter = SettingsSyncDocument.date(
          millis: SettingsSyncDocument.millis(theirs.modifiedAt) + 1
        )
        mine.modifiedAt = max(mine.modifiedAt, justAfter)
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
      } else if isNewer(mine.modifiedAt, deviceID, than: theirs.modifiedAt, theirs.deviceID) {
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
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

  /// Folds competing whole-file versions (iCloud conflict versions) into one document,
  /// keeping the newest entry per key and every device. Unknown keys are kept.
  static func combine(_ base: SettingsSyncDocument, _ other: SettingsSyncDocument)
    -> SettingsSyncDocument {
    var merged = base
    merged.schemaVersion = max(base.schemaVersion, other.schemaVersion)
    for (key, entry) in other.entries {
      if let existing = merged.entries[key],
         !isNewer(entry.modifiedAt, entry.deviceID, than: existing.modifiedAt, existing.deviceID) {
        continue
      }
      merged.entries[key] = entry
    }
    for (id, device) in other.devices {
      if let existing = merged.devices[id], existing.lastWriteAt >= device.lastWriteAt { continue }
      merged.devices[id] = device
    }
    return merged
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

  private static func upload(
    _ entry: LocalEntry,
    key: String,
    fingerprint: String?,
    deviceID: String,
    into result: inout Result
  ) {
    result.document.entries[key] = SettingsSyncDocument.Entry(
      value: entry.value,
      modifiedAt: entry.modifiedAt,
      deviceID: deviceID
    )
    result.documentChanged = true
    result.agreed[key] = SettingsSyncLocalRecord(
      fingerprint: fingerprint,
      modifiedAt: entry.modifiedAt
    )
  }
}

/// What this Mac last agreed with the cloud for one key: used to spot local edits between syncs.
struct SettingsSyncLocalRecord: Codable, Equatable, Sendable {
  /// Fingerprint of the value, nil when the key was absent.
  var fingerprint: String?
  var modifiedAt: Date
}
