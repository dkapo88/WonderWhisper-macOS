import Foundation

/// Watches the iCloud Drive settings folder and reports when `settings.json` changes there,
/// including when iCloud downloads a newer copy written by another Mac.
final class SettingsSyncFilePresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "SettingsSyncFilePresenter"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private let fileName: String
  private let onChange: @Sendable () -> Void

  init(directory: URL, fileName: String, onChange: @escaping @Sendable () -> Void) {
    presentedItemURL = directory
    self.fileName = fileName
    self.onChange = onChange
    super.init()
  }

  func presentedSubitemDidChange(at url: URL) {
    guard url.lastPathComponent == fileName
      || url.lastPathComponent == ".\(fileName).icloud" else { return }
    onChange()
  }

  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
    if newURL.lastPathComponent == fileName { onChange() }
  }

  func presentedItemDidChange() {
    onChange()
  }
}
