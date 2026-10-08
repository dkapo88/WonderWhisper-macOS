import Foundation

/// Pure planning step of one sync transaction: given what is on disk (the current file and any
/// unresolved iCloud conflict versions) and this Mac's candidates, decide what to write, which
/// conflict versions were incorporated, and what this Mac must apply. No IO, so the same logic
/// runs inside the coordinated file transaction and in the in-memory simulation tests.
enum SettingsSyncTransaction {
  struct Input: Sendable {
    var local: [String: SettingsSyncMerger.LocalCandidate]
    var deviceID: String
    var deviceName: String
    /// Wall time, display-only (the device's last write).
    var timestamp: Date
    var mode: SettingsSyncMerger.Mode = .normal
    /// This Mac's counter; new versions are stamped above it.
    var localCounter: Int64 = 0
    /// First upload after the user saw no file: if a document has appeared since, stop so
    /// the user can be asked which copy to keep instead of silently merging.
    var requireNoDocument = false
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
    /// Conflict versions left unresolved: unreadable, or holding entries this build can't
    /// verify. They are retried on every sync and never discarded.
    var pendingConflicts = 0
    /// Keys whose current cloud entry couldn't be decoded; preserved, never overwritten.
    var lockedKeys: Set<String> = []
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
    plan.lockedKeys = Set(remote?.opaqueEntries.keys.map { $0 } ?? [])

    // Validate each conflict version on its own BEFORE combining. One that can't be read, has
    // entries this build can't decode, or touches a locked key is kept for a later retry.
    for (index, data) in conflicts.enumerated() {
      guard let data,
            let version = try? SettingsSyncDocument.decode(data),
            version.opaqueEntries.isEmpty,
            plan.lockedKeys.isDisjoint(with: version.entries.keys) else {
        plan.pendingConflicts += 1
        continue
      }
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
      localCounter: input.localCounter,
      mode: input.mode,
      lockedKeys: plan.lockedKeys
    )
    if result.document.devices[input.deviceID] == nil
      || !plan.incorporated.isEmpty
      || unreadable {
      result.documentChanged = true
    }
    guard result.documentChanged, !plan.schemaTooNew else {
      result.documentChanged = false
      plan.merge = result
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
    return plan
  }
}
