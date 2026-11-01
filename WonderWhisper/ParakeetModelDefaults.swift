import Foundation

/// One-time launch migration for the Bark Clean default.
///
/// An unset `parakeet.version` now resolves to Bark Clean (`ParakeetModelKind.newInstallDefault`).
/// Existing installs must keep the model they were using, including those that never touched the
/// picker and ran the old unset default (Unified). On the first launch of this version, an
/// existing install gets that old default pinned in `pinnedDefaultKey`, and is flagged to show a
/// one-time "new recommended model" note in Settings. New installs pin nothing.
///
/// The pin never writes `parakeet.version` itself: that key syncs through iCloud, and a launch-time
/// write would count as a new edit there and could replace another Mac's real choice. A value the
/// user picks, here or on another Mac, always wins over the pin.
enum ParakeetModelDefaults {
  /// Set once the migration has run on this Mac (any outcome).
  static let migrationKey = "parakeet.barkCleanDefault.migrated"
  /// True while the Settings note recommending Bark Clean should show.
  static let recommendationPendingKey = "parakeet.barkCleanRecommendation.pending"
  /// What an unset `parakeet.version` means on an existing install. Not synced.
  static let pinnedDefaultKey = "parakeet.unsetDefault"

  enum Outcome: Equatable {
    /// Already ran on an earlier launch.
    case alreadyMigrated
    /// First launch of a new install: Bark Clean by default, no note.
    case newInstall
    /// Existing install: kept (or pinned) its model and will see the note.
    case existingInstall(kept: ParakeetModelKind)
  }

  /// Runs the migration once. `isExistingInstall` says whether this Mac ran an earlier version
  /// (see `hasPriorLaunch(defaults:bundleIdentifier:)`).
  @discardableResult
  static func migrateIfNeeded(defaults: UserDefaults, isExistingInstall: Bool) -> Outcome {
    guard !defaults.bool(forKey: migrationKey) else { return .alreadyMigrated }
    defer { defaults.set(true, forKey: migrationKey) }
    guard isExistingInstall else { return .newInstall }
    // Pin what the old version resolved an unset key to, whether or not it is set right now.
    defaults.set(ParakeetModelKind.legacyDefault.rawValue, forKey: pinnedDefaultKey)
    let kept = ParakeetModelKind.resolved(
      stored: defaults.string(forKey: ParakeetModelKind.defaultsKey), defaults: defaults
    )
    if kept != .barkClean {
      defaults.set(true, forKey: recommendationPendingKey)
    }
    return .existingInstall(kept: kept)
  }

  /// Whether an earlier version ran on this Mac: the app's own preferences domain already holds
  /// something other than this migration's keys. Every earlier version writes to it on first
  /// launch (window and status-item state, Sparkle, settings), and nothing has written to it yet
  /// this launch when the migration runs from `WonderWhisperApp.init`.
  static func hasPriorLaunch(defaults: UserDefaults, bundleIdentifier: String) -> Bool {
    let ownKeys: Set<String> = [migrationKey, recommendationPendingKey, pinnedDefaultKey]
    let domain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    return domain.keys.contains { !ownKeys.contains($0) }
  }

  /// Launch entry point. Skipped under the test runner, whose defaults are a scratch suite.
  static func migrateAtLaunch() {
    guard !AppConfig.isTestRun else { return }
    let defaults = AppConfig.defaults
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppConfig.bundleIdentifier
    let outcome = migrateIfNeeded(
      defaults: defaults,
      isExistingInstall: hasPriorLaunch(defaults: defaults, bundleIdentifier: bundleIdentifier)
    )
    if outcome != .alreadyMigrated {
      AppLog.dictation.log("[Parakeet] default model migration: \(String(describing: outcome))")
    }
  }

  /// The pinned default for an unset `parakeet.version`, or nil on a new install.
  static func pinnedDefault(defaults: UserDefaults = AppConfig.defaults) -> String? {
    defaults.string(forKey: pinnedDefaultKey)
  }

  static func isRecommendationPending(defaults: UserDefaults = AppConfig.defaults) -> Bool {
    defaults.bool(forKey: recommendationPendingKey)
  }

  static func dismissRecommendation(defaults: UserDefaults = AppConfig.defaults) {
    defaults.set(false, forKey: recommendationPendingKey)
  }
}
