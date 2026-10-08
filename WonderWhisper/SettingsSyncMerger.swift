import Foundation

/// Pure per-key merge between one Mac and the cloud document, ordered by version
/// (`SettingsSyncVersion`). Versions are never rewritten: a value is uploaded with the version
/// of the edit that produced it, wherever that edit happened.
enum SettingsSyncMerger {
  enum Mode: Sendable, Equatable {
    /// Ordinary sync: per key, the higher version wins.
    case normal
    /// "Use iCloud": adopt every cloud key (resets included) whatever the versions. Local
    /// values for keys the cloud doesn't have are stamped and uploaded.
    case adopt
    /// "Replace iCloud": stamp this Mac's whole batch, unchanged values and resets included,
    /// above every counter in the file and its conflict versions.
    case replace
  }

  /// This Mac's view of one setting: its current value and the version it carries, or nil
  /// for a value that has never been versioned (a local value that predates sync).
  struct LocalCandidate: Equatable, Sendable {
    var value: SettingsSyncValue?
    var version: SettingsSyncVersion?
  }

  struct Result: Equatable, Sendable {
    /// Cloud values this Mac must take; nil means remove the local key.
    var applyLocally: [String: SettingsSyncValue?] = [:]
    /// The document to store in iCloud after the merge.
    var document: SettingsSyncDocument
    /// True when `document` differs from what is in iCloud and must be written.
    var documentChanged = false
    /// Per key: the value fingerprint and version this Mac now agrees with.
    var agreed: [String: SettingsSyncLocalRecord] = [:]
    /// Versions created by this merge (first-enable batches and never-versioned local values).
    var stamped: [String: SettingsSyncDocument.Entry] = [:]
  }

  /// - Parameters:
  ///   - remote: the cloud document with any incorporated conflict versions already folded in.
  ///   - localCounter: this Mac's counter; new versions are stamped above it and above every
  ///     counter in `remote` and in `local`.
  ///   - lockedKeys: keys whose cloud entry couldn't be decoded. They are neither applied nor
  ///     overwritten.
  static func merge(
    local: [String: LocalCandidate],
    remote: SettingsSyncDocument?,
    deviceID: String,
    localCounter: Int64,
    mode: Mode = .normal,
    lockedKeys: Set<String> = []
  ) -> Result {
    var result = Result(document: remote ?? SettingsSyncDocument())
    if remote == nil { result.documentChanged = true }

    let highest = max(
      localCounter,
      result.document.highestCounter,
      local.values.compactMap(\.version?.counter).max() ?? 0
    )
    let stamp = SettingsSyncVersion(
      min(highest, SettingsSyncDocument.maxCounter - 1) + 1,
      deviceID
    )

    for key in local.keys.sorted() where !lockedKeys.contains(key) {
      guard let mine = local[key] else { continue }
      let theirs = result.document.entries[key]

      switch mode {
      case .replace:
        // Whole batch, including values equal to the cloud's and resets of cloud keys.
        if mine.value == nil, theirs == nil { continue }
        put(key, value: mine.value, version: stamp, stamped: true, into: &result)

      case .adopt, .normal:
        let mineVersion = mode == .adopt ? nil : mine.version
        guard let theirs else {
          if let mineVersion {
            put(key, value: mine.value, version: mineVersion, stamped: false, into: &result)
          } else if mine.value != nil {
            put(key, value: mine.value, version: stamp, stamped: true, into: &result)
          }
          continue
        }
        if let mineVersion, mineVersion > theirs.version {
          // Ours is the newer edit (equal values included: keep the higher version).
          put(key, value: mine.value, version: mineVersion, stamped: false, into: &result)
        } else {
          // Theirs is newer, the same edit, or we never versioned ours: take theirs.
          result.agreed[key] = SettingsSyncLocalRecord(
            fingerprint: theirs.value?.fingerprint,
            version: theirs.version
          )
          if mine.value?.fingerprint != theirs.value?.fingerprint {
            result.applyLocally[key] = .some(theirs.value)
          }
        }
      }
    }
    return result
  }

  /// Folds a competing whole-file version (an iCloud conflict version) into `base`, keeping
  /// the higher version per key and the latest record of every device. Unknown keys are kept.
  static func combine(_ base: SettingsSyncDocument, _ other: SettingsSyncDocument)
    -> SettingsSyncDocument {
    var merged = base
    merged.schemaVersion = max(base.schemaVersion, other.schemaVersion)
    for (key, entry) in other.entries {
      if let existing = merged.entries[key], entry.version <= existing.version { continue }
      merged.entries[key] = entry
    }
    for (id, device) in other.devices {
      if let existing = merged.devices[id], existing.lastWriteAt >= device.lastWriteAt { continue }
      merged.devices[id] = device
    }
    return merged
  }

  private static func put(
    _ key: String,
    value: SettingsSyncValue?,
    version: SettingsSyncVersion,
    stamped: Bool,
    into result: inout Result
  ) {
    let entry = SettingsSyncDocument.Entry(value: value, version: version)
    if result.document.entries[key] != entry {
      result.document.entries[key] = entry
      result.documentChanged = true
    }
    if stamped { result.stamped[key] = entry }
    result.agreed[key] = SettingsSyncLocalRecord(fingerprint: value?.fingerprint, version: version)
  }
}

/// What this Mac last agreed with the cloud for one key, or a pending local edit.
struct SettingsSyncLocalRecord: Codable, Equatable, Sendable {
  /// Fingerprint of the value, nil when the key is absent (a reset).
  var fingerprint: String?
  /// Version of that value; nil for a value that has never been versioned.
  var version: SettingsSyncVersion?
}
