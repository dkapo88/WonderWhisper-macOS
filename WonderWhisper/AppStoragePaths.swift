import Foundation

enum AppStoragePaths {
  static func appSupportRoot(fileManager: FileManager = .default) -> URL {
    if let scratch = AppConfig.testScratchApplicationSupport {
      // Unit tests: never the real ~/Library/Application Support/HermesWhisper, and no
      // migration from the real WonderWhisper folder either.
      let root = scratch.appendingPathComponent(
        AppConfig.appSupportDirectoryName,
        isDirectory: true
      )
      try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }
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
    migrateOriginalSupportDirectoryIfNeeded(to: root, base: base, fileManager: fileManager)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func migrateOriginalSupportDirectoryIfNeeded(
    to root: URL,
    base: URL,
    fileManager: FileManager
  ) {
    let originalRoot = base.appendingPathComponent(
      AppConfig.originalAppSupportDirectoryName,
      isDirectory: true
    )

    guard !fileManager.fileExists(atPath: root.path),
          fileManager.fileExists(atPath: originalRoot.path) else {
      return
    }

    try? fileManager.copyItem(at: originalRoot, to: root)
  }
}
