import Foundation

/// Pure planning step of one sync transaction: given what is on disk (the current file and any
/// unresolved iCloud conflict versions) and this Mac's candidates, decide what to write, which
/// conflict versions were incorporated, which keys are blocked, and what this Mac must apply.
/// No IO, so the same logic runs inside the coordinated file transaction and in the in-memory
/// simulation tests.
enum SettingsSyncTransaction {
  struct Input: Sendable {
    var local: [String: SettingsSyncMerger.LocalCandidate]
    var deviceID: String
    var deviceName: String
    /// Wall time, display-only (the device's last write).
    var timestamp: Date
    var mode: SettingsSyncMerger.Mode = .normal
    /// Highest version this Mac has issued or accepted; new versions are stamped above it.
    var localVersion: SettingsSyncVersion?
    /// Allocated and persisted by the engine BEFORE the writing transaction. A stale or
    /// missing reservation causes a read-only retry, never a transaction-created version.
    var reservedVersion: SettingsSyncVersion?
    /// First upload after the user saw no file: if a document has appeared since, stop so
    /// the user can be asked which copy to keep instead of silently merging.
    var requireNoDocument = false
    /// Blocked keys the user chose to repair (Replace repairs every blocked key).
    var repairKeys: Set<String> = []
  }

  enum CurrentFile: Sendable {
    case missing
    case contents(Data)
  }

  struct Plan: Sendable {
    /// Nil when the transaction stopped early (a document appeared).
    var merge: SettingsSyncMerger.Result?
    /// The document to write, or nil when nothing needs writing.
    var write: SettingsSyncDocument?
    /// The current file couldn't be parsed at all; back it up before overwriting.
    var quarantine = false
    var documentAppeared = false
    var schemaTooNew = false
    /// Indices (into the conflict list) of versions folded into the merge.
    var incorporated: [Int] = []
    /// Conflict versions left unresolved (unreadable, or blocked); retried every sync.
    var pendingConflicts = 0
    /// Keys whose cloud entry (in the file or a conflict version) couldn't be decoded and that
    /// remain blocked after this transaction. Never applied, never overwritten.
    var blockedKeys: Set<String> = []
    /// Keys repaired by this transaction.
    var repairedKeys: Set<String> = []
    /// Raw JSON of every undecodable entry seen, to back up next to settings.json.
    var blockedRaw: [String: Data] = [:]
    /// A new version was needed but counters are at the ceiling; nothing explicit was done.
    var exhausted = false
    var needsReservation = false
    var reservationFloor: SettingsSyncVersion?
    /// Original documents to preserve before an explicit recovery overwrites any copies.
    var replacementBackups: [Data] = []
  }

  static func plan(
    _ input: Input,
    current: CurrentFile,
    conflicts: [Data?]
  ) -> Plan {
    var plan = Plan()

    var remote: SettingsSyncDocument?
    var unreadable = false
    if case .contents(let data) = current {
      if let document = try? SettingsSyncDocument.decode(data) {
        remote = document
      } else {
        unreadable = true
      }
    }
    let decodedConflicts = conflicts.map { data in
      data.flatMap { try? SettingsSyncDocument.decode($0) }
    }

    // Blocked keys: undecodable entries in the file or in any conflict version.
    var blocked = Set(remote?.opaqueEntries.keys.map { $0 } ?? [])
    for (key, raw) in remote?.opaqueEntries ?? [:] { plan.blockedRaw[key] = raw }
    for version in decodedConflicts.compactMap({ $0 }) {
      for (key, raw) in version.opaqueEntries {
        blocked.insert(key)
        if plan.blockedRaw[key] == nil { plan.blockedRaw[key] = raw }
      }
    }
    let repairing = input.mode == .replace
      ? blocked
      : blocked.intersection(input.repairKeys)
    let stillBlocked = blocked.subtracting(repairing)
    plan.repairedKeys = repairing
    plan.blockedKeys = stillBlocked
    for key in repairing { remote?.opaqueEntries[key] = nil }

    // Validate each conflict version on its own BEFORE combining. One that can't be read, or
    // that has a blocked entry (its own or touching a key blocked in the file), is kept for a
    // later retry. Undecodable entries for keys being repaired are dropped (they are backed up).
    for (index, decoded) in decodedConflicts.enumerated() {
      guard var version = decoded,
            Set(version.opaqueEntries.keys).isSubset(of: repairing),
            stillBlocked.isDisjoint(with: version.entries.keys) else {
        plan.pendingConflicts += 1
        continue
      }
      version.opaqueEntries = [:]
      plan.incorporated.append(index)
      remote = remote.map { SettingsSyncMerger.combine($0, version) } ?? version
    }

    if input.requireNoDocument, remote != nil {
      plan.documentAppeared = true
      return plan
    }
    plan.schemaTooNew = (remote?.schemaVersion ?? 0) > SettingsSyncDocument.currentSchemaVersion

    var result = SettingsSyncMerger.merge(
      local: input.local,
      remote: remote,
      deviceID: input.deviceID,
      localVersion: input.localVersion,
      mode: input.mode,
      lockedKeys: stillBlocked,
      forceStampKeys: repairing,
      reservedVersion: input.reservedVersion
    )
    let floor = ([input.localVersion, remote?.highestVersion]
      + input.local.values.map(\.version)).compactMap { $0 }.max()
    if !result.stamped.isEmpty, !plan.schemaTooNew,
       input.reservedVersion == nil
        || (input.reservedVersion?.counter ?? 0) <= (floor?.counter ?? 0) {
      plan.needsReservation = true
      plan.reservationFloor = floor
      plan.repairedKeys = []
      plan.blockedKeys = blocked
      plan.incorporated = []
      plan.pendingConflicts = conflicts.count
      return plan
    }
    plan.exhausted = result.exhausted
    if result.exhausted, !repairing.isEmpty || input.mode == .replace {
      // An explicit choice that can't be carried out without reusing a version: change
      // nothing (blocked entries stay preserved) and keep the counter-ceiling error visible.
      plan.repairedKeys = []
      plan.blockedKeys = blocked
      plan.incorporated = []
      plan.pendingConflicts = conflicts.count
      return plan
    }
    if result.document.devices[input.deviceID] == nil
      || !plan.incorporated.isEmpty
      || !repairing.isEmpty
      || unreadable {
      result.documentChanged = true
    }
    guard result.documentChanged, !plan.schemaTooNew else {
      result.documentChanged = false
      plan.merge = result
      plan.repairedKeys = []
      plan.blockedKeys = blocked
      return plan
    }
    result.document.schemaVersion = SettingsSyncDocument.currentSchemaVersion
    result.document.devices[input.deviceID] = SettingsSyncDocument.Device(
      name: input.deviceName,
      lastWriteAt: input.timestamp
    )
    plan.merge = result
    plan.write = result.document
    plan.quarantine = unreadable
    if input.mode == .replace || !repairing.isEmpty {
      let replacedKeys = input.mode == .replace ? Set(input.local.keys) : repairing
      let originals: [Data] = {
        if case .contents(let data) = current { return [data] }
        return []
      }() + conflicts.compactMap { $0 }
      plan.replacementBackups = originals.filter { data in
        guard let original = try? SettingsSyncDocument.decode(data) else { return false }
        return !replacedKeys.isDisjoint(with: original.entries.keys)
          || !replacedKeys.isDisjoint(with: original.opaqueEntries.keys)
      }
    }
    return plan
  }
}
