import Foundation
import AppKit

/// Keeps the allowlisted preferences (`SettingsSyncRegistry`) in step across Macs through a
/// JSON file in iCloud Drive.
///
/// Ordering model: a Lamport counter, not wall time.
/// - Every edit is stamped `max(this Mac's counter, highest counter seen in the file) + 1`, so
///   an edit made after receiving another Mac's change always orders after it. Equal counters
///   (concurrent edits) are broken by device ID, identically on every Mac.
/// - Wall time is display-only (the "last synced" line, a device's last write); clock skew
///   cannot affect which edit wins.
/// - Counters above `this Mac's counter + 10^9` (or `SettingsSyncDocument.maxCounter`) are
///   corrupt: ignored for merging, never adopted into this Mac's counter.
///
/// Flow: local edits are noticed through `UserDefaults.didChangeNotification`, stamped right
/// away and uploaded after a short debounce. Cloud edits are noticed through an
/// `NSFilePresenter` plus a slow poll, then merged per key inside one coordinated transaction.
/// No echo: a key only counts as changed when its value fingerprint differs from what this Mac
/// last agreed with the cloud. Turning sync off bumps a generation and cancels any in-flight
/// transaction, so a sync already running can neither apply nor write afterwards.
@MainActor
final class SettingsSyncService: ObservableObject {
  enum FirstEnableChoice: Sendable {
    /// Overwrite this Mac's synced settings with the ones already in iCloud.
    case useCloud
    /// Overwrite the iCloud copy with this Mac's settings.
    case replaceCloud
  }

  enum Mode: String, Sendable {
    case normal
    /// "Use iCloud settings": this Mac's values lose to anything already in iCloud.
    case preferCloud
    /// "Replace iCloud": this Mac's values (and resets) win whatever the counters say.
    case preferLocal
    /// First enable when no file existed; stops and asks if one has appeared since.
    case initialUpload
  }

  /// How far above this Mac's counter a cloud counter may be before it is treated as corrupt.
  static let maxCounterJump: Int64 = 1_000_000_000

  static let shared: SettingsSyncService = {
    if AppConfig.isTestRun {
      // Unit tests run inside the app host; never let the shared instance near real iCloud.
      let scratch = (AppConfig.testScratchApplicationSupport
        ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("SettingsSyncShared", isDirectory: true)
      return SettingsSyncService(
        defaults: AppConfig.defaults,
        directory: scratch.appendingPathComponent(SettingsSyncFileStore.folderName),
        iCloudRoot: scratch,
        observesChanges: false
      )
    }
    let root = SettingsSyncFileStore.iCloudDriveRoot
    return SettingsSyncService(
      defaults: AppConfig.defaults,
      directory: root.appendingPathComponent(SettingsSyncFileStore.folderName, isDirectory: true),
      iCloudRoot: root
    )
  }()

  @Published private(set) var isEnabled: Bool
  @Published private(set) var isSyncing = false
  @Published private(set) var isICloudAvailable: Bool
  @Published private(set) var lastSyncedAt: Date?
  @Published private(set) var deviceCount: Int?
  @Published private(set) var lastError: String?
  /// Non-error information from the latest sync (recomputed every sync, so it never goes stale).
  @Published private(set) var notice: String?
  /// True while the user must choose between the existing iCloud copy and this Mac's settings.
  @Published private(set) var isAwaitingFirstEnableChoice = false

  /// Called on the main actor, once per sync, with every key whose value was replaced by a
  /// newer cloud value, so live view models can re-read the whole batch together.
  var onRemoteChangesApplied: ((Set<String>) -> Void)?

  /// Test seam: awaited after the download check and before the file transaction, standing in
  /// for anything that can happen while a sync is in flight (iCloud replacing the file, the
  /// user turning sync off).
  var beforeTransactionForTesting: (() async -> Void)?

  let deviceID: String
  /// Number of files written by this instance; lets tests prove there is no echo.
  private(set) var writeCount = 0
  /// Keys whose received values failed validation in the most recent sync.
  private(set) var lastRejectedKeys: Set<String> = []
  /// This Mac's Lamport counter: highest counter issued or accepted.
  private(set) var counter: Int64
  /// Conflict versions left unmerged by the latest sync; retried even if the file is unchanged.
  private(set) var pendingConflictCount = 0

  var fileURL: URL { store.fileURL }

  private let defaults: UserDefaults
  private let store: SettingsSyncFileStore
  private let iCloudRoot: URL
  private let deviceName: String
  private let now: () -> Date
  private let observesChanges: Bool
  private let localDebounce: Duration
  private let remoteDebounce: Duration
  private let pollInterval: TimeInterval

  private var localState: [String: SettingsSyncLocalRecord]
  /// Counter each not-yet-uploaded local edit was stamped with when first seen (including
  /// removals, whose fingerprint is nil), so it keeps its place in the order.
  private var pendingEdits: [String: SettingsSyncLocalRecord] = [:]
  private var generation = 0
  private var cancellation = SettingsSyncCancellation()
  private var started = false
  private var requestedMode: Mode?
  /// The first-enable choice until a transaction has fully completed it. Persisted, so a
  /// download wait, an IO failure or a relaunch can't turn "Replace iCloud" into an ordinary
  /// merge with empty state.
  private var pendingFirstEnableMode: Mode? {
    didSet {
      if let pendingFirstEnableMode {
        defaults.set(pendingFirstEnableMode.rawValue, forKey: SettingsSyncStateKey.firstEnableMode)
      } else {
        defaults.removeObject(forKey: SettingsSyncStateKey.firstEnableMode)
      }
    }
  }
  private var waitingForDownload = false
  private var lastSeenModificationDate: Date?
  private var defaultsObserver: NSObjectProtocol?
  private var localDebounceTask: Task<Void, Never>?
  private var remoteDebounceTask: Task<Void, Never>?
  private var pollTimer: Timer?
  private var presenter: SettingsSyncFilePresenter?

  init(
    defaults: UserDefaults,
    directory: URL,
    iCloudRoot: URL,
    deviceName: String = Host.current().localizedName ?? "Mac",
    now: @escaping () -> Date = Date.init,
    conflicts: SettingsSyncConflictSource = .fileVersions,
    observesChanges: Bool = true,
    localDebounce: Duration = .seconds(2),
    remoteDebounce: Duration = .milliseconds(500),
    pollInterval: TimeInterval = 30
  ) {
    self.defaults = defaults
    self.store = SettingsSyncFileStore(directory: directory, conflicts: conflicts)
    self.iCloudRoot = iCloudRoot
    self.deviceName = deviceName
    self.now = now
    self.observesChanges = observesChanges
    self.localDebounce = localDebounce
    self.remoteDebounce = remoteDebounce
    self.pollInterval = pollInterval

    if let stored = defaults.string(forKey: SettingsSyncStateKey.deviceID), !stored.isEmpty {
      deviceID = stored
    } else {
      deviceID = UUID().uuidString
      defaults.set(deviceID, forKey: SettingsSyncStateKey.deviceID)
    }
    isEnabled = defaults.bool(forKey: SettingsSyncStateKey.enabled)
    isICloudAvailable = SettingsSyncFileStore.isICloudDriveAvailable(root: iCloudRoot)
    lastSyncedAt = defaults.object(forKey: SettingsSyncStateKey.lastSyncedAt) as? Date
    let storedCounter = (defaults.object(forKey: SettingsSyncStateKey.counter) as? NSNumber)?
      .int64Value ?? 0
    // Out of range can only mean corruption: start over and re-learn from the file (an honest
    // counter is always ≤ the highest one in the file plus local edits).
    counter = (0...SettingsSyncDocument.maxCounter).contains(storedCounter) ? storedCounter : 0
    // Schema 1 used a wall-clock "clock"; its ordering metadata is discarded.
    defaults.removeObject(forKey: SettingsSyncStateKey.legacyClock)
    localState = Self.loadLocalState(from: defaults)
    pendingFirstEnableMode = defaults.string(forKey: SettingsSyncStateKey.firstEnableMode)
      .flatMap(Mode.init(rawValue:))
  }

  // MARK: - Lifecycle

  /// Call once at launch. Does nothing unless the user turned sync on.
  func start() {
    guard !started else { return }
    started = true
    refreshAvailability()
    guard isEnabled else { return }
    beginObserving()
    Task { await syncNow() }
  }

  func refreshAvailability() {
    isICloudAvailable = SettingsSyncFileStore.isICloudDriveAvailable(root: iCloudRoot)
  }

  // MARK: - User actions

  /// Turning on never silently overwrites anything: if iCloud already holds settings the user
  /// is asked which copy to keep (`isAwaitingFirstEnableChoice`).
  func setEnabled(_ enabled: Bool) async {
    guard enabled else {
      disable()
      return
    }
    guard !isEnabled, !isAwaitingFirstEnableChoice else { return }
    refreshAvailability()
    guard isICloudAvailable else {
      lastError = "iCloud Drive is off on this Mac. Turn it on in System Settings → "
        + "your Apple Account → iCloud → iCloud Drive."
      return
    }
    lastError = nil
    notice = nil

    let store = self.store
    let presenter = self.presenter
    let peek = await Task.detached {
      Result { try store.read(presenter: presenter) }
    }.value
    guard !isEnabled, !isAwaitingFirstEnableChoice else { return }
    switch peek {
    case .success(.document):
      isAwaitingFirstEnableChoice = true
    case .success(.missing), .failure(SettingsSyncFileStore.StoreError.corrupt):
      // The transaction re-checks: if a valid file appears meanwhile it stops and asks.
      await enable(mode: .initialUpload)
    case .success(.downloading):
      lastError = "iCloud is still downloading the settings file. Try again in a moment."
    case .failure(let error):
      lastError = error.localizedDescription
    }
  }

  func resolveFirstEnable(_ choice: FirstEnableChoice) async {
    guard isAwaitingFirstEnableChoice else { return }
    isAwaitingFirstEnableChoice = false
    await enable(mode: choice == .useCloud ? .preferCloud : .preferLocal)
  }

  func cancelFirstEnable() {
    isAwaitingFirstEnableChoice = false
  }

  func syncNow() async {
    await sync(mode: .normal)
  }

  // MARK: - Enable / disable

  private func enable(mode: Mode) async {
    generation += 1
    cancellation = SettingsSyncCancellation()
    isEnabled = true
    defaults.set(true, forKey: SettingsSyncStateKey.enabled)
    localState = [:]
    pendingEdits = [:]
    pendingFirstEnableMode = mode == .normal ? nil : mode
    saveLocalState()
    beginObserving()
    await sync(mode: mode)
  }

  private func disable() {
    isAwaitingFirstEnableChoice = false
    guard isEnabled else { return }
    generation += 1
    cancellation.cancel()
    requestedMode = nil
    pendingFirstEnableMode = nil
    isEnabled = false
    defaults.set(false, forKey: SettingsSyncStateKey.enabled)
    // Forget what was agreed: turning sync back on asks again instead of guessing.
    localState = [:]
    pendingEdits = [:]
    saveLocalState()
    setCounter(0)
    pendingConflictCount = 0
    stopObserving()
    lastError = nil
    notice = nil
  }

  /// A document showed up during a first upload: back out and ask the user instead.
  private func revertToChoice() {
    disable()
    isAwaitingFirstEnableChoice = true
  }

  // MARK: - Sync

  private func sync(mode: Mode) async {
    guard isEnabled else { return }
    if isSyncing {
      // Keep the strongest pending request; an explicit choice must not degrade to .normal.
      if mode != .normal || requestedMode == nil { requestedMode = mode }
      return
    }
    isSyncing = true
    var nextMode: Mode? = mode
    while let current = nextMode, isEnabled {
      requestedMode = nil
      await performSync(mode: current)
      nextMode = requestedMode
    }
    isSyncing = false
  }

  private func performSync(mode requested: Mode) async {
    // An unfinished first-enable choice overrides whatever triggered this sync.
    let mode = pendingFirstEnableMode ?? requested
    let syncGeneration = generation
    let token = cancellation
    func stillCurrent() -> Bool { syncGeneration == generation && isEnabled }

    refreshAvailability()
    guard isICloudAvailable else {
      lastError = "iCloud Drive is off on this Mac, so settings aren't syncing."
      return
    }

    let store = self.store
    let pending = await Task.detached { store.requestDownloadIfNeeded() }.value
    guard stillCurrent() else { return }
    if pending == .downloading {
      waitingForDownload = true
      notice = "Waiting for iCloud to download the settings file…"
      return
    }
    if let hook = beforeTransactionForTesting {
      await hook()
      guard stillCurrent() else { return }
    }

    noteLocalChanges()
    let snapshot = readLocalValues()
    let local = localEntries(snapshot: snapshot, mode: mode, stamp: checkedIncrement(counter))
    var input = SettingsSyncFileStore.TransactionInput(
      local: local,
      deviceID: deviceID,
      deviceName: deviceName,
      timestamp: currentTime()
    )
    input.authoritative = mode == .preferLocal
    input.requireNoDocument = mode == .initialUpload
    input.counterCeiling = counterCeiling()

    let presenter = self.presenter
    let transaction = await Task.detached {
      Result { try store.transact(input, cancellation: token, presenter: presenter) }
    }.value
    guard stillCurrent() else { return }

    let outcome: SettingsSyncFileStore.TransactionOutcome
    switch transaction {
    case .success(let value):
      outcome = value
    case .failure(let error):
      lastError = error.localizedDescription
      return
    }
    if outcome.cancelled { return }
    if outcome.documentAppeared {
      revertToChoice()
      return
    }
    guard let result = outcome.merge else { return }
    // Done with the first-enable choice only once it has been fully carried out: merged and
    // (where needed) written. A newer-schema file couldn't be written, so it stays pending.
    if !outcome.schemaTooNew { pendingFirstEnableMode = nil }
    waitingForDownload = false
    lastSeenModificationDate = store.modificationDate()
    pendingConflictCount = outcome.pendingConflicts
    if outcome.wrote { writeCount += 1 }
    adoptCounter(outcome.highestCounter)

    let applied = applyCloudValues(result, local: local, snapshot: snapshot)
    notice = Self.notice(for: outcome, rejected: lastRejectedKeys)

    lastSyncedAt = currentTime()
    defaults.set(lastSyncedAt, forKey: SettingsSyncStateKey.lastSyncedAt)
    deviceCount = result.document.devices.count
    lastError = outcome.schemaTooNew
      ? "iCloud settings were saved by a newer WonderWhisper. Update this Mac to sync changes."
      : nil
    if !applied.isEmpty {
      onRemoteChangesApplied?(applied)
    }
  }

  private static func notice(
    for outcome: SettingsSyncFileStore.TransactionOutcome,
    rejected: Set<String>
  ) -> String? {
    var parts: [String] = []
    if let backup = outcome.quarantinedAs {
      parts.append("The iCloud settings file was unreadable, so it was moved to \(backup) "
        + "and replaced with this Mac's settings.")
    }
    if !outcome.invalidCounterKeys.isEmpty {
      let count = outcome.invalidCounterKeys.count
      parts.append("Ignored \(count) setting\(count == 1 ? "" : "s") in iCloud with invalid "
        + "ordering data.")
    }
    if !rejected.isEmpty {
      let count = rejected.count
      parts.append("Ignored \(count) setting\(count == 1 ? "" : "s") from iCloud that this Mac "
        + "can't use; kept this Mac's value\(count == 1 ? "" : "s").")
    }
    if outcome.pendingConflicts > 0 {
      parts.append("Waiting to merge \(outcome.pendingConflicts) conflicting iCloud "
        + "version\(outcome.pendingConflicts == 1 ? "" : "s").")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// Writes newer, valid cloud values into UserDefaults and records what this Mac now agrees
  /// with. Returns the keys that changed.
  private func applyCloudValues(
    _ result: SettingsSyncMerger.Result,
    local: [String: SettingsSyncMerger.LocalEntry],
    snapshot: [String: SettingsSyncValue?]
  ) -> Set<String> {
    var applied: Set<String> = []
    var rejected: Set<String> = []
    for key in result.applyLocally.keys.sorted() {
      guard let value = result.applyLocally[key] else { continue }
      let current = SettingsSyncValue.read(key, from: defaults)
      if current?.fingerprint != (snapshot[key] ?? nil)?.fingerprint {
        // Edited on this Mac while the transaction ran; the edit is newer, keep it.
        continue
      }
      guard SettingsSyncRegistry.isValid(value, for: key) else {
        // Keep this Mac's value. Without a record it stays "older than the cloud", so it is
        // only uploaded (replacing the bad value) once the user edits it here.
        rejected.insert(key)
        if localState[key] == nil {
          localState[key] = SettingsSyncLocalRecord(
            fingerprint: current?.fingerprint,
            counter: current == nil ? SettingsSyncMerger.noOpinion : 0
          )
        }
        continue
      }
      // Record first, so the defaults change notification finds nothing new to upload.
      if let record = result.agreed[key] { localState[key] = record }
      SettingsSyncValue.write(value, key: key, to: defaults)
      applied.insert(key)
    }
    for (key, entry) in local where result.applyLocally[key] == nil {
      // Absent here and never agreed in the cloud: no opinion, so a later cloud value wins.
      localState[key] = result.agreed[key] ?? SettingsSyncLocalRecord(
        fingerprint: entry.value?.fingerprint,
        counter: entry.value == nil ? SettingsSyncMerger.noOpinion : entry.counter
      )
    }
    saveLocalState()
    for (key, edit) in pendingEdits {
      if let record = localState[key], record.fingerprint == edit.fingerprint {
        pendingEdits[key] = nil
      }
    }
    lastRejectedKeys = rejected
    if let highest = localState.values.map(\.counter).max() { adoptCounter(highest) }
    return applied
  }

  private func localEntries(
    snapshot: [String: SettingsSyncValue?],
    mode: Mode,
    stamp: Int64
  ) -> [String: SettingsSyncMerger.LocalEntry] {
    var entries: [String: SettingsSyncMerger.LocalEntry] = [:]
    for key in SettingsSyncRegistry.syncedKeys {
      let value = snapshot[key] ?? nil
      let entryCounter: Int64
      switch mode {
      case .preferLocal, .initialUpload:
        entryCounter = stamp
      case .preferCloud:
        entryCounter = value == nil ? SettingsSyncMerger.noOpinion : 0
      case .normal:
        let fingerprint = value?.fingerprint
        if let record = localState[key] {
          if record.fingerprint == fingerprint {
            entryCounter = record.counter
          } else if let edit = pendingEdits[key], edit.fingerprint == fingerprint {
            entryCounter = edit.counter
          } else {
            entryCounter = stamp
          }
        } else {
          entryCounter = value == nil ? SettingsSyncMerger.noOpinion : 0
        }
      }
      entries[key] = SettingsSyncMerger.LocalEntry(value: value, counter: entryCounter)
    }
    return entries
  }

  private func readLocalValues() -> [String: SettingsSyncValue?] {
    var values: [String: SettingsSyncValue?] = [:]
    for key in SettingsSyncRegistry.syncedKeys {
      values[key] = .some(SettingsSyncValue.read(key, from: defaults))
    }
    return values
  }

  /// Stamps synced settings that changed since the last sync with the next counter, at the
  /// moment the change is seen (including removals). Runs on every defaults change
  /// notification (cheap: hashes ~70 small values).
  func noteLocalChanges() {
    guard isEnabled else { return }
    var stamp: Int64?
    for key in SettingsSyncRegistry.syncedKeys {
      guard let record = localState[key] else { continue }
      let fingerprint = SettingsSyncValue.read(key, from: defaults)?.fingerprint
      if record.fingerprint == fingerprint {
        pendingEdits[key] = nil
        continue
      }
      // A pending record with a nil fingerprint is a recorded removal, distinct from "none".
      if let pending = pendingEdits[key], pending.fingerprint == fingerprint { continue }
      let next = stamp ?? nextCounter()
      stamp = next
      pendingEdits[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, counter: next)
    }
  }

  /// True when any synced value differs from what this Mac last agreed with the cloud.
  func hasLocalChanges() -> Bool {
    SettingsSyncRegistry.syncedKeys.contains { key in
      let fingerprint = SettingsSyncValue.read(key, from: defaults)?.fingerprint
      guard let record = localState[key] else { return fingerprint != nil }
      return record.fingerprint != fingerprint
    }
  }

  // MARK: - Lamport counter

  /// Wall time, whole milliseconds. Display-only.
  private func currentTime() -> Date {
    SettingsSyncDocument.date(millis: SettingsSyncDocument.millis(now()))
  }

  private func checkedIncrement(_ value: Int64) -> Int64 {
    min(value, SettingsSyncDocument.maxCounter - 1) + 1
  }

  private func nextCounter() -> Int64 {
    setCounter(checkedIncrement(counter))
    return counter
  }

  /// Raises this Mac's counter to a counter it has accepted (never lowers it).
  private func adoptCounter(_ seen: Int64) {
    guard seen > counter, seen <= counterCeiling() else { return }
    setCounter(seen)
  }

  /// Highest cloud counter accepted as genuine: `counter + maxCounterJump`, capped.
  private func counterCeiling() -> Int64 {
    let (sum, overflow) = counter.addingReportingOverflow(Self.maxCounterJump)
    return overflow ? SettingsSyncDocument.maxCounter : min(sum, SettingsSyncDocument.maxCounter)
  }

  private func setCounter(_ value: Int64) {
    counter = value
    if value == 0 {
      defaults.removeObject(forKey: SettingsSyncStateKey.counter)
    } else {
      defaults.set(NSNumber(value: value), forKey: SettingsSyncStateKey.counter)
    }
  }

  // MARK: - Observation

  private func beginObserving() {
    guard observesChanges, defaultsObserver == nil else { return }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: defaults,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.scheduleLocalSync() }
    }

    try? FileManager.default.createDirectory(
      at: store.directory,
      withIntermediateDirectories: true
    )
    let presenter = SettingsSyncFilePresenter(
      directory: store.directory,
      fileName: SettingsSyncFileStore.fileName
    ) { [weak self] in
      Task { @MainActor in self?.scheduleRemoteCheck(force: true) }
    }
    NSFileCoordinator.addFilePresenter(presenter)
    self.presenter = presenter

    let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scheduleRemoteCheck(force: false) }
    }
    timer.tolerance = pollInterval / 4
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func stopObserving() {
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
    }
    defaultsObserver = nil
    if let presenter {
      NSFileCoordinator.removeFilePresenter(presenter)
    }
    presenter = nil
    pollTimer?.invalidate()
    pollTimer = nil
    localDebounceTask?.cancel()
    remoteDebounceTask?.cancel()
  }

  private func scheduleLocalSync() {
    guard isEnabled else { return }
    noteLocalChanges()
    localDebounceTask?.cancel()
    let delay = localDebounce
    localDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.hasLocalChanges() else { return }
      await self.syncNow()
    }
  }

  /// True when a poll should sync even though the file's modification date hasn't changed.
  func hasDeferredRemoteWork() -> Bool {
    waitingForDownload || lastError != nil || pendingConflictCount > 0
      || pendingFirstEnableMode != nil
  }

  private func scheduleRemoteCheck(force: Bool) {
    guard isEnabled else { return }
    remoteDebounceTask?.cancel()
    let delay = remoteDebounce
    remoteDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      let changed = self.store.modificationDate() != self.lastSeenModificationDate
      guard force || changed || self.hasDeferredRemoteWork() else { return }
      await self.syncNow()
    }
  }

  // MARK: - Persistence of sync state

  private static func loadLocalState(
    from defaults: UserDefaults
  ) -> [String: SettingsSyncLocalRecord] {
    guard let data = defaults.data(forKey: SettingsSyncStateKey.localState) else { return [:] }
    // Schema-1 records (wall-clock dates) fail to decode and are dropped, as intended.
    return (try? JSONDecoder().decode([String: SettingsSyncLocalRecord].self, from: data)) ?? [:]
  }

  private func saveLocalState() {
    guard let data = try? JSONEncoder().encode(localState) else { return }
    defaults.set(data, forKey: SettingsSyncStateKey.localState)
  }
}
