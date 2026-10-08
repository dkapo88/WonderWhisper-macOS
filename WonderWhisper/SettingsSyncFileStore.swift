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

  enum ReadResult: Equatable {
    case missing
    /// The file exists only as an evicted iCloud placeholder; a download was requested.
    case downloading
    case document(SettingsSyncDocument)
  }

  enum StoreError: LocalizedError, Equatable {
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

  let directory: URL

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

  func read(presenter: NSFilePresenter? = nil) throws -> ReadResult {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: fileURL.path) {
      if fileManager.fileExists(atPath: placeholderURL.path) {
        try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
        return .downloading
      }
      return .missing
    }

    let status = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    if status?.ubiquitousItemDownloadingStatus == .notDownloaded {
      try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
      return .downloading
    }

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
      if !fileManager.fileExists(atPath: fileURL.path) { return .missing }
      throw StoreError.readFailed(error.localizedDescription)
    }
    guard let data else { return .missing }
    do {
      return .document(try SettingsSyncDocument.decode(data))
    } catch {
      throw StoreError.corrupt
    }
  }

  func write(_ document: SettingsSyncDocument, presenter: NSFilePresenter? = nil) throws {
    let data: Data
    do {
      data = try document.encoded()
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw StoreError.writeFailed(error.localizedDescription)
    }
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: presenter).coordinate(
      writingItemAt: fileURL,
      options: .forReplacing,
      error: &coordinationError
    ) { url in
      do {
        try data.write(to: url, options: .atomic)
      } catch {
        writeError = error
      }
    }
    if let error = coordinationError ?? writeError {
      throw StoreError.writeFailed(error.localizedDescription)
    }
  }

  /// Moves an unreadable file aside (kept for inspection) so a fresh one can replace it.
  /// Returns the backup name.
  @discardableResult
  func quarantineUnreadableFile(now: Date) -> String? {
    let stamp = Int(now.timeIntervalSince1970)
    let backup = directory.appendingPathComponent("settings.unreadable-\(stamp).json")
    var coordinationError: NSError?
    var moved = false
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: fileURL,
      options: .forMoving,
      writingItemAt: backup,
      options: .forReplacing,
      error: &coordinationError
    ) { source, destination in
      moved = (try? FileManager.default.moveItem(at: source, to: destination)) != nil
    }
    return moved ? backup.lastPathComponent : nil
  }
}
