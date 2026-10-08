import Foundation

/// Pure per-key last-writer-wins merge between this Mac and the cloud document, ordered by
/// Lamport counter (then device ID). Wall-clock time plays no part.
enum SettingsSyncMerger {
  /// Counter for a local "no opinion": the key was absent here and this Mac never agreed on a
  /// value for it, so anything in the cloud beats it and nothing is uploaded for it.
  static let noOpinion: Int64 = -1

  /// This Mac's view of one setting: its current value and the counter of its last change.
  struct LocalEntry: Equatable, Sendable {
    var value: SettingsSyncValue?
    var counter: Int64
  }

  struct Result: Equatable, Sendable {
    /// Cloud values that are newer than this Mac's; nil means remove the local key.
    var applyLocally: [String: SettingsSyncValue?] = [:]
    /// The document to store in iCloud after the merge.
    var document: SettingsSyncDocument
    /// True when `document` differs from what is in iCloud and must be written.
    var documentChanged = false
    /// Per key: the value fingerprint and counter this Mac now agrees with.
    var agreed: [String: SettingsSyncLocalRecord] = [:]
  }

  /// - Parameter authoritative: "Replace iCloud with this Mac's settings". Every local value,
  ///   including an absent one (written as a reset), wins regardless of counters and is stamped
  ///   one past the cloud entry it replaces, so every other Mac also treats it as newest.
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
        mine.counter = max(mine.counter, 0)
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
        continue
      }

      let theirFingerprint = SettingsSyncValue.fingerprint(of: theirs.value)
      if myFingerprint == theirFingerprint {
        // Same value on both sides: nothing to write, nothing to apply.
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: theirFingerprint,
          counter: theirs.counter
        )
        continue
      }

      if authoritative {
        mine.counter = max(mine.counter, theirs.counter + 1)
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
      } else if isNewer(mine.counter, deviceID, than: theirs.counter, theirs.deviceID) {
        upload(mine, key: key, fingerprint: myFingerprint, deviceID: deviceID, into: &result)
      } else {
        result.applyLocally[key] = .some(theirs.value)
        result.agreed[key] = SettingsSyncLocalRecord(
          fingerprint: theirFingerprint,
          counter: theirs.counter
        )
      }
    }
    return result
  }

  /// Folds competing whole-file versions (iCloud conflict versions) into one document,
  /// keeping the newest entry per key and the latest record of every device. Unknown keys
  /// are kept.
  static func combine(_ base: SettingsSyncDocument, _ other: SettingsSyncDocument)
    -> SettingsSyncDocument {
    var merged = base
    merged.schemaVersion = max(base.schemaVersion, other.schemaVersion)
    for (key, entry) in other.entries {
      if let existing = merged.entries[key], !entry.isNewer(than: existing) { continue }
      merged.entries[key] = entry
    }
    for (id, device) in other.devices {
      if let existing = merged.devices[id], existing.lastWriteAt >= device.lastWriteAt { continue }
      merged.devices[id] = device
    }
    return merged
  }

  /// Higher counter wins; an exact tie is broken by device ID so every Mac picks the same side.
  static func isNewer(
    _ lhsCounter: Int64,
    _ lhsDevice: String,
    than rhsCounter: Int64,
    _ rhsDevice: String
  ) -> Bool {
    if lhsCounter != rhsCounter { return lhsCounter > rhsCounter }
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
      counter: entry.counter,
      deviceID: deviceID
    )
    result.documentChanged = true
    result.agreed[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, counter: entry.counter)
  }
}

/// What this Mac last agreed with the cloud for one key: used to spot local edits between syncs.
struct SettingsSyncLocalRecord: Codable, Equatable, Sendable {
  /// Fingerprint of the value, nil when the key was absent.
  var fingerprint: String?
  /// Lamport counter of that agreed value (or of a pending local edit).
  var counter: Int64
}
