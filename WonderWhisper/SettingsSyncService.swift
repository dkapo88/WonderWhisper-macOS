import Foundation
import AppKit

/// Keeps the allowlisted preferences (`SettingsSyncRegistry`) in step across Macs through a
/// JSON file in iCloud Drive.
///
/// Ordering model (see `SettingsSyncVersion`):
/// - A version is `(Lamport counter, writer device)`. It is created only when this Mac observes
///   a genuine local edit (or carries out an explicit first-enable choice) and never changes
///   afterwards. Received, merged, agreed, persisted and re-uploaded values keep their original
///   version. Per key the higher version wins; wall time is display-only.
/// - New versions are stamped `max(this Mac's counter, highest counter seen) + 1`, at the moment
///   the edit is observed, and persisted immediately (so a relaunch never re-stamps them).
/// - "Use iCloud" adopts every cloud key, resets included. "Replace iCloud" stamps the whole
///   local batch above every counter in the file and its conflict versions.
///
/// This class is the async shell: notifications, polling, the file transaction off the main
/// thread, and writing received values. The logic lives in `SettingsSyncEngine` (per-Mac state)
/// and `SettingsSyncTransaction` (read-merge-write planning), which the simulation tests drive
/// directly.
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
    /// "Use iCloud settings".
    case preferCloud
    /// "Replace iCloud with this Mac's settings".
    case preferLocal
    /// First enable when no file existed; stops and asks if one has appeared since.
    case initialUpload

    var mergeMode: SettingsSyncMerger.Mode {
      switch self {
      case .normal, .initialUpload: return .normal
      case .preferCloud: return .adopt
      case .preferLocal: return .replace
      }
    }
  }

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
  /// Settings whose iCloud entry couldn't be read. They don't sync until repaired; the raw entry
  /// is backed up next to settings.json.
  @Published private(set) var blockedKeys: [String] = []
  /// Version counters are at the ceiling; new changes are blocked.
  @Published private(set) var isOrderingExhausted = false

  /// Called on the main actor, once per sync, with every key whose value was replaced by a
  /// newer cloud value, so live view models can re-read the whole batch together.
  var onRemoteChangesApplied: ((Set<String>) -> Void)?

  /// Test seam: awaited after the download check and before the file transaction, standing in
  /// for anything that can happen while a sync is in flight (iCloud replacing the file, the
  /// user turning sync off).
  var beforeTransactionForTesting: (() async -> Void)?
  /// Test seam after snapshot/reservation, while the transaction is in flight.
  var afterSnapshotForTesting: (() async -> Void)?

  var deviceID: String { engine.deviceID }
  /// This Mac's Lamport counter: highest counter issued or accepted.
  var counter: Int64 { engine.counter }
  /// Highest version this Mac has issued or accepted.
  var latestVersion: SettingsSyncVersion? { engine.latest }
  /// Number of files written by this instance; lets tests prove there is no echo.
  private(set) var writeCount = 0
  /// Keys whose received values failed validation in the most recent sync.
  private(set) var lastRejectedKeys: Set<String> = []
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
  private let keys: Set<String>

  private var engine: SettingsSyncEngine
  private var generation = 0
  private var cancellation = SettingsSyncCancellation()
  private var started = false
  private var requestedMode: Mode?
  /// Blocked keys the user asked to repair; consumed by the next successful transaction.
  private var pendingRepairKeys: Set<String> = []
  /// The first-enable choice until a transaction has fully carried it out. Persisted, so a
  /// download wait, an IO failure or a relaunch can't turn "Replace iCloud" into an ordinary
  /// merge.
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
    self.keys = SettingsSyncRegistry.syncedKeys

    let deviceID: String
    if let stored = defaults.string(forKey: SettingsSyncStateKey.deviceID), !stored.isEmpty {
      deviceID = stored
    } else {
      deviceID = UUID().uuidString
      defaults.set(deviceID, forKey: SettingsSyncStateKey.deviceID)
    }
    var engine = Self.loadEngine(from: defaults) ?? SettingsSyncEngine(deviceID: deviceID)
    engine.deviceID = deviceID
    // A key this app version no longer syncs is forgotten; if it comes back, it starts fresh.
    engine.retain(keys: SettingsSyncRegistry.syncedKeys)
    self.engine = engine
    isEnabled = defaults.bool(forKey: SettingsSyncStateKey.enabled)
    isICloudAvailable = SettingsSyncFileStore.isICloudDriveAvailable(root: iCloudRoot)
    lastSyncedAt = defaults.object(forKey: SettingsSyncStateKey.lastSyncedAt) as? Date
    // Earlier schemas kept these separately; the engine state now holds everything.
    defaults.removeObject(forKey: SettingsSyncStateKey.legacyClock)
    defaults.removeObject(forKey: SettingsSyncStateKey.legacyCounter)
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
    case .success(.document(let document)):
      blockedKeys = document.opaqueEntries.keys.sorted()
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

  /// "Repair": replace the unreadable iCloud entries for `keys` (all blocked keys by default)
  /// with this Mac's values at a valid version above everything in the file, and resolve the
  /// conflict versions they were blocking. The raw entries stay backed up.
  func repairBlockedKeys(_ keys: Set<String>? = nil) async {
    pendingRepairKeys.formUnion(keys ?? Set(blockedKeys))
    await sync(mode: .normal)
  }

  // MARK: - Enable / disable

  private func enable(mode: Mode) async {
    generation += 1
    cancellation = SettingsSyncCancellation()
    isEnabled = true
    defaults.set(true, forKey: SettingsSyncStateKey.enabled)
    engine.reset()
    saveEngine()
    pendingFirstEnableMode = mode == .normal ? nil : mode
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
    engine.reset()
    saveEngine()
    pendingConflictCount = 0
    pendingRepairKeys = []
    blockedKeys = []
    isOrderingExhausted = false
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
    var snapshot = readLocalValues()
    engine.beginTransaction(snapshot)
    var versionFloor = engine.latest
    var reservedVersion: SettingsSyncVersion?
    if mode.mergeMode != .normal || !pendingRepairKeys.isEmpty {
      reservedVersion = engine.reserveVersion(after: nil)
    }
    var snapshotVersion = engine.latest
    saveEngine()
    var candidates = engine.candidates(snapshot, mode: mode.mergeMode)
    var finished: SettingsSyncFileStore.TransactionOutcome?
    // If iCloud installed a newer counter, reserve above it and retry the coordinated read.
    // No write or conflict resolution happens until the reservation has been checked.
    for _ in 0..<4 {
      var input = SettingsSyncTransaction.Input(
        local: candidates,
        deviceID: deviceID,
        deviceName: deviceName,
        timestamp: currentTime()
      )
      input.mode = mode.mergeMode
      input.localVersion = versionFloor
      input.reservedVersion = reservedVersion
      input.requireNoDocument = mode == .initialUpload
      input.repairKeys = pendingRepairKeys
      if let hook = afterSnapshotForTesting {
        await hook()
        guard stillCurrent() else { return }
      }
      let presenter = self.presenter
      let transactionInput = input
      let transaction = await Task.detached {
        Result { try store.transact(transactionInput, cancellation: token, presenter: presenter) }
      }.value
      guard stillCurrent() else { return }
      let outcome: SettingsSyncFileStore.TransactionOutcome
      switch transaction {
      case .success(let value): outcome = value
      case .failure(let error):
        lastError = error.localizedDescription
        return
      }
      guard outcome.needsReservation else {
        finished = outcome
        break
      }
      noteLocalChanges()
      snapshot = readLocalValues()
      versionFloor = engine.latest
      reservedVersion = engine.reserveVersion(after: outcome.reservationFloor)
      snapshotVersion = engine.latest
      candidates = engine.candidates(snapshot, mode: mode.mergeMode)
      saveEngine()
      guard reservedVersion != nil else {
        isOrderingExhausted = true
        lastError = Self.exhaustedMessage
        return
      }
    }
    guard let outcome = finished else {
      lastError = "iCloud settings changed during sync. Try Sync Now again."
      return
    }
    if outcome.cancelled { return }
    if outcome.documentAppeared {
      revertToChoice()
      return
    }
    blockedKeys = outcome.blockedKeys.sorted()
    isOrderingExhausted = outcome.exhausted || engine.isExhausted
    guard let result = outcome.merge else {
      if outcome.exhausted { lastError = Self.exhaustedMessage }
      return
    }
    pendingRepairKeys.subtract(outcome.repairedKeys)
    pendingRepairKeys.formIntersection(outcome.blockedKeys)
    // Done with the first-enable choice only once it has been fully carried out: merged and
    // (where needed) written. A newer-schema file couldn't be written, so it stays pending.
    if !outcome.schemaTooNew { pendingFirstEnableMode = nil }
    waitingForDownload = false
    lastSeenModificationDate = store.modificationDate()
    pendingConflictCount = outcome.pendingConflicts
    if outcome.wrote { writeCount += 1 }

    // Stamp anything edited while the transaction ran, so completion can tell it apart by
    // version (an undo back to the snapshot value included).
    noteLocalChanges()
    let completion = engine.complete(
      result,
      candidates: candidates,
      snapshot: snapshot,
      snapshotVersion: snapshotVersion,
      current: readLocalValues(),
      isValid: { SettingsSyncRegistry.isValid($1, for: $0) }
    )
    // Record first (engine), then write: the defaults change notification then finds nothing
    // new to stamp.
    saveEngine()
    for (key, value) in completion.apply {
      SettingsSyncValue.write(value, key: key, to: defaults)
    }
    lastRejectedKeys = completion.rejected
    notice = Self.notice(for: outcome, rejected: completion.rejected)

    lastSyncedAt = currentTime()
    defaults.set(lastSyncedAt, forKey: SettingsSyncStateKey.lastSyncedAt)
    deviceCount = result.document.devices.count
    isOrderingExhausted = outcome.exhausted || engine.isExhausted
    if outcome.schemaTooNew {
      lastError = "iCloud settings were saved by a newer WonderWhisper. Update this Mac to sync "
        + "changes."
    } else if isOrderingExhausted {
      lastError = Self.exhaustedMessage
    } else {
      lastError = nil
    }
    let applied = Set(completion.apply.keys)
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
    if !outcome.blockedKeys.isEmpty {
      let names = outcome.blockedKeys.sorted().joined(separator: ", ")
      parts.append("Not syncing until repaired (unreadable in iCloud): \(names).")
    }
    if !outcome.backedUpAs.isEmpty {
      parts.append("Previous copies are saved next to settings.json as settings.backup-*.json.")
    }
    if !outcome.repairedKeys.isEmpty {
      let names = outcome.repairedKeys.sorted().joined(separator: ", ")
      parts.append("Repaired: \(names).")
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

  static let exhaustedMessage = "iCloud sync is blocked at the counter limit. Turn sync off, "
    + "then on and choose Replace iCloud with This Mac's Settings. If the iCloud file itself "
    + "is at the limit, restore an earlier backup before replacing it."

  private func readLocalValues() -> SettingsSyncEngine.Values {
    var values: SettingsSyncEngine.Values = [:]
    for key in keys {
      values[key] = .some(SettingsSyncValue.read(key, from: defaults))
    }
    return values
  }

  /// Stamps every synced setting that changed since the last sync (resets included) with a new
  /// version at the moment it is seen, and persists it at once. Runs on every defaults change
  /// notification (cheap: hashes ~70 small values).
  func noteLocalChanges() {
    guard isEnabled else { return }
    if engine.noteLocalChanges(readLocalValues()) {
      saveEngine()
    }
  }

  /// True when any synced value differs from what this Mac last agreed with the cloud.
  func hasLocalChanges() -> Bool {
    engine.hasLocalChanges(readLocalValues())
  }

  /// The version of the pending (not yet uploaded) edit for a key, if any.
  func pendingVersion(for key: String) -> SettingsSyncVersion? {
    engine.pending[key]?.version
  }

  /// Wall time, whole milliseconds. Display-only.
  private func currentTime() -> Date {
    SettingsSyncDocument.date(millis: SettingsSyncDocument.millis(now()))
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
      || pendingFirstEnableMode != nil || !pendingRepairKeys.isEmpty
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

  private static func loadEngine(from defaults: UserDefaults) -> SettingsSyncEngine? {
    guard let data = defaults.data(forKey: SettingsSyncStateKey.localState) else { return nil }
    // Earlier formats fail to decode and are dropped: no users shipped with them.
    return try? JSONDecoder().decode(SettingsSyncEngine.self, from: data)
  }

  /// Persists the whole engine (agreed records, pending edits with their versions, counter).
  private func saveEngine() {
    guard let data = try? JSONEncoder().encode(engine) else { return }
    defaults.set(data, forKey: SettingsSyncStateKey.localState)
  }
}
