import Foundation

/// Marks work that originates from applying settings received through iCloud sync.
///
/// When a received batch is applied, view-model `didSet`s run synchronously and also schedule
/// deferred `Task` hops that persist (possibly derived) values. Those writes are not user edits
/// and must never be stamped as genuine local edits.
///
/// The marker is a task-local value attached to the apply operation itself: it is inherited by
/// every `Task` the apply creates (the deferred hops, however long they are delayed) and by
/// nothing else, so UI actions and other genuine edits never carry it. There is no time window.
/// Long-lived workers that a `didSet` may (re)start, such as response monitors, are created
/// through `withoutRemoteApply` so their own later writes count as this Mac's.
enum SettingsSyncProvenance {
  @TaskLocal static var isRemoteApply = false

  static func applyingRemoteSettings<T>(_ body: () throws -> T) rethrows -> T {
    try $isRemoteApply.withValue(true) {
      try body()
    }
  }

  /// Runs `body` (typically creating a long-lived `Task`) without remote-apply provenance.
  static func withoutRemoteApply<T>(_ body: () throws -> T) rethrows -> T {
    try $isRemoteApply.withValue(false) {
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
  /// The suppression rule: a write to a synced key made with remote-apply provenance.
  static func suppresses(_ key: String) -> Bool {
    SettingsSyncProvenance.isRemoteApply && SettingsSyncRegistry.isSynced(key)
  }

  private func suppressed(_ key: String) -> Bool {
    Self.suppresses(key)
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
