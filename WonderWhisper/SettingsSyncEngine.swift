import Foundation

/// One Mac's sync state as a pure value: what it agreed with the cloud, its pending local
/// edits, and the highest version it has issued or accepted. No IO and no async, so the service
/// and the simulation tests drive exactly the same logic. The whole value is persisted after
/// every change, so a relaunch never loses or re-stamps a pending edit.
struct SettingsSyncEngine: Codable, Equatable, Sendable {
  var deviceID: String
  /// Highest version issued or accepted (the Lamport clock).
  var latest: SettingsSyncVersion?
  /// Per key: the value and version this Mac agrees with the cloud on.
  var records: [String: SettingsSyncLocalRecord] = [:]
  /// Per key: a genuine local edit not yet uploaded, stamped with its version when observed.
  var pending: [String: SettingsSyncLocalRecord] = [:]
  /// Observations for keys awaiting their first baseline. Kept through IO retries and saved
  /// with the engine so an undo, or a relaunch during adoption, cannot lose a genuine edit.
  var unagreedObservations: [String: SettingsSyncLocalRecord] = [:]
  var unagreedEdits: Set<String> = []

  mutating func beginTransaction(_ snapshot: Values) {
    for (key, value) in snapshot where records[key] == nil {
      if unagreedObservations[key] == nil {
        unagreedObservations[key] = SettingsSyncLocalRecord(
          fingerprint: value?.fingerprint, version: nil
        )
      }
    }
  }

  /// Reserve a transaction's batch from this Mac's clock before IO can interleave an edit.
  /// A newer cloud file may require a larger reservation; the transaction then retries
  /// without writing. Consumed counters are never reused, even after an IO failure.
  mutating func reserveVersion(after floor: SettingsSyncVersion?) -> SettingsSyncVersion? {
    adopt(floor)
    return nextVersion()
  }

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

  /// The Lamport counter.
  var counter: Int64 { latest?.counter ?? 0 }

  /// True when no further version can be created. No version may be reused.
  var isExhausted: Bool { counter >= SettingsSyncDocument.maxCounter }

  /// Stamps every synced key whose value differs from what was agreed (resets included) with a
  /// new version when seen. Un-agreed keys track edits and undos during a transaction, then
  /// receive a version above the completed baseline. Returns true if anything changed.
  /// When counters are exhausted nothing is stamped (the change stays local, unversioned).
  @discardableResult
  mutating func noteLocalChanges(_ current: Values) -> Bool {
    var changed = false
    var stamp: SettingsSyncVersion?
    for key in current.keys.sorted() {
      let fingerprint = (current[key] ?? nil)?.fingerprint
      guard let record = records[key] else {
        if let observation = unagreedObservations[key], observation.fingerprint != fingerprint {
          unagreedObservations[key]?.fingerprint = fingerprint
          unagreedEdits.insert(key)
          changed = true
        }
        continue
      }
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
    let previouslyUnagreed = Set(candidates.keys.filter { records[$0] == nil })
    let deferredEdits = previouslyUnagreed.filter { key in
      unagreedEdits.contains(key)
        || (current[key] ?? nil)?.fingerprint != (snapshot[key] ?? nil)?.fingerprint
    }
    // Adopt the transaction before issuing any previously unversioned genuine edit. Unlike
    // old exhausted edits, these are observations made during this particular transaction.
    adopt(result.document.highestVersion)
    var deferredStamp: SettingsSyncVersion?
    for key in candidates.keys.sorted() {
      guard let candidate = candidates[key] else { continue }
      let now = (current[key] ?? nil)?.fingerprint
      let cloudValue = result.document.entries[key]?.value
      let hasRemoteApply = result.applyLocally[key] != nil
      let invalid = hasRemoteApply && !isValid(key, cloudValue)
      let oldRecord = records[key]
      if invalid {
        completion.rejected.insert(key)
        if oldRecord == nil {
          records[key] = SettingsSyncLocalRecord(fingerprint: now, version: nil)
        }
        continue
      }
      if let agreed = result.agreed[key] {
        // Establish the baseline even when the local value was edited during file IO.
        records[key] = agreed
      } else if oldRecord == nil {
        records[key] = SettingsSyncLocalRecord(
          fingerprint: candidate.value?.fingerprint, version: candidate.version
        )
      }
      if deferredEdits.contains(key) {
        if deferredStamp == nil { deferredStamp = nextVersion() }
        if let deferredStamp {
          pending[key] = SettingsSyncLocalRecord(fingerprint: now, version: deferredStamp)
        }
        continue
      }
      if inFlight.contains(key) || now != (snapshot[key] ?? nil)?.fingerprint { continue }
      if let oldRecord, oldRecord.fingerprint != now, pending[key] == nil {
        // Exhausted edits stay local and unversioned. Accepting a Replace must never promote
        // one into a fresh operation above that Replace.
        continue
      }
      if hasRemoteApply { completion.apply[key] = .some(cloudValue) }
    }
    for (key, edit) in pending where !inFlight.contains(key) && !deferredEdits.contains(key) {
      if let agreedVersion = records[key]?.version, let version = edit.version,
         agreedVersion >= version {
        pending[key] = nil
      }
    }
    for record in records.values { adopt(record.version) }
    unagreedObservations = [:]
    unagreedEdits = []
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
    unagreedObservations = unagreedObservations.filter { keys.contains($0.key) }
    unagreedEdits.formIntersection(keys)
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
    unagreedObservations = [:]
    unagreedEdits = []
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
