import Foundation
import Testing
@testable import WonderWhisper

/// The Bark Clean default: new installs get it, existing installs keep their model (including a
/// never-set `parakeet.version`, which used to mean Unified) and see the note once.
struct ParakeetModelDefaultsTests {
  private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "ww-parakeet-defaults-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  private func selection(_ defaults: UserDefaults) -> ParakeetModelKind {
    ParakeetModelKind(storedValue: defaults.string(forKey: ParakeetModelKind.defaultsKey))
  }

  @Test func newInstallGetsBarkCleanWithoutTheNote() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: false) == .newInstall)
    #expect(defaults.string(forKey: ParakeetModelKind.defaultsKey) == nil)
    #expect(selection(defaults) == .barkClean)
    #expect(!ParakeetModelDefaults.isRecommendationPending(defaults: defaults))
  }

  @Test func existingInstallThatNeverPickedAModelKeepsUnified() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let outcome = ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true)
    #expect(outcome == .existingInstall(kept: .unified))
    #expect(defaults.string(forKey: ParakeetModelKind.defaultsKey) == "unified")
    #expect(selection(defaults) == .unified)
    #expect(ParakeetModelDefaults.isRecommendationPending(defaults: defaults))
  }

  @Test func existingExplicitSelectionsAreLeftAlone() {
    for (stored, kept) in [("unified", ParakeetModelKind.unified), ("ultra", .ultra), ("v3", .ultra),
                           ("v2", .unified), ("something-new", .unified)] {
      let (defaults, suite) = scratchDefaults()
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(stored, forKey: ParakeetModelKind.defaultsKey)
      let outcome = ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true)
      #expect(outcome == .existingInstall(kept: kept), "stored \(stored)")
      #expect(defaults.string(forKey: ParakeetModelKind.defaultsKey) == stored, "stored \(stored)")
      #expect(ParakeetModelDefaults.isRecommendationPending(defaults: defaults), "stored \(stored)")
    }
  }

  @Test func existingInstallAlreadyOnBarkCleanGetsNoNote() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("bark-clean", forKey: ParakeetModelKind.defaultsKey)
    #expect(ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true)
      == .existingInstall(kept: .barkClean))
    #expect(!ParakeetModelDefaults.isRecommendationPending(defaults: defaults))
  }

  @Test func runsOnlyOnceAndDismissalSticks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true)
    ParakeetModelDefaults.dismissRecommendation(defaults: defaults)
    // A later reset of the key (e.g. synced removal) is not re-pinned, and the note stays dismissed.
    defaults.removeObject(forKey: ParakeetModelKind.defaultsKey)
    #expect(ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true) == .alreadyMigrated)
    #expect(defaults.string(forKey: ParakeetModelKind.defaultsKey) == nil)
    #expect(!ParakeetModelDefaults.isRecommendationPending(defaults: defaults))
  }

  @Test func newInstallStaysNewOnLaterLaunches() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: false)
    // The second launch looks like an existing install, but the migration already ran.
    #expect(ParakeetModelDefaults.migrateIfNeeded(defaults: defaults, isExistingInstall: true) == .alreadyMigrated)
    #expect(selection(defaults) == .barkClean)
    #expect(!ParakeetModelDefaults.isRecommendationPending(defaults: defaults))
  }

  @Test func priorLaunchMeansTheDomainHoldsMoreThanTheMigrationsOwnKeys() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!ParakeetModelDefaults.hasPriorLaunch(defaults: defaults, bundleIdentifier: suite))
    defaults.set(true, forKey: ParakeetModelDefaults.migrationKey)
    defaults.set(true, forKey: ParakeetModelDefaults.recommendationPendingKey)
    #expect(!ParakeetModelDefaults.hasPriorLaunch(defaults: defaults, bundleIdentifier: suite))
    defaults.set(true, forKey: "SUHasLaunchedBefore")
    #expect(ParakeetModelDefaults.hasPriorLaunch(defaults: defaults, bundleIdentifier: suite))
  }
}
