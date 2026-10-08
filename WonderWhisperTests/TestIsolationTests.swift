import Foundation
import Testing
@testable import WonderWhisper

/// Guards the user's real data: under the test runner every store must resolve to a
/// process-specific scratch directory, and preference defaults must go to the scratch suite.
struct TestIsolationTests {
  private static func resolved(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  @Test func appSupportRootIsAProcessScratchDirectory() throws {
    let root = Self.resolved(AppStoragePaths.appSupportRoot())
    let real = Self.resolved(
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    )
    let scratch = try #require(AppConfig.testScratchApplicationSupport)

    #expect(!root.hasPrefix(real + "/"), "tests resolved the real Application Support: \(root)")
    #expect(root.hasPrefix(Self.resolved(scratch) + "/"))
    #expect(root.hasPrefix(Self.resolved(FileManager.default.temporaryDirectory) + "/"))
    #expect(root.contains("WonderWhisperTests-\(ProcessInfo.processInfo.processIdentifier)"))
    #expect(root.hasSuffix("/" + AppConfig.appSupportDirectoryName))
  }

  @Test func preferenceDefaultsAreTheScratchSuite() {
    #expect(AppConfig.isTestRun)
    #expect(AppConfig.defaults !== UserDefaults.standard)
  }

  /// Helpers that used to default to `.standard` now default to `AppConfig.defaults`.
  @Test func defaultedPreferenceHelpersUseTheScratchSuite() {
    let key = MeetingTriggerRule.defaultsKey
    let previous = AppConfig.defaults.object(forKey: key)
    defer { AppConfig.defaults.set(previous, forKey: key) }

    MeetingTriggerRule.save([])
    #expect(AppConfig.defaults.data(forKey: key) != nil)
    #expect(MeetingTriggerRule.load(defaults: AppConfig.defaults).isEmpty)
    #expect(MeetingTriggerRule.load().isEmpty)
  }
}
