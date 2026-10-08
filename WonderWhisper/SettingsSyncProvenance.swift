import Foundation

/// Marks work that originates from applying settings received through iCloud sync.
///
/// When a received batch is applied, view-model `didSet`s run synchronously and also schedule
/// deferred `Task` hops that persist (possibly derived) values. Those writes are not user edits
/// and must never be stamped as genuine local edits. The marker is a task-local value, so it is
/// inherited by every `Task` created while applying (the deferred hops) but not by unrelated
/// work such as UI actions. It expires after a short window so a long-lived task that happens
/// to be started during an apply doesn't carry it forever.
enum SettingsSyncProvenance {
  @TaskLocal static var remoteApplyUntil: Date?

  /// How long deferred hops spawned by an apply keep the marker.
  static let window: TimeInterval = 2

  static var isRemoteApply: Bool {
    guard let until = remoteApplyUntil else { return false }
    return Date() < until
  }

  static func applyingRemoteSettings<T>(_ body: () throws -> T) rethrows -> T {
    try $remoteApplyUntil.withValue(Date().addingTimeInterval(window)) {
      try body()
    }
  }
}

/// `AppConfig.defaults`: a normal `UserDefaults` that drops writes to synced keys made while
/// applying received settings (`SettingsSyncProvenance`). The sync service writes received
/// values itself, outside that scope; everything the view models then persist as a side effect
/// (the same value, a derived value, or a launch default after a reset) is suppressed, so it
/// can't turn into a local edit. Genuine edits made afterwards are written normally.
final class SyncProvenanceUserDefaults: UserDefaults {
  private func suppressed(_ key: String) -> Bool {
    SettingsSyncProvenance.isRemoteApply && SettingsSyncRegistry.isSynced(key)
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(value, forKey: defaultName)
  }

  override func removeObject(forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.removeObject(forKey: defaultName)
  }

  override func set(_ value: Bool, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(value, forKey: defaultName)
  }

  override func set(_ value: Int, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(value, forKey: defaultName)
  }

  override func set(_ value: Double, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(value, forKey: defaultName)
  }

  override func set(_ value: Float, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(value, forKey: defaultName)
  }

  override func set(_ url: URL?, forKey defaultName: String) {
    guard !suppressed(defaultName) else { return }
    super.set(url, forKey: defaultName)
  }
}
