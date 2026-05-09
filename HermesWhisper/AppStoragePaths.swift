import Foundation

enum AppStoragePaths {
  static func appSupportRoot(fileManager: FileManager = .default) -> URL {
    let base: URL
    do {
      base = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    } catch {
      return URL(fileURLWithPath: "/tmp/\(AppConfig.appSupportDirectoryName)", isDirectory: true)
    }

    let root = base.appendingPathComponent(AppConfig.appSupportDirectoryName, isDirectory: true)
    migrateLegacySupportDirectoryIfNeeded(to: root, base: base, fileManager: fileManager)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func migrateLegacySupportDirectoryIfNeeded(
    to root: URL,
    base: URL,
    fileManager: FileManager
  ) {
    let legacyRoot = base.appendingPathComponent(
      AppConfig.legacyAppSupportDirectoryName,
      isDirectory: true
    )

    guard !fileManager.fileExists(atPath: root.path),
          fileManager.fileExists(atPath: legacyRoot.path) else {
      return
    }

    try? fileManager.copyItem(at: legacyRoot, to: root)
  }
}
