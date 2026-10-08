import Foundation
import AppKit

/// Keeps the allowlisted preferences (`SettingsSyncRegistry`) in step across Macs through a
/// JSON file in iCloud Drive.
///
/// - Local edits are noticed through `UserDefaults.didChangeNotification`, stamped right away
///   and uploaded after a short debounce.
/// - Cloud edits are noticed through an `NSFilePresenter` on the folder plus a slow poll, then
///   merged per key (newest `modifiedAt` wins) inside one coordinated file transaction.
/// - Timestamps come from a hybrid logical clock: never earlier than any timestamp this Mac has
///   seen, so an edit made after receiving another Mac's change always wins over it even if
///   that Mac's clock runs fast.
/// - No echo: a key only counts as changed when its value fingerprint differs from what this Mac
///   last agreed with the cloud, and that record is updated before a cloud value is applied.
/// - Turning sync off bumps a generation and cancels any in-flight transaction, so a sync that
///   was already running can neither apply nor write afterwards.
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
    /// "Replace iCloud": this Mac's values win, whatever the timestamps say.
    case preferLocal
    /// First enable when no file existed; stops and asks if one has appeared since.
    case initialUpload
  }

  /// Cloud timestamps further ahead of this Mac's wall clock than this are treated as clock
  /// skew: ignored for merging and never fed into the logical clock.
  static let maxClockSkew: TimeInterval = 24 * 60 * 60

  static let shared: SettingsSyncService = {
    if isTestRun {
      // Unit tests run inside the app host; never let the shared instance near real iCloud.
      let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("WonderWhisperSettingsSyncShared", isDirectory: true)
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
  /// Non-error information worth showing (an unreadable file was replaced, values rejected).
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
  /// When each not-yet-uploaded local edit was first seen (including removals, whose
  /// fingerprint is nil), so an edit keeps its real time even if the upload happens later.
  private var pendingEdits: [String: SettingsSyncLocalRecord] = [:]
  /// Hybrid logical clock: highest timestamp (ms) issued or observed.
  private var clockMillis: Int64
  private var generation = 0
  private var cancellation = SettingsSyncCancellation()
  private var started = false
  private var requestedMode: Mode?
  /// The first-enable choice (use iCloud / replace iCloud / initial upload) until a
  /// transaction actually succeeds. Persisted, so a download wait, an IO failure or a relaunch
  /// can't turn "Replace iCloud" into an ordinary merge with empty state.
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
    clockMillis = (defaults.object(forKey: SettingsSyncStateKey.clock) as? NSNumber)?
      .int64Value ?? 0
    localState = Self.loadLocalState(from: defaults)
    pendingFirstEnableMode = defaults.string(forKey: SettingsSyncStateKey.firstEnableMode)
      .flatMap(Mode.init(rawValue:))
    recoverClockIfSkewed()
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
    clockMillis = 0
    defaults.removeObject(forKey: SettingsSyncStateKey.clock)
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
    let timestamp = nextTimestamp()
    let snapshot = readLocalValues()
    let local = localEntries(snapshot: snapshot, mode: mode, timestamp: timestamp)
    var input = SettingsSyncFileStore.TransactionInput(
      local: local,
      deviceID: deviceID,
      deviceName: deviceName,
      timestamp: timestamp
    )
    input.authoritative = mode == .preferLocal
    input.requireNoDocument = mode == .initialUpload
    input.horizon = horizon()

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
    if !outcome.schemaTooNew { pendingFirstEnableMode = nil }
    waitingForDownload = false
    lastSeenModificationDate = store.modificationDate()
    if outcome.wrote { writeCount += 1 }

    let applied = applyCloudValues(result, local: local, snapshot: snapshot)

    if let backup = outcome.quarantinedAs {
      notice = "The iCloud settings file was unreadable, so it was moved to \(backup) "
        + "and replaced with this Mac's settings."
    } else if !outcome.futureKeys.isEmpty {
      let count = outcome.futureKeys.count
      notice = "Ignored \(count) setting\(count == 1 ? "" : "s") in iCloud dated more than a day "
        + "in the future. Another Mac's clock may be wrong."
    } else if !lastRejectedKeys.isEmpty {
      let count = lastRejectedKeys.count
      notice = "Ignored \(count) setting\(count == 1 ? "" : "s") from iCloud that this Mac "
        + "can't use; kept this Mac's value\(count == 1 ? "" : "s")."
    } else if notice?.hasPrefix("Waiting for iCloud") == true || outcome.wrote {
      notice = nil
    }

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
            modifiedAt: Date(timeIntervalSince1970: 0)
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
      localState[key] = result.agreed[key] ?? SettingsSyncLocalRecord(
        fingerprint: entry.value?.fingerprint,
        modifiedAt: entry.modifiedAt
      )
    }
    saveLocalState()
    for (key, edit) in pendingEdits {
      if let record = localState[key], record.fingerprint == edit.fingerprint {
        pendingEdits[key] = nil
      }
    }
    lastRejectedKeys = rejected
    // Advance the logical clock only from timestamps this Mac accepted for synced keys, and
    // never past the skew horizon (the transaction already set later entries aside).
    let limit = horizon()
    let accepted = result.agreed
      .filter { !rejected.contains($0.key) && $0.value.modifiedAt <= limit }
      .map { SettingsSyncDocument.millis($0.value.modifiedAt) }
    if let newest = accepted.max(), newest > clockMillis {
      clockMillis = newest
      defaults.set(NSNumber(value: clockMillis), forKey: SettingsSyncStateKey.clock)
    }
    return applied
  }

  private func localEntries(
    snapshot: [String: SettingsSyncValue?],
    mode: Mode,
    timestamp: Date
  ) -> [String: SettingsSyncMerger.LocalEntry] {
    let unknownAge = Date(timeIntervalSince1970: 0)
    var entries: [String: SettingsSyncMerger.LocalEntry] = [:]
    for key in SettingsSyncRegistry.syncedKeys {
      let value = snapshot[key] ?? nil
      let modifiedAt: Date
      switch mode {
      case .preferLocal, .initialUpload:
        modifiedAt = timestamp
      case .preferCloud:
        modifiedAt = unknownAge
      case .normal:
        let fingerprint = value?.fingerprint
        let limit = horizon()
        if let record = localState[key] {
          if record.fingerprint == fingerprint {
            // A record stamped by an earlier skewed clock must not win forever.
            modifiedAt = record.modifiedAt > limit ? unknownAge : record.modifiedAt
          } else if let edit = pendingEdits[key], edit.fingerprint == fingerprint,
                    edit.modifiedAt <= limit {
            modifiedAt = edit.modifiedAt
          } else {
            modifiedAt = timestamp
          }
        } else {
          modifiedAt = unknownAge
        }
      }
      entries[key] = SettingsSyncMerger.LocalEntry(value: value, modifiedAt: modifiedAt)
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

  /// Stamps synced settings that changed since the last sync with the time they were first
  /// seen, including removals. Runs on every defaults change notification (cheap: hashes ~70
  /// small values).
  func noteLocalChanges() {
    guard isEnabled else { return }
    var stamp: Date?
    for key in SettingsSyncRegistry.syncedKeys {
      guard let record = localState[key] else { continue }
      let fingerprint = SettingsSyncValue.read(key, from: defaults)?.fingerprint
      if record.fingerprint == fingerprint {
        pendingEdits[key] = nil
        continue
      }
      // A pending record with a nil fingerprint is a recorded removal, distinct from "none".
      if let pending = pendingEdits[key], pending.fingerprint == fingerprint { continue }
      let seenAt = stamp ?? nextTimestamp()
      stamp = seenAt
      pendingEdits[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, modifiedAt: seenAt)
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

  // MARK: - Clock

  /// Wall time, whole milliseconds. Used for display.
  private func currentTime() -> Date {
    SettingsSyncDocument.date(millis: SettingsSyncDocument.millis(now()))
  }

  /// Next edit timestamp: wall time, but always after anything already issued or observed.
  private func nextTimestamp() -> Date {
    recoverClockIfSkewed()
    let wall = SettingsSyncDocument.millis(now())
    clockMillis = max(wall, min(clockMillis, SettingsSyncDocument.maxMillis - 1) + 1)
    defaults.set(NSNumber(value: clockMillis), forKey: SettingsSyncStateKey.clock)
    return SettingsSyncDocument.date(millis: clockMillis)
  }

  /// Latest timestamp still trusted: wall time plus `maxClockSkew`.
  private func horizon() -> Date {
    now().addingTimeInterval(Self.maxClockSkew)
  }

  /// A clock persisted beyond the horizon (by an older build, or a once-fast clock) is reset
  /// to wall time instead of stamping every future edit far in the future.
  private func recoverClockIfSkewed() {
    guard clockMillis > SettingsSyncDocument.millis(horizon()) else { return }
    clockMillis = SettingsSyncDocument.millis(now())
    defaults.set(NSNumber(value: clockMillis), forKey: SettingsSyncStateKey.clock)
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

  private func scheduleRemoteCheck(force: Bool) {
    guard isEnabled else { return }
    remoteDebounceTask?.cancel()
    let delay = remoteDebounce
    remoteDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      let modified = self.store.modificationDate()
      let changed = modified != self.lastSeenModificationDate
      guard force || changed || self.waitingForDownload || self.lastError != nil else { return }
      await self.syncNow()
    }
  }

  // MARK: - Persistence of sync state

  private static func loadLocalState(
    from defaults: UserDefaults
  ) -> [String: SettingsSyncLocalRecord] {
    guard let data = defaults.data(forKey: SettingsSyncStateKey.localState) else { return [:] }
    let decoder = SettingsSyncDocument.makeDecoder()
    return (try? decoder.decode([String: SettingsSyncLocalRecord].self, from: data)) ?? [:]
  }

  private func saveLocalState() {
    guard let data = try? SettingsSyncDocument.makeEncoder().encode(localState) else { return }
    defaults.set(data, forKey: SettingsSyncStateKey.localState)
  }

  private static var isTestRun: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }
}
