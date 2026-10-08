import Foundation

/// One Mac's sync state as a pure value: what it agreed with the cloud, its pending local
/// edits, and its Lamport counter. No IO and no async, so the service and the simulation tests
/// drive exactly the same logic. The whole value is persisted after every change, so a
/// relaunch never loses or re-stamps a pending edit.
struct SettingsSyncEngine: Codable, Equatable, Sendable {
  var deviceID: String
  /// Highest counter issued or accepted.
  var counter: Int64 = 0
  /// Per key: the value and version this Mac agrees with the cloud on.
  var records: [String: SettingsSyncLocalRecord] = [:]
  /// Per key: a genuine local edit not yet uploaded, stamped with its version when observed.
  var pending: [String: SettingsSyncLocalRecord] = [:]

  init(deviceID: String) {
    self.deviceID = deviceID
  }

  /// Values the engine reads; nil inner value means the key is absent.
  typealias Values = [String: SettingsSyncValue?]

  struct Completion: Equatable, Sendable {
    /// Cloud values to write into this Mac's preferences (nil removes the key).
    var apply: [String: SettingsSyncValue?] = [:]
    /// Keys whose cloud value failed validation; this Mac's value was kept.
    var rejected: Set<String> = []
  }

  /// Stamps every synced key whose value differs from what was agreed (resets included) with a
  /// new version, at the moment the change is seen. Only keys with an agreed record count:
  /// before the first sync there is nothing to edit against. Returns true if anything changed.
  @discardableResult
  mutating func noteLocalChanges(_ current: Values) -> Bool {
    var changed = false
    var stamp: SettingsSyncVersion?
    for key in current.keys.sorted() {
      guard let record = records[key] else { continue }
      let fingerprint = (current[key] ?? nil)?.fingerprint
      if let edit = pending[key] {
        // Unchanged since it was stamped (a nil fingerprint is a recorded reset).
        if edit.fingerprint == fingerprint { continue }
        // Changed again, possibly back to the agreed value: an undo is a genuine edit too,
        // so it gets a new version rather than silently reverting to the old one.
      } else if record.fingerprint == fingerprint {
        // Unchanged (also covers re-saving the same value): not an edit.
        continue
      }
      let version = stamp ?? nextVersion()
      stamp = version
      pending[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, version: version)
      changed = true
    }
    return changed
  }

  /// What this Mac brings to a merge. Explicit first-enable modes ignore local versions.
  func candidates(
    _ current: Values,
    mode: SettingsSyncMerger.Mode
  ) -> [String: SettingsSyncMerger.LocalCandidate] {
    var candidates: [String: SettingsSyncMerger.LocalCandidate] = [:]
    for (key, value) in current {
      let fingerprint = value?.fingerprint
      var version: SettingsSyncVersion?
      if mode == .normal {
        if let edit = pending[key], edit.fingerprint == fingerprint {
          version = edit.version
        } else if let record = records[key], record.fingerprint == fingerprint {
          version = record.version
        }
      }
      candidates[key] = SettingsSyncMerger.LocalCandidate(value: value, version: version)
    }
    return candidates
  }

  /// Records the outcome of a successful transaction.
  /// - Parameters:
  ///   - snapshot: the values the candidates were built from.
  ///   - current: the values now (a key edited during the transaction is not overwritten).
  ///   - isValid: per-key validation of a received value.
  mutating func complete(
    _ result: SettingsSyncMerger.Result,
    candidates: [String: SettingsSyncMerger.LocalCandidate],
    snapshot: Values,
    current: Values,
    isValid: (String, SettingsSyncValue?) -> Bool
  ) -> Completion {
    var completion = Completion()
    var after = current
    for key in result.applyLocally.keys.sorted() {
      guard let value = result.applyLocally[key] else { continue }
      let now = (current[key] ?? nil)?.fingerprint
      if now != (snapshot[key] ?? nil)?.fingerprint {
        continue  // edited here while the transaction ran: that edit is newer, keep it
      }
      guard isValid(key, value) else {
        completion.rejected.insert(key)
        if records[key] == nil {
          records[key] = SettingsSyncLocalRecord(fingerprint: now, version: nil)
        }
        continue
      }
      if let agreed = result.agreed[key] { records[key] = agreed }
      completion.apply[key] = .some(value)
      after[key] = .some(value)
    }
    for (key, candidate) in candidates where result.applyLocally[key] == nil {
      if let agreed = result.agreed[key] {
        records[key] = agreed
      } else if records[key] == nil {
        // Locked, or absent everywhere: remember what is here, unversioned.
        records[key] = SettingsSyncLocalRecord(
          fingerprint: candidate.value?.fingerprint,
          version: candidate.version
        )
      }
    }
    // A pending edit is settled once the agreed record matches the value now held: it was
    // uploaded (the record carries its version) or superseded by a newer applied value.
    for key in pending.keys {
      if let record = records[key], record.fingerprint == (after[key] ?? nil)?.fingerprint {
        pending[key] = nil
      }
    }
    adopt(result.document.highestCounter)
    for record in records.values { if let version = record.version { adopt(version.counter) } }
    return completion
  }

  /// Raises the counter to one this Mac has accepted (never lowers it).
  mutating func adopt(_ seen: Int64) {
    guard (0...SettingsSyncDocument.maxCounter).contains(seen), seen > counter else { return }
    counter = seen
  }

  /// True when any value differs from what was agreed, or an edit is pending.
  func hasLocalChanges(_ current: Values) -> Bool {
    if !pending.isEmpty { return true }
    return current.contains { key, value in
      guard let record = records[key] else { return value != nil }
      return record.fingerprint != value?.fingerprint
    }
  }

  mutating func reset() {
    counter = 0
    records = [:]
    pending = [:]
  }

  private mutating func nextVersion() -> SettingsSyncVersion {
    counter = min(counter, SettingsSyncDocument.maxCounter - 1) + 1
    return SettingsSyncVersion(counter, deviceID)
  }
}
