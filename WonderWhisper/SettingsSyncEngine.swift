import Foundation

/// One Mac's sync state as a pure value: what it agreed with the cloud, its pending local
/// edits, and the highest version it has issued or accepted. No IO and no async, so the service
/// and the simulation tests drive exactly the same logic. The whole value is persisted after
/// every change, so a relaunch never loses or re-stamps a pending edit.
struct SettingsSyncEngine: Codable, Equatable, Sendable {
  var deviceID: String
  /// Highest version issued or accepted (the Lamport clock, with its epoch).
  var latest: SettingsSyncVersion?
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

  /// The Lamport counter (within the current epoch).
  var counter: Int64 { latest?.counter ?? 0 }

  /// True when no further version can be created: the user has to reset sync ordering.
  var isExhausted: Bool { counter >= SettingsSyncDocument.maxCounter }

  /// Stamps every synced key whose value differs from what was agreed (resets included) with a
  /// new version, at the moment the change is seen. Only keys with an agreed record count:
  /// before the first sync there is nothing to edit against. Returns true if anything changed.
  /// When counters are exhausted nothing is stamped (the change stays local, unversioned).
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
      if stamp == nil { stamp = nextVersion() }
      guard let stamp else { return changed }  // exhausted
      pending[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, version: stamp)
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
  ///   - snapshotVersion: `latest` when the snapshot was taken. A pending edit with a newer
  ///     version was made while the transaction ran: it is kept (even if its value equals the
  ///     snapshot, e.g. an undo) and its key is not overwritten.
  ///   - current: the values now.
  ///   - isValid: per-key validation of a received value.
  mutating func complete(
    _ result: SettingsSyncMerger.Result,
    candidates: [String: SettingsSyncMerger.LocalCandidate],
    snapshot: Values,
    snapshotVersion: SettingsSyncVersion?,
    current: Values,
    isValid: (String, SettingsSyncValue?) -> Bool
  ) -> Completion {
    let inFlight = Set(pending.compactMap { key, edit -> String? in
      guard let version = edit.version else { return nil }
      if let snapshotVersion, version <= snapshotVersion { return nil }
      return key
    })

    var completion = Completion()
    for key in result.applyLocally.keys.sorted() {
      guard let value = result.applyLocally[key] else { continue }
      let now = (current[key] ?? nil)?.fingerprint
      if inFlight.contains(key) || now != (snapshot[key] ?? nil)?.fingerprint {
        continue  // edited here while the transaction ran: that edit is newer, keep it
      }
      if let record = records[key], record.fingerprint != now, pending[key] == nil {
        // A local change that couldn't be versioned (counters exhausted): keep it until the
        // user resets sync ordering, rather than overwrite it.
        continue
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
    }
    for (key, candidate) in candidates where result.applyLocally[key] == nil {
      if let agreed = result.agreed[key] {
        records[key] = agreed
      } else if records[key] == nil {
        // Blocked, or absent everywhere: remember what is here, unversioned.
        records[key] = SettingsSyncLocalRecord(
          fingerprint: candidate.value?.fingerprint,
          version: candidate.version
        )
      }
    }
    // Settle pending edits by VERSION, never by value: an edit is done once the agreed record
    // carries its version or a newer one. In-flight edits are always kept.
    for (key, edit) in pending where !inFlight.contains(key) {
      if let agreedVersion = records[key]?.version, let version = edit.version,
         agreedVersion >= version {
        pending[key] = nil
      }
    }
    adopt(result.document.highestVersion)
    for record in records.values { adopt(record.version) }
    return completion
  }

  /// Raises `latest` to a version this Mac has accepted (never lowers it).
  mutating func adopt(_ seen: SettingsSyncVersion?) {
    guard let seen else { return }
    if let latest, seen <= latest { return }
    latest = seen
  }

  /// Drops state for keys no longer synced (an app version that removed them from the
  /// allowlist). If a later version adds a key back, it starts unversioned.
  mutating func retain(keys: Set<String>) {
    records = records.filter { keys.contains($0.key) }
    pending = pending.filter { keys.contains($0.key) }
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
    latest = nil
    records = [:]
    pending = [:]
  }

  /// The next version, or nil when the counter would pass `maxCounter`.
  private mutating func nextVersion() -> SettingsSyncVersion? {
    guard let latest else {
      let first = SettingsSyncVersion(1, deviceID)
      self.latest = first
      return first
    }
    guard let next = latest.successor(writer: deviceID) else { return nil }
    self.latest = next
    return next
  }
}
