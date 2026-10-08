import Foundation
import AppKit

/// Keeps the allowlisted preferences (`SettingsSyncRegistry`) in step across Macs through a
/// JSON file in iCloud Drive.
///
/// - Local edits are noticed through `UserDefaults.didChangeNotification` and uploaded after a
///   short debounce.
/// - Cloud edits are noticed through an `NSFilePresenter` on the folder plus a slow poll, then
///   merged per key (newest `modifiedAt` wins) and written into UserDefaults.
/// - No echo: a key only counts as changed when its value fingerprint differs from what this Mac
///   last agreed with the cloud, and that record is updated before a cloud value is applied.
///   Applying a cloud value therefore never schedules an upload of the same value.
@MainActor
final class SettingsSyncService: ObservableObject {
  // Sync's own state. Not synced (see `SettingsSyncRegistry.excluded`).
  static let enabledKey = "settingsSync.enabled"
  static let deviceIDKey = "settingsSync.deviceID"
  static let localStateKey = "settingsSync.localState"
  static let lastSyncedAtKey = "settingsSync.lastSyncedAt"

  enum FirstEnableChoice {
    /// Overwrite this Mac's synced settings with the ones already in iCloud.
    case useCloud
    /// Overwrite the iCloud copy with this Mac's settings.
    case replaceCloud
  }

  enum Mode {
    case normal
    case preferCloud
    case preferLocal
  }

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
  /// Non-error information worth showing once (e.g. an unreadable file was replaced).
  @Published private(set) var notice: String?
  /// True while the user must choose between the existing iCloud copy and this Mac's settings.
  @Published private(set) var isAwaitingFirstEnableChoice = false

  /// Called on the main actor with the keys whose values were replaced by newer cloud values,
  /// so live view models can re-read them.
  var onRemoteChangesApplied: ((Set<String>) -> Void)?

  let deviceID: String
  /// Number of files written by this instance; lets tests prove there is no echo.
  private(set) var writeCount = 0

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
  /// When each not-yet-uploaded local edit was first seen, keyed by setting, so an edit keeps
  /// its real time even if the upload happens later (debounce, offline, iCloud busy).
  private var pendingEdits: [String: SettingsSyncLocalRecord] = [:]
  private var started = false
  private var resyncRequested = false
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
    observesChanges: Bool = true,
    localDebounce: Duration = .seconds(2),
    remoteDebounce: Duration = .milliseconds(500),
    pollInterval: TimeInterval = 30
  ) {
    self.defaults = defaults
    self.store = SettingsSyncFileStore(directory: directory)
    self.iCloudRoot = iCloudRoot
    self.deviceName = deviceName
    self.now = now
    self.observesChanges = observesChanges
    self.localDebounce = localDebounce
    self.remoteDebounce = remoteDebounce
    self.pollInterval = pollInterval

    if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
      deviceID = stored
    } else {
      deviceID = UUID().uuidString
      defaults.set(deviceID, forKey: Self.deviceIDKey)
    }
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    isICloudAvailable = SettingsSyncFileStore.isICloudDriveAvailable(root: iCloudRoot)
    lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
    localState = Self.loadLocalState(from: defaults)
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

    switch await readCloud() {
    case .success(.document):
      isAwaitingFirstEnableChoice = true
    case .success(.missing):
      await enable(mode: .preferLocal)
    case .success(.downloading):
      lastError = "iCloud is still downloading the settings file. Try again in a moment."
    case .failure(SettingsSyncFileStore.StoreError.corrupt):
      await enable(mode: .preferLocal)
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
    isEnabled = true
    defaults.set(true, forKey: Self.enabledKey)
    localState = [:]
    pendingEdits = [:]
    saveLocalState()
    beginObserving()
    await sync(mode: mode)
  }

  private func disable() {
    isAwaitingFirstEnableChoice = false
    guard isEnabled else { return }
    isEnabled = false
    defaults.set(false, forKey: Self.enabledKey)
    // Forget what was agreed: turning sync back on asks again instead of guessing.
    localState = [:]
    pendingEdits = [:]
    saveLocalState()
    stopObserving()
    lastError = nil
    notice = nil
  }

  // MARK: - Sync

  private func sync(mode: Mode) async {
    guard isEnabled else { return }
    if isSyncing {
      resyncRequested = true
      return
    }
    isSyncing = true
    var nextMode = mode
    repeat {
      resyncRequested = false
      await performSync(mode: nextMode)
      nextMode = .normal
    } while resyncRequested && isEnabled
    isSyncing = false
  }

  private func performSync(mode: Mode) async {
    refreshAvailability()
    guard isICloudAvailable else {
      lastError = "iCloud Drive is off on this Mac, so settings aren't syncing."
      return
    }

    noteLocalChanges()
    let timestamp = currentTime()
    let snapshot = readLocalValues()

    var remote: SettingsSyncDocument?
    switch await readCloud() {
    case .success(.document(let document)):
      remote = document
    case .success(.missing):
      remote = nil
    case .success(.downloading):
      waitingForDownload = true
      notice = "Waiting for iCloud to download the settings file…"
      return
    case .failure(SettingsSyncFileStore.StoreError.corrupt):
      let store = self.store
      let stamp = timestamp
      let backup = await Task.detached { store.quarantineUnreadableFile(now: stamp) }.value
      notice = "The iCloud settings file was unreadable"
        + (backup.map { ", so it was moved to \($0)" } ?? "")
        + " and replaced with this Mac's settings."
      remote = nil
    case .failure(let error):
      lastError = error.localizedDescription
      return
    }
    waitingForDownload = false
    lastSeenModificationDate = store.modificationDate()

    let canWrite = (remote?.schemaVersion ?? 0) <= SettingsSyncDocument.currentSchemaVersion
    let local = localEntries(snapshot: snapshot, mode: mode, timestamp: timestamp)
    var result = SettingsSyncMerger.merge(local: local, remote: remote, deviceID: deviceID)

    // Apply newer cloud values. The agreed record is stored first, so the defaults change
    // notification this triggers finds nothing new to upload.
    var applied: Set<String> = []
    for key in result.applyLocally.keys.sorted() {
      guard let value = result.applyLocally[key] else { continue }
      let current = SettingsSyncValue.read(key, from: defaults)
      if current?.fingerprint != (snapshot[key] ?? nil)?.fingerprint {
        // Edited on this Mac while the file was being read; the edit is newer, keep it.
        continue
      }
      if let record = result.agreed[key] { localState[key] = record }
      SettingsSyncValue.write(value, key: key, to: defaults)
      applied.insert(key)
    }
    for (key, entry) in local where !result.applyLocally.keys.contains(key) {
      localState[key] = result.agreed[key] ?? SettingsSyncLocalRecord(
        fingerprint: entry.value?.fingerprint,
        modifiedAt: entry.modifiedAt
      )
    }
    saveLocalState()
    for key in local.keys {
      if pendingEdits[key]?.fingerprint == localState[key]?.fingerprint {
        pendingEdits[key] = nil
      }
    }

    if result.document.devices[deviceID] == nil { result.documentChanged = true }
    if result.documentChanged, canWrite {
      result.document.schemaVersion = SettingsSyncDocument.currentSchemaVersion
      result.document.devices[deviceID] = SettingsSyncDocument.Device(
        name: deviceName,
        lastWriteAt: timestamp
      )
      let store = self.store
      let document = result.document
      let presenter = self.presenter
      let writeResult: Result<Void, Error> = await Task.detached {
        Result { try store.write(document, presenter: presenter) }
      }.value
      if case .failure(let error) = writeResult {
        lastError = error.localizedDescription
        if !applied.isEmpty { onRemoteChangesApplied?(applied) }
        return
      }
      writeCount += 1
      lastSeenModificationDate = store.modificationDate()
    }

    lastSyncedAt = timestamp
    defaults.set(timestamp, forKey: Self.lastSyncedAtKey)
    deviceCount = result.document.devices.count
    lastError = canWrite ? nil
      : "iCloud settings were saved by a newer WonderWhisper. Update this Mac to sync changes."
    if !applied.isEmpty {
      onRemoteChangesApplied?(applied)
    }
  }

  private func readCloud() async -> Result<SettingsSyncFileStore.ReadResult, Error> {
    let store = self.store
    let presenter = self.presenter
    return await Task.detached {
      Result { try store.read(presenter: presenter) }
    }.value
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
      case .preferLocal:
        modifiedAt = timestamp
      case .preferCloud:
        modifiedAt = unknownAge
      case .normal:
        let fingerprint = value?.fingerprint
        if let record = localState[key] {
          if record.fingerprint == fingerprint {
            modifiedAt = record.modifiedAt
          } else if let edit = pendingEdits[key], edit.fingerprint == fingerprint {
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
  /// seen. Runs on every defaults change notification (cheap: hashes ~70 small values).
  func noteLocalChanges() {
    guard isEnabled else { return }
    let seenAt = currentTime()
    for key in SettingsSyncRegistry.syncedKeys {
      let fingerprint = SettingsSyncValue.read(key, from: defaults)?.fingerprint
      guard let record = localState[key], record.fingerprint != fingerprint else {
        pendingEdits[key] = nil
        continue
      }
      if pendingEdits[key]?.fingerprint != fingerprint {
        pendingEdits[key] = SettingsSyncLocalRecord(fingerprint: fingerprint, modifiedAt: seenAt)
      }
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

  /// Milliseconds precision, matching the file encoding, so timestamps round-trip exactly.
  private func currentTime() -> Date {
    let millis = (now().timeIntervalSince1970 * 1000).rounded(.down)
    return Date(timeIntervalSince1970: millis / 1000)
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
    guard let data = defaults.data(forKey: localStateKey) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return (try? decoder.decode([String: SettingsSyncLocalRecord].self, from: data)) ?? [:]
  }

  private func saveLocalState() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    guard let data = try? encoder.encode(localState) else { return }
    defaults.set(data, forKey: Self.localStateKey)
  }

  private static var isTestRun: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }
}
