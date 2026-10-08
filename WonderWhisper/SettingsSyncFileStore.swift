import Foundation

/// Reads and writes `settings.json` in a folder of iCloud Drive with `NSFileCoordinator`.
///
/// The app is unsandboxed and Developer ID signed, so it uses iCloud Drive as a plain folder
/// (`~/Library/Mobile Documents/com~apple~CloudDocs/WonderWhisper/`) instead of an iCloud
/// container, which would need an iCloud entitlement and provisioning profile. All methods
/// block on file IO and must run off the main thread.
struct SettingsSyncFileStore: Sendable {
  static let folderName = "WonderWhisper"
  static let fileName = "settings.json"

  enum ReadResult: Equatable, Sendable {
    case missing
    /// The file exists only as an evicted iCloud placeholder; a download was requested.
    case downloading
    case document(SettingsSyncDocument)
  }

  enum StoreError: LocalizedError, Equatable, Sendable {
    /// The file is there but is not a settings document this app can parse.
    case corrupt
    /// Reading failed for an IO reason that may be transient; the file is left alone.
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
      switch self {
      case .corrupt: return "The iCloud settings file is not valid settings JSON."
      case .readFailed(let detail): return "Couldn't read the iCloud settings file (\(detail))."
      case .writeFailed(let detail): return "Couldn't save to iCloud Drive (\(detail))."
      }
    }
  }

  /// Everything one sync needs to merge, prepared on the main actor.
  struct TransactionInput: Sendable {
    var local: [String: SettingsSyncMerger.LocalEntry]
    var deviceID: String
    var deviceName: String
    var timestamp: Date
    /// "Replace iCloud with this Mac's settings".
    var authoritative = false
    /// First upload after the user saw no file: if a document has appeared since, stop so
    /// the user can be asked which copy to keep instead of silently merging.
    var requireNoDocument = false
  }

  struct TransactionOutcome: Sendable {
    /// Nil when the transaction stopped early (cancelled or a document appeared).
    var merge: SettingsSyncMerger.Result?
    /// The cloud document as found (after folding in conflict versions), before merging.
    var observed: SettingsSyncDocument?
    var wrote = false
    var schemaTooNew = false
    var documentAppeared = false
    var cancelled = false
    var quarantinedAs: String?
    var resolvedConflicts = 0
  }

  let directory: URL
  let conflicts: SettingsSyncConflictSource

  init(directory: URL, conflicts: SettingsSyncConflictSource = .fileVersions) {
    self.directory = directory
    self.conflicts = conflicts
  }

  var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

  /// Legacy iCloud eviction stub (`.settings.json.icloud`) left in place of a removed file.
  var placeholderURL: URL {
    directory.appendingPathComponent(".\(Self.fileName).icloud", isDirectory: false)
  }

  /// `~/Library/Mobile Documents/com~apple~CloudDocs`, the user's iCloud Drive root.
  static var iCloudDriveRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
  }

  static func isICloudDriveAvailable(root: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// Modification date without reading the file; used by the poll to skip unchanged files.
  func modificationDate() -> Date? {
    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate
  }

  /// Returns `.downloading` (and asks iCloud to fetch the file) when only a placeholder is
  /// on disk; nil when the file is local or absent.
  func requestDownloadIfNeeded() -> ReadResult? {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: fileURL.path) {
      guard fileManager.fileExists(atPath: placeholderURL.path) else { return nil }
      try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
      return .downloading
    }
    let status = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    if status?.ubiquitousItemDownloadingStatus == .notDownloaded {
      try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
      return .downloading
    }
    return nil
  }

  /// Read-only peek, used to decide whether to ask the user on first enable.
  func read(presenter: SettingsSyncFilePresenter? = nil) throws -> ReadResult {
    if let pending = requestDownloadIfNeeded() { return pending }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

    var coordinationError: NSError?
    var readError: Error?
    var data: Data?
    NSFileCoordinator(filePresenter: presenter).coordinate(
      readingItemAt: fileURL,
      options: [],
      error: &coordinationError
    ) { url in
      do {
        data = try Data(contentsOf: url)
      } catch {
        readError = error
      }
    }
    if let error = coordinationError ?? readError {
      if !FileManager.default.fileExists(atPath: fileURL.path) { return .missing }
      throw StoreError.readFailed(error.localizedDescription)
    }
    guard let data else { return .missing }
    do {
      return .document(try SettingsSyncDocument.decode(data))
    } catch {
      throw StoreError.corrupt
    }
  }

  /// Reads, merges and writes inside ONE coordinated write, so a copy iCloud installs between
  /// a read and a write can't be overwritten by a stale merge. Inside the same transaction:
  /// unresolved iCloud conflict versions are folded in per key (and marked resolved only after
  /// the merged file is saved), a newer-schema file is never written, and a file is only
  /// moved aside as unreadable if it is still unreadable here.
  func transact(
    _ input: TransactionInput,
    cancellation: SettingsSyncCancellation,
    presenter: SettingsSyncFilePresenter? = nil
  ) throws -> TransactionOutcome {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }

    var outcome = TransactionOutcome()
    var failure: Error?
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: presenter).coordinate(
      writingItemAt: fileURL,
      options: .forMerging,
      error: &coordinationError
    ) { url in
      do {
        outcome = try runTransaction(input, at: url, cancellation: cancellation)
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    if let coordinationError {
      throw StoreError.writeFailed(coordinationError.localizedDescription)
    }
    return outcome
  }

  private func runTransaction(
    _ input: TransactionInput,
    at url: URL,
    cancellation: SettingsSyncCancellation
  ) throws -> TransactionOutcome {
    var outcome = TransactionOutcome()
    guard !cancellation.isCancelled else {
      outcome.cancelled = true
      return outcome
    }

    var remote: SettingsSyncDocument?
    var unreadable: Data?
    if FileManager.default.fileExists(atPath: url.path) {
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw StoreError.readFailed(error.localizedDescription)
      }
      do {
        remote = try SettingsSyncDocument.decode(data)
      } catch {
        unreadable = data
      }
    }

    let conflictVersions = conflicts.unresolved(url)
    for version in conflictVersions {
      guard let data = version.data,
            let document = try? SettingsSyncDocument.decode(data) else { continue }
      remote = remote.map { SettingsSyncMerger.combine($0, document) } ?? document
    }

    if input.requireNoDocument, remote != nil {
      outcome.documentAppeared = true
      return outcome
    }
    outcome.observed = remote
    outcome.schemaTooNew = (remote?.schemaVersion ?? 0) > SettingsSyncDocument.currentSchemaVersion

    var result = SettingsSyncMerger.merge(
      local: input.local,
      remote: remote,
      deviceID: input.deviceID,
      authoritative: input.authoritative
    )
    if result.document.devices[input.deviceID] == nil
      || !conflictVersions.isEmpty
      || unreadable != nil {
      result.documentChanged = true
    }

    guard result.documentChanged, !outcome.schemaTooNew else {
      result.documentChanged = false
      outcome.merge = result
      return outcome
    }
    guard !cancellation.isCancelled else {
      outcome.cancelled = true
      return outcome
    }

    result.document.schemaVersion = SettingsSyncDocument.currentSchemaVersion
    result.document.devices[input.deviceID] = SettingsSyncDocument.Device(
      name: input.deviceName,
      lastWriteAt: input.timestamp
    )
    let encoded: Data
    do {
      encoded = try result.document.encoded()
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }
    if let unreadable {
      let stamp = Int(input.timestamp.timeIntervalSince1970)
      let backup = directory.appendingPathComponent("settings.unreadable-\(stamp).json")
      if (try? unreadable.write(to: backup, options: .atomic)) != nil {
        outcome.quarantinedAs = backup.lastPathComponent
      }
    }
    do {
      try encoded.write(to: url, options: .atomic)
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }
    outcome.wrote = true
    if !conflictVersions.isEmpty {
      conflictVersions.forEach { $0.resolve() }
      conflicts.finish(url)
      outcome.resolvedConflicts = conflictVersions.count
    }
    outcome.merge = result
    return outcome
  }
}

/// Where unresolved iCloud conflict versions come from. Production uses `NSFileVersion`;
/// tests inject fakes because real conflict versions can't be created outside iCloud.
struct SettingsSyncConflictSource: Sendable {
  struct Version: Sendable {
    let data: Data?
    let resolve: @Sendable () -> Void
  }

  let unresolved: @Sendable (URL) -> [Version]
  /// Called once after every listed version was resolved and the merged file saved.
  let finish: @Sendable (URL) -> Void

  static let fileVersions = SettingsSyncConflictSource(
    unresolved: { url in
      let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
      return versions.map { version in
        let box = FileVersionBox(version)
        return Version(
          data: try? Data(contentsOf: version.url),
          resolve: { box.version.isResolved = true }
        )
      }
    },
    finish: { url in
      try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
  )

  static let none = SettingsSyncConflictSource(unresolved: { _ in [] }, finish: { _ in })
}

/// `NSFileVersion` is not Sendable; it is only touched inside the coordinated transaction on
/// the thread that created it.
private final class FileVersionBox: @unchecked Sendable {
  let version: NSFileVersion

  init(_ version: NSFileVersion) {
    self.version = version
  }
}

/// Set when sync is turned off; an in-flight transaction checks it before merging and again
/// right before writing.
final class SettingsSyncCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
