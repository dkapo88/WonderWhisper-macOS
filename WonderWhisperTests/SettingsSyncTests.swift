import Foundation
import Testing
@testable import WonderWhisper

/// iCloud settings sync, run entirely against temp folders and throwaway UserDefaults suites.
/// Nothing here touches the real iCloud Drive folder or the user's preferences.
/// Serialized: the live-apply tests share the scratch `AppConfig.defaults` keys.
@Suite(.serialized)
@MainActor
struct SettingsSyncTests {
  /// Two simulated Macs sharing one temp "iCloud Drive".
  @MainActor
  private final class Harness {
    let root: URL
    let folder: URL
    var suites: [String] = []
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SettingsSyncTests-\(UUID().uuidString)", isDirectory: true)
      folder = root.appendingPathComponent("WonderWhisper", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDefaults() throws -> UserDefaults {
      let name = "ww.settingsSync.tests.\(UUID().uuidString)"
      suites.append(name)
      return try #require(UserDefaults(suiteName: name))
    }

    /// - Parameter clockOffset: how far this Mac's wall clock is ahead of the shared clock
    ///   (display-only under the Lamport ordering; used to prove skew can't change a winner).
    func makeService(
      _ defaults: UserDefaults,
      name: String,
      clockOffset: TimeInterval = 0,
      conflicts: SettingsSyncConflictSource = .none
    ) -> SettingsSyncService {
      SettingsSyncService(
        defaults: defaults,
        directory: folder,
        iCloudRoot: root,
        deviceName: name,
        now: { [unowned self] in self.clock.addingTimeInterval(clockOffset) },
        conflicts: conflicts,
        observesChanges: false
      )
    }

    func tick(_ seconds: TimeInterval = 5) {
      clock = clock.addingTimeInterval(seconds)
    }

    var fileURL: URL { folder.appendingPathComponent("settings.json") }

    func readDocument() throws -> SettingsSyncDocument {
      try SettingsSyncDocument.decode(Data(contentsOf: fileURL))
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
      for suite in suites {
        UserDefaults().removePersistentDomain(forName: suite)
      }
    }
  }

  /// A valid value for every allowlisted key, built from its declared expectation, so every
  /// plist type is exercised and every received value passes validation.
  private static func sampleValue(for key: String, index: Int) throws -> SettingsSyncValue {
    let expectation = try #require(SettingsSyncRegistry.expectations[key])
    switch expectation {
    case .bool: return .bool(index % 2 == 0)
    case .string: return .string("value-\(key)")
    case .oneOf(let allowed): return .string(try #require(allowed.sorted().last))
    case .int(let range): return .int(min(range.lowerBound + 7, range.upperBound))
    case .double(let range): return .double((range.lowerBound + range.upperBound) / 2)
    case .strings: return .strings(["a-\(index)", "b-\(key)"])
    case .json(let shape): return .data(try sampleJSON(shape))
    }
  }

  private static func sampleJSON(_ shape: SettingsSyncRegistry.JSONShape) throws -> Data {
    let encoder = JSONEncoder()
    switch shape {
    case .promptSettings:
      var settings = SimpleModeDefaults.settings(for: .command)
      settings.header = "Synced header"
      return try encoder.encode(settings)
    case .promptTemplates:
      return try encoder.encode([
        SimplePromptTemplate(name: "Synced", rules: "Be brief", footer: "")
      ])
    case .favoriteModels:
      return try encoder.encode([FavoriteOpenRouterModel(id: "x/y", name: "X · Y")])
    case .beeperChats:
      return try encoder.encode([BeeperChatEntry(chatID: "!chat", alias: "Team")])
    case .meetingTriggerRules:
      return try encoder.encode(Array(MeetingTriggerRule.defaultRules.prefix(1)))
    }
  }

  // MARK: - Round trip

  @Test func everyAllowlistedKeyRoundTripsToAnotherMac() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    let keys = SettingsSyncRegistry.synced.map(\.key)
    var samples: [String: SettingsSyncValue] = [:]
    for (index, key) in keys.enumerated() {
      let value = try Self.sampleValue(for: key, index: index)
      samples[key] = value
      SettingsSyncValue.write(value, key: key, to: defaultsA)
    }

    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    #expect(macA.isEnabled)
    #expect(!macA.isAwaitingFirstEnableChoice)

    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    var appliedOnB: Set<String> = []
    macB.onRemoteChangesApplied = { appliedOnB.formUnion($0) }
    await macB.setEnabled(true)
    #expect(macB.isAwaitingFirstEnableChoice)
    await macB.resolveFirstEnable(.useCloud)

    for key in keys {
      let received = SettingsSyncValue.read(key, from: defaultsB)
      #expect(received == samples[key], "\(key) did not round-trip")
    }
    #expect(appliedOnB == Set(keys))
    #expect(macB.deviceCount == 2)
    #expect(macB.lastError == nil)
  }

  @Test func valueCodingRoundTripsEveryType() throws {
    let values: [SettingsSyncValue] = [
      .bool(true), .int(42), .double(0.2), .string("héllo"), .strings(["x", "y"]),
      .data(Data([0, 1, 2, 255]))
    ]
    for value in values {
      let data = try JSONEncoder().encode(value)
      #expect(try JSONDecoder().decode(SettingsSyncValue.self, from: data) == value)
    }
  }

  @Test func jsonBlobFingerprintIgnoresKeyOrder() {
    let first = SettingsSyncValue.data(Data(#"{"a":1,"b":[true,"x"]}"#.utf8))
    let second = SettingsSyncValue.data(Data(#"{"b":[true,"x"],"a":1}"#.utf8))
    #expect(first.fingerprint == second.fingerprint)
    #expect(SettingsSyncValue.bool(true).fingerprint != SettingsSyncValue.int(1).fingerprint)
  }

  // MARK: - Exclusions

  @Test func registryNeverListsSecretsOrExcludedKeys() {
    #expect(SettingsSyncRegistry.syncedKeys.count == SettingsSyncRegistry.synced.count)
    #expect(SettingsSyncRegistry.syncedKeys.isDisjoint(with: SettingsSyncRegistry.excluded.keys))
    let secretAliases = [
      AppConfig.groqAPIKeyAlias, AppConfig.openrouterAPIKeyAlias,
      AppConfig.vercelGatewayAPIKeyAlias, AppConfig.xaiAPIKeyAlias, AppConfig.sonioxAPIKeyAlias,
      AppConfig.hermesAPIKeyAlias, AppConfig.beeperAccessTokenAlias
    ]
    for key in SettingsSyncRegistry.syncedKeys {
      #expect(!secretAliases.contains(key))
      let lowered = key.lowercased()
      #expect(!lowered.contains("apikey") && !lowered.contains("api_key"))
      #expect(!lowered.contains("token") && !lowered.contains("secret"))
      #expect(!lowered.hasPrefix("settingssync."))
    }
  }

  @Test func excludedKeysAndSecretsNeverReachTheFile() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("Luis, Xinyi", forKey: "vocab.custom")
    for key in SettingsSyncRegistry.excluded.keys where !key.hasPrefix("settingsSync.") {
      defaults.set("local-only-\(key)", forKey: key)
    }
    // Even if a secret were ever mirrored into defaults by mistake, sync must not pick it up.
    defaults.set("sk-or-v1-SECRET", forKey: AppConfig.openrouterAPIKeyAlias)
    defaults.set("gsk_SECRET", forKey: AppConfig.groqAPIKeyAlias)

    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    let raw = try String(contentsOf: harness.fileURL, encoding: .utf8)
    #expect(!raw.contains("SECRET"))
    #expect(!raw.contains("local-only-"))
    let document = try harness.readDocument()
    #expect(Set(document.entries.keys).isSubset(of: SettingsSyncRegistry.syncedKeys))
    #expect(document.entries["vocab.custom"]?.value == .string("Luis, Xinyi"))
    for key in SettingsSyncRegistry.excluded.keys {
      #expect(document.entries[key] == nil)
    }
  }

  // MARK: - Merge

  @Test func newerEditWinsPerKeyAndUntouchedKeysSurvive() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("one", forKey: "vocab.custom")
    defaultsA.set("en", forKey: "transcription.language")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)

    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)

    // A edits vocabulary and language and syncs. B receives that, then edits vocabulary
    // again (causally later, so it must win), while A's language edit must survive.
    // In the app the defaults change notification calls `noteLocalChanges()` at edit time.
    defaultsA.set("from A", forKey: "vocab.custom")
    defaultsA.set("fr", forKey: "transcription.language")
    macA.noteLocalChanges()
    await macA.syncNow()
    await macB.syncNow()
    #expect(defaultsB.string(forKey: "vocab.custom") == "from A")

    defaultsB.set("from B", forKey: "vocab.custom")
    macB.noteLocalChanges()
    await macB.syncNow()
    await macA.syncNow()

    #expect(defaultsA.string(forKey: "vocab.custom") == "from B")
    #expect(defaultsB.string(forKey: "vocab.custom") == "from B")
    #expect(defaultsA.string(forKey: "transcription.language") == "fr")
    #expect(defaultsB.string(forKey: "transcription.language") == "fr")
  }

  @Test func resetToDefaultPropagatesAsRemoval() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("backslash", forKey: "hermes.shortcut.selection")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    #expect(defaultsB.string(forKey: "hermes.shortcut.selection") == "backslash")

    harness.tick()
    defaultsA.removeObject(forKey: "hermes.shortcut.selection")
    await macA.syncNow()
    await macB.syncNow()
    #expect(defaultsB.object(forKey: "hermes.shortcut.selection") == nil)
  }

  @Test func mergerBreaksExactTiesTheSameWayOnEveryMac() {
    let remote = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("remote"), counter: 100, deviceID: "AAAA")
    ])
    func merge(_ writer: String) -> SettingsSyncMerger.Result {
      SettingsSyncMerger.merge(
        local: ["vocab.custom": .init(value: .string("local"),
                                      version: SettingsSyncVersion(100, writer))],
        remote: remote,
        deviceID: writer,
        localVersion: SettingsSyncVersion(100, writer)
      )
    }
    let higher = merge("ZZZZ")
    #expect(higher.documentChanged)
    #expect(higher.applyLocally.isEmpty)
    let lower = merge("0000")
    #expect(!lower.documentChanged)
    #expect(lower.applyLocally["vocab.custom"] == .some(.string("remote")))
  }

  // MARK: - No echo

  @Test func applyingRemoteChangesNeverTriggersAnUpload() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("Luis", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    await macA.syncNow()  // A learns about B's device entry.

    harness.tick()
    defaultsA.set("Luis, Xinyi", forKey: "vocab.custom")
    #expect(macA.hasLocalChanges())
    await macA.syncNow()
    #expect(!macA.hasLocalChanges())

    var applyCount = 0
    macB.onRemoteChangesApplied = { _ in applyCount += 1 }
    let writesBefore = macB.writeCount
    harness.tick()
    await macB.syncNow()
    #expect(defaultsB.string(forKey: "vocab.custom") == "Luis, Xinyi")
    #expect(applyCount == 1)
    #expect(macB.writeCount == writesBefore, "applying a cloud value must not re-upload it")
    #expect(!macB.hasLocalChanges(), "applied cloud values must not look like local edits")

    let fileBefore = try Data(contentsOf: harness.fileURL)
    let writesA = macA.writeCount
    for _ in 0..<3 {
      harness.tick()
      await macB.syncNow()
      await macA.syncNow()
    }
    #expect(try Data(contentsOf: harness.fileURL) == fileBefore)
    #expect(macB.writeCount == writesBefore)
    #expect(macA.writeCount == writesA)
    #expect(applyCount == 1)
  }

  // MARK: - First enable

  @Test func firstEnableUploadsWhenICloudHasNoSettings() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("parakeet-local", forKey: "simple.voice.engine")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    #expect(mac.isEnabled)
    #expect(!mac.isAwaitingFirstEnableChoice)
    let document = try harness.readDocument()
    #expect(document.schemaVersion == SettingsSyncDocument.currentSchemaVersion)
    #expect(document.entries["simple.voice.engine"]?.value == .string("parakeet-local"))
    #expect(document.devices[mac.deviceID]?.name == "Mac A")
  }

  @Test func firstEnableAsksBeforeTouchingExistingCloudSettings() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("cloud vocab", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    let cloudBefore = try Data(contentsOf: harness.fileURL)

    harness.tick()
    defaultsB.set("this mac vocab", forKey: "vocab.custom")
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    #expect(macB.isAwaitingFirstEnableChoice)
    #expect(!macB.isEnabled)
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac vocab")
    #expect(try Data(contentsOf: harness.fileURL) == cloudBefore)

    // Cancel leaves both sides untouched and sync off.
    macB.cancelFirstEnable()
    #expect(!macB.isEnabled)
    #expect(try Data(contentsOf: harness.fileURL) == cloudBefore)
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac vocab")
  }

  @Test func firstEnableUseCloudReplacesThisMacsSettings() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("cloud vocab", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)

    harness.tick()
    defaultsB.set("this mac vocab", forKey: "vocab.custom")
    defaultsB.set("de", forKey: "transcription.language")  // not in the cloud yet
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)

    #expect(macB.isEnabled)
    #expect(defaultsB.string(forKey: "vocab.custom") == "cloud vocab")
    // Settings the cloud never had are kept and shared, not wiped.
    #expect(defaultsB.string(forKey: "transcription.language") == "de")
    #expect(try harness.readDocument().entries["transcription.language"]?.value == .string("de"))
  }

  @Test func firstEnableReplaceCloudPushesThisMacEverywhere() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("cloud vocab", forKey: "vocab.custom")
    defaultsA.set("backslash", forKey: "hermes.shortcut.selection")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)

    harness.tick()
    defaultsB.set("this mac vocab", forKey: "vocab.custom")
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.replaceCloud)
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac vocab")

    harness.tick()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "this mac vocab")
    // B never set a Hermes hotkey, so replacing iCloud resets it on A too.
    #expect(defaultsA.object(forKey: "hermes.shortcut.selection") == nil)
  }

  // MARK: - Robustness

  @Test func corruptFileIsSetAsideAndReplaced() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data("{ this is not json".utf8).write(to: harness.fileURL)
    let defaults = try harness.makeDefaults()
    defaults.set("Luis", forKey: "vocab.custom")

    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    #expect(mac.isEnabled)
    #expect(mac.notice?.contains("unreadable") == true)
    #expect(try harness.readDocument().entries["vocab.custom"]?.value == .string("Luis"))
    let names = try FileManager.default.contentsOfDirectory(atPath: harness.folder.path)
    #expect(names.contains { $0.hasPrefix("settings.unreadable-") })
  }

  @Test func missingFileOrFolderIsRecreatedOnSync() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("Luis", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    try FileManager.default.removeItem(at: harness.folder)
    harness.tick()
    await mac.syncNow()
    #expect(mac.lastError == nil)
    #expect(try harness.readDocument().entries["vocab.custom"]?.value == .string("Luis"))
  }

  /// Unknown keys are kept; an entry with an unknown value type can't be verified, so it is
  /// preserved verbatim and its key is left alone (this Mac keeps its own value).
  @Test func unknownKeysAndValueTypesAreIgnoredButKept() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "entries": {
        "future.setting": {"value": {"type": "string", "value": "x"}, "counter": 5,
          "deviceID": "OTHER"},
        "vocab.spelling": {"value": {"type": "hologram", "value": 3}, "counter": 5,
          "deviceID": "OTHER"},
        "vocab.custom": {"value": {"type": "string", "value": "cloud"}, "counter": 5,
          "deviceID": "OTHER"}
      },
      "devices": {"OTHER": {"name": "Other Mac", "lastWriteAt": 1000}}
    }
    """
    try Data(json.utf8).write(to: harness.fileURL)
    let defaults = try harness.makeDefaults()
    defaults.set("mine", forKey: "vocab.spelling")

    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)

    #expect(defaults.string(forKey: "vocab.custom") == "cloud")
    #expect(defaults.object(forKey: "future.setting") == nil)
    #expect(defaults.string(forKey: "vocab.spelling") == "mine")
    let document = try harness.readDocument()
    #expect(document.entries["future.setting"]?.value == .string("x"))
    #expect(document.entries["vocab.spelling"] == nil)
    #expect(document.opaqueEntries["vocab.spelling"] != nil, "unverifiable entry was dropped")
    #expect(document.devices.count == 2)
  }

  @Test func newerSchemaIsReadButNeverOverwritten() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let future = SettingsSyncDocument(
      schemaVersion: SettingsSyncDocument.currentSchemaVersion + 1,
      entries: [
        "vocab.custom": .init(
          value: .string("from newer app"),
          counter: 5,
          deviceID: "OTHER"
        )
      ]
    )
    try future.encoded().write(to: harness.fileURL)
    let before = try Data(contentsOf: harness.fileURL)
    let defaults = try harness.makeDefaults()
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)

    #expect(defaults.string(forKey: "vocab.custom") == "from newer app")
    #expect(try Data(contentsOf: harness.fileURL) == before)
    #expect(mac.lastError?.contains("newer WonderWhisper") == true)
  }

  @Test func iCloudDriveOffKeepsSyncOffWithAPlainMessage() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    let mac = SettingsSyncService(
      defaults: defaults,
      directory: harness.folder,
      iCloudRoot: harness.root.appendingPathComponent("no-icloud-here"),
      deviceName: "Mac A",
      observesChanges: false
    )
    #expect(!mac.isICloudAvailable)
    await mac.setEnabled(true)
    #expect(!mac.isEnabled)
    #expect(mac.lastError?.contains("iCloud Drive is off") == true)
    #expect(!FileManager.default.fileExists(atPath: harness.fileURL.path))
  }

  @Test func turningSyncOffStopsWritingAndAsksAgainNextTime() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("Luis", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    await mac.setEnabled(false)
    #expect(!mac.isEnabled)

    let before = try Data(contentsOf: harness.fileURL)
    defaults.set("changed while off", forKey: "vocab.custom")
    await mac.syncNow()
    #expect(try Data(contentsOf: harness.fileURL) == before)

    await mac.setEnabled(true)
    #expect(mac.isAwaitingFirstEnableChoice)
  }

  // MARK: - Live apply

  @Test func appliedCloudValuesReachTheLiveViewModels() throws {
    // AppConfig.defaults is the wiped scratch suite under the test runner.
    let defaults = AppConfig.defaults
    let keys = [
      "vocab.custom", "transcription.language", "llm.temperature", "meeting.notes.model",
      "simple.dictation.settings"
    ]
    defer { keys.forEach { defaults.removeObject(forKey: $0) } }
    let vm = DictationViewModel()

    var dictation = vm.simpleDictation
    dictation.header = "Synced header"
    defaults.set(try JSONEncoder().encode(dictation), forKey: "simple.dictation.settings")
    defaults.set("Luis, Xinyi", forKey: "vocab.custom")
    defaults.set("fr", forKey: "transcription.language")
    defaults.set(0.7, forKey: "llm.temperature")
    defaults.set("openai/gpt-synced", forKey: "meeting.notes.model")

    vm.applySyncedSettings(changedKeys: Set(keys))

    #expect(vm.vocabCustom == "Luis, Xinyi")
    #expect(vm.transcriptionLanguage == "fr")
    #expect(vm.llmTemperature == 0.7)
    #expect(vm.meetingCoordinator.noteModel == "openai/gpt-synced")
    #expect(vm.simpleDictation.header == "Synced header")
  }

  // MARK: - Review regressions

  /// #1: applying several received keys must not let one property's side effects write stale
  /// cached siblings over the other received values.
  @Test func liveApplyKeepsEveryValueInAReceivedBatch() {
    let defaults = AppConfig.defaults
    let keys: Set<String> = ["vocab.custom", "vocab.spelling", "llm.model", "screenContext.enabled"]
    defer { keys.forEach { defaults.removeObject(forKey: $0) } }
    let vm = DictationViewModel()
    #expect(vm.vocabSpelling != "Lewis -> Luis")

    // Sync writes the whole batch into UserDefaults first, then notifies once.
    defaults.set("Luis, Xinyi", forKey: "vocab.custom")
    defaults.set("Lewis -> Luis", forKey: "vocab.spelling")
    defaults.set("openai/gpt-synced", forKey: "llm.model")
    defaults.set(!vm.screenContextEnabled, forKey: "screenContext.enabled")
    let expectedScreenContext = !vm.screenContextEnabled

    vm.applySyncedSettings(changedKeys: keys)

    #expect(vm.vocabCustom == "Luis, Xinyi")
    #expect(vm.vocabSpelling == "Lewis -> Luis")
    #expect(vm.llmModel == "openai/gpt-synced")
    #expect(vm.screenContextEnabled == expectedScreenContext)
    #expect(defaults.string(forKey: "vocab.spelling") == "Lewis -> Luis")
    #expect(defaults.string(forKey: "llm.model") == "openai/gpt-synced")
    #expect(defaults.object(forKey: "screenContext.enabled") as? Bool == expectedScreenContext)
  }

  /// #2: an edit made after receiving another Mac's change wins even when that Mac's clock is
  /// ten minutes fast.
  @Test func laterEditWinsOverAMacWithAFastClock() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("from fast A", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A", clockOffset: 600)
    await macA.setEnabled(true)

    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    #expect(defaultsB.string(forKey: "vocab.custom") == "from fast A")

    harness.tick()
    defaultsB.set("later edit on B", forKey: "vocab.custom")
    macB.noteLocalChanges()
    await macB.syncNow()
    #expect(defaultsB.string(forKey: "vocab.custom") == "later edit on B")

    harness.tick()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "later edit on B")
  }

  /// #2: "Replace iCloud" is authoritative even against entries stamped by a fast clock.
  @Test func replaceICloudWinsOverAMacWithAFastClock() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("from fast A", forKey: "vocab.custom")
    defaultsA.set("fr", forKey: "transcription.language")
    let macA = harness.makeService(defaultsA, name: "Mac A", clockOffset: 600)
    await macA.setEnabled(true)

    harness.tick()
    defaultsB.set("B is the source of truth", forKey: "vocab.custom")
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.replaceCloud)
    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("B is the source of truth"))
    #expect(document.entries["transcription.language"]?.value == nil)

    harness.tick()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "B is the source of truth")
    #expect(defaultsA.object(forKey: "transcription.language") == nil)
  }

  /// #3: a newer document installed by iCloud while a sync is in flight is merged, not
  /// overwritten by a merge computed from an older read.
  @Test func documentInstalledMidSyncIsMergedNotOverwritten() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("one", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    harness.tick()
    defaults.set("local edit", forKey: "vocab.custom")
    mac.noteLocalChanges()
    let fileURL = harness.fileURL
    mac.beforeTransactionForTesting = { [weak mac] in
      mac?.beforeTransactionForTesting = nil
      var installed = try? SettingsSyncDocument.decode(Data(contentsOf: fileURL))
      installed?.entries["transcription.language"] = .init(
        value: .string("de"),
        counter: 1_000,
        deviceID: "OTHER"
      )
      try? installed?.encoded().write(to: fileURL, options: .atomic)
    }
    harness.tick()
    await mac.syncNow()

    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("local edit"))
    #expect(document.entries["transcription.language"]?.value == .string("de"))
    #expect(defaults.string(forKey: "transcription.language") == "de")
  }

  /// #3: a newer-schema file installed mid-sync is never overwritten.
  @Test func newerSchemaInstalledMidSyncIsNeverOverwritten() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set("one", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    harness.tick()
    defaults.set("local edit", forKey: "vocab.custom")
    mac.noteLocalChanges()
    let future = SettingsSyncDocument(schemaVersion: SettingsSyncDocument.currentSchemaVersion + 1)
    let futureData = try future.encoded()
    let fileURL = harness.fileURL
    mac.beforeTransactionForTesting = { [weak mac] in
      mac?.beforeTransactionForTesting = nil
      try? futureData.write(to: fileURL, options: .atomic)
    }
    await mac.syncNow()

    #expect(try Data(contentsOf: harness.fileURL) == futureData)
    #expect(mac.lastError?.contains("newer WonderWhisper") == true)
  }

  /// #3: corruption is re-checked inside the transaction; a file repaired in the meantime is
  /// not quarantined, and first enable stops to ask instead of overwriting it.
  @Test func repairedFileIsNotQuarantinedAndFirstEnableAsks() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data("{ broken".utf8).write(to: harness.fileURL)
    let repaired = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("repaired"), counter: 1, deviceID: "B")
    ])
    let repairedData = try repaired.encoded()
    let defaults = try harness.makeDefaults()
    defaults.set("this mac", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    let fileURL = harness.fileURL
    mac.beforeTransactionForTesting = { [weak mac] in
      mac?.beforeTransactionForTesting = nil
      try? repairedData.write(to: fileURL, options: .atomic)
    }

    await mac.setEnabled(true)

    #expect(!mac.isEnabled)
    #expect(mac.isAwaitingFirstEnableChoice)
    #expect(try Data(contentsOf: harness.fileURL) == repairedData)
    let names = try FileManager.default.contentsOfDirectory(atPath: harness.folder.path)
    #expect(!names.contains { $0.hasPrefix("settings.unreadable-") })
    #expect(defaults.string(forKey: "vocab.custom") == "this mac")
  }

  /// #4: an offline Mac's edits kept by iCloud as a conflict version are merged per key, and
  /// the conflict is marked resolved only after the merged file is saved.
  @Test func iCloudConflictVersionsAreMergedThenResolved() async throws {
    let harness = try Harness()
    let conflicts = FakeConflictVersions()
    let defaults = try harness.makeDefaults()
    defaults.set("mine", forKey: "vocab.custom")
    defaults.set("en", forKey: "transcription.language")
    let mac = harness.makeService(defaults, name: "Mac A", conflicts: conflicts.source)
    await mac.setEnabled(true)

    harness.tick()
    let losingVersion = SettingsSyncDocument(
      entries: [
        "transcription.language": .init(
          value: .string("fr"),
          counter: 1_000,
          deviceID: "OFFLINE"
        )
      ],
      devices: ["OFFLINE": .init(name: "Offline Mac", lastWriteAt: harness.clock)]
    )
    conflicts.add(try losingVersion.encoded())
    harness.tick()
    await mac.syncNow()

    #expect(defaults.string(forKey: "transcription.language") == "fr")
    #expect(defaults.string(forKey: "vocab.custom") == "mine")
    let document = try harness.readDocument()
    #expect(document.entries["transcription.language"]?.value == .string("fr"))
    #expect(document.devices["OFFLINE"] != nil)
    #expect(conflicts.resolvedCount == 1)
    #expect(conflicts.finishCount == 1)
  }

  /// #4: conflicts stay unresolved when the merged document can't be saved (newer schema).
  @Test func conflictVersionsStayUnresolvedWhenNothingIsSaved() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let future = SettingsSyncDocument(schemaVersion: SettingsSyncDocument.currentSchemaVersion + 1)
    try future.encoded().write(to: harness.fileURL)
    let conflicts = FakeConflictVersions()
    conflicts.add(try SettingsSyncDocument().encoded())
    let defaults = try harness.makeDefaults()
    let mac = harness.makeService(defaults, name: "Mac A", conflicts: conflicts.source)
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)

    #expect(conflicts.resolvedCount == 0)
    #expect(conflicts.finishCount == 0)
  }

  /// #5: a reset is stamped when it happens; uploaded later it must not erase a newer value
  /// another Mac set in the meantime.
  @Test func olderResetLosesToNewerRemoteValue() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("shared", forKey: "vocab.spelling")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)

    harness.tick()
    let counterBeforeReset = macA.counter
    defaultsA.removeObject(forKey: "vocab.spelling")
    macA.noteLocalChanges()
    #expect(macA.counter == counterBeforeReset + 1, "a removal must be stamped when seen")
    // B makes two edits after A's reset was seen, so B's last one is ordered after it.
    harness.tick()
    defaultsB.set("interim on B", forKey: "vocab.spelling")
    macB.noteLocalChanges()
    await macB.syncNow()
    defaultsB.set("newer on B", forKey: "vocab.spelling")
    macB.noteLocalChanges()
    await macB.syncNow()

    harness.tick()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.spelling") == "newer on B")
    #expect(try harness.readDocument().entries["vocab.spelling"]?.value == .string("newer on B"))
  }

  /// #6: turning sync off while a sync is in flight stops it from applying or writing.
  @Test func disablingDuringAnInFlightSyncStopsIt() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("one", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)
    harness.tick()
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    harness.tick()
    defaultsB.set("cloud value", forKey: "vocab.custom")
    macB.noteLocalChanges()
    await macB.syncNow()

    let fileBefore = try Data(contentsOf: harness.fileURL)
    let writesBefore = macA.writeCount
    var applied = false
    macA.onRemoteChangesApplied = { _ in applied = true }
    macA.beforeTransactionForTesting = { [weak macA] in
      guard let macA else { return }
      macA.beforeTransactionForTesting = nil
      await macA.setEnabled(false)
      defaultsA.set("edit while off", forKey: "vocab.custom")
    }
    harness.tick()
    await macA.syncNow()

    #expect(!macA.isEnabled)
    #expect(defaultsA.string(forKey: "vocab.custom") == "edit while off")
    #expect(!applied)
    #expect(macA.writeCount == writesBefore)
    #expect(try Data(contentsOf: harness.fileURL) == fileBefore)
  }

  /// #6: the transaction itself honours cancellation right before writing.
  @Test func cancelledTransactionNeverWrites() throws {
    let harness = try Harness()
    let store = SettingsSyncFileStore(directory: harness.folder, conflicts: .none)
    let token = SettingsSyncCancellation()
    token.cancel()
    let input = SettingsSyncFileStore.TransactionInput(
      local: ["vocab.custom": .init(value: .string("x"), version: SettingsSyncVersion(1, "A"))],
      deviceID: "A",
      deviceName: "Mac A",
      timestamp: harness.clock
    )
    let outcome = try store.transact(input, cancellation: token)
    #expect(outcome.cancelled)
    #expect(!outcome.wrote)
    #expect(!FileManager.default.fileExists(atPath: harness.fileURL.path))
  }

  /// #7: received values are validated per setting; bad ones are rejected and the local value
  /// kept, instead of crashing (`UInt32(-1)`) or replacing good prompt data.
  @Test func invalidReceivedValuesAreRejectedAndLocalValuesKept() async throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    let goodSettings = try JSONEncoder().encode(SimpleModeDefaults.settings(for: .dictation))
    defaults.set(9, forKey: "pasteShortcut.keyCode")
    defaults.set(goodSettings, forKey: "simple.dictation.settings")
    defaults.set("good vocab", forKey: "vocab.custom")
    defaults.set("parakeet-local", forKey: "simple.voice.engine")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)

    harness.tick(60)
    var hostile = try harness.readDocument()
    let later: Int64 = 1_000
    hostile.entries["pasteShortcut.keyCode"] = .init(
      value: .int(-1),
      counter: later,
      deviceID: "X"
    )
    hostile.entries["simple.dictation.settings"] = .init(
      value: .data(Data("not json".utf8)),
      counter: later,
      deviceID: "X"
    )
    hostile.entries["vocab.custom"] = .init(value: .int(5), counter: later, deviceID: "X")
    hostile.entries["simple.voice.engine"] = .init(
      value: .string("no-such-engine"),
      counter: later,
      deviceID: "X"
    )
    try hostile.encoded().write(to: harness.fileURL, options: .atomic)

    var applied: Set<String> = []
    mac.onRemoteChangesApplied = { applied.formUnion($0) }
    harness.tick()
    await mac.syncNow()

    #expect(defaults.integer(forKey: "pasteShortcut.keyCode") == 9)
    #expect(defaults.data(forKey: "simple.dictation.settings") == goodSettings)
    #expect(defaults.string(forKey: "vocab.custom") == "good vocab")
    #expect(defaults.string(forKey: "simple.voice.engine") == "parakeet-local")
    #expect(applied.isEmpty)
    #expect(mac.lastRejectedKeys == [
      "pasteShortcut.keyCode", "simple.dictation.settings", "vocab.custom", "simple.voice.engine"
    ])
    #expect(mac.notice?.contains("Ignored 4 settings") == true)

    // Rejection is stable: no ping-pong writes on later syncs.
    let writes = mac.writeCount
    harness.tick()
    await mac.syncNow()
    #expect(mac.writeCount == writes)
  }

  @Test func validationChecksTypesRangesAndEmbeddedJSON() throws {
    #expect(SettingsSyncRegistry.isValid(.int(36), for: "pasteShortcut.keyCode"))
    #expect(!SettingsSyncRegistry.isValid(.int(-1), for: "pasteShortcut.keyCode"))
    let tooBig = SettingsSyncValue.int(Int(UInt32.max) + 1)
    #expect(!SettingsSyncRegistry.isValid(tooBig, for: "pasteShortcut.modifiers"))
    #expect(!SettingsSyncRegistry.isValid(.double(.nan), for: "llm.temperature"))
    #expect(SettingsSyncRegistry.isValid(.int(1), for: "llm.temperature"))
    #expect(!SettingsSyncRegistry.isValid(.string("1"), for: "llm.temperature"))
    #expect(!SettingsSyncRegistry.isValid(.string("telepathy"), for: "hermes.shortcut.selection"))
    #expect(SettingsSyncRegistry.isValid(nil, for: "hermes.shortcut.selection"))
    #expect(!SettingsSyncRegistry.isValid(.string("x"), for: "not.a.synced.key"))
    #expect(!SettingsSyncRegistry.isValid(.data(Data("[1]".utf8)), for: "beeper.chats"))
    for (index, setting) in SettingsSyncRegistry.synced.enumerated() {
      let sample = try Self.sampleValue(for: setting.key, index: index)
      #expect(SettingsSyncRegistry.isValid(sample, for: setting.key), "\(setting.key)")
    }
  }

  /// #8: the types handed across the background file transaction are Sendable, and the
  /// registry's metadata keys are readable from a nonisolated context.
  @Test nonisolated func syncTypesAreSafeToCrossIsolationBoundaries() {
    Self.requireSendable(SettingsSyncFilePresenter.self)
    Self.requireSendable(SettingsSyncFileStore.self)
    Self.requireSendable(SettingsSyncFileStore.TransactionInput.self)
    Self.requireSendable(SettingsSyncFileStore.TransactionOutcome.self)
    Self.requireSendable(SettingsSyncConflictSource.self)
    Self.requireSendable(SettingsSyncCancellation.self)
    Self.requireSendable(SettingsSyncDocument.self)
    #expect(SettingsSyncRegistry.excluded[SettingsSyncStateKey.enabled] != nil)
    #expect(SettingsSyncRegistry.excluded[SettingsSyncStateKey.localState] != nil)
    Self.requireSendable(SettingsSyncEngine.self)
    Self.requireSendable(SettingsSyncVersion.self)
    Self.requireSendable(SettingsSyncTransaction.Plan.self)
  }

  private nonisolated static func requireSendable<T: Sendable>(_: T.Type) {}

  // MARK: - Review round 2 regressions

  /// R2-1: a syntactically valid but absurd timestamp must be rejected, not trap in Int64(_:).
  @Test func malformedTimestampsAreRejectedWithoutCrashing() async throws {
    let json = """
    {
      "schemaVersion": 1,
      "entries": {
        "vocab.custom": {"value": {"type": "string", "value": "huge"}, "counter": 1e20,
          "deviceID": "X"},
        "vocab.spelling": {"value": {"type": "string", "value": "negative"}, "counter": -1,
          "deviceID": "X"},
        "transcription.language": {"value": {"type": "string", "value": "max"},
          "counter": 1.7e308, "deviceID": "X"},
        "llm.temperature": {"value": {"type": "double", "value": 0.5},
          "counter": 9007199254740993, "deviceID": "X"},
        "llm.model": {"value": {"type": "string", "value": "ok"}, "counter": 3,
          "deviceID": "X"}
      },
      "devices": {"X": {"name": "Broken Mac", "lastWriteAt": 1e20}}
    }
    """
    let document = try SettingsSyncDocument.decode(Data(json.utf8))
    #expect(Set(document.entries.keys) == ["llm.model"])
    #expect(Set(document.opaqueEntries.keys)
      == ["vocab.custom", "vocab.spelling", "transcription.language", "llm.temperature"])
    #expect(document.devices.isEmpty)
    #expect(SettingsSyncDocument.millis(Date(timeIntervalSince1970: 1e300))
      == SettingsSyncDocument.maxMillis)
    #expect(SettingsSyncDocument.checkedMillis(.infinity) == nil)

    // End to end: a Mac syncing against that file keeps working.
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: harness.fileURL)
    let defaults = try harness.makeDefaults()
    defaults.set("mine", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)
    #expect(mac.isEnabled)
    #expect(defaults.string(forKey: "llm.model") == "ok")
    #expect(defaults.string(forKey: "vocab.custom") == "mine")
    #expect(try harness.readDocument().opaqueEntries.count == 4, "malformed entries were lost")
  }

  /// R2-2: a conflict version that can't be read yet keeps its offline edits for a later sync:
  /// only incorporated versions are resolved, and no blanket removal runs while one is pending.
  @Test func unreadableConflictVersionIsKeptForRetry() async throws {
    let harness = try Harness()
    let conflicts = FakeConflictVersions()
    let defaults = try harness.makeDefaults()
    defaults.set("en", forKey: "transcription.language")
    defaults.set("mine", forKey: "vocab.spelling")
    let mac = harness.makeService(defaults, name: "Mac A", conflicts: conflicts.source)
    await mac.setEnabled(true)

    harness.tick()
    func version(_ key: String, _ value: String, _ counter: Int64) throws -> Data {
      try SettingsSyncDocument(entries: [
        key: .init(value: .string(value), counter: counter, deviceID: "OFFLINE")
      ]).encoded()
    }
    conflicts.add(try version("transcription.language", "fr", 1_000))
    let stillDownloading = conflicts.add(nil)
    harness.tick()
    await mac.syncNow()

    #expect(defaults.string(forKey: "transcription.language") == "fr")
    #expect(conflicts.resolvedCount == 1)
    #expect(conflicts.finishCount == 0, "must not remove versions while one is unmerged")
    #expect(conflicts.remainingCount == 1)

    // The version becomes readable later; its edit is merged and only then is all cleaned up.
    conflicts.setData(stillDownloading, try version("vocab.spelling", "offline edit", 2_000))
    harness.tick()
    await mac.syncNow()
    #expect(defaults.string(forKey: "vocab.spelling") == "offline edit")
    #expect(conflicts.resolvedCount == 2)
    #expect(conflicts.finishCount == 1)
    #expect(conflicts.remainingCount == 0)
  }

  /// R2-3: "Replace iCloud" stays "Replace iCloud" through a download wait, a failed write and
  /// a relaunch, instead of degrading into a merge that lets the cloud overwrite this Mac.
  @Test func replaceICloudSurvivesDownloadWaitFailedWriteAndRelaunch() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("cloud vocab", forKey: "vocab.custom")
    defaultsA.set("fr", forKey: "transcription.language")
    let macA = harness.makeService(defaultsA, name: "Mac A")
    await macA.setEnabled(true)

    harness.tick()
    defaultsB.set("this mac", forKey: "vocab.custom")
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    #expect(macB.isAwaitingFirstEnableChoice)

    // iCloud evicts the file to a placeholder after the dialog opened.
    let fm = FileManager.default
    let parked = harness.root.appendingPathComponent("parked.json")
    let placeholder = harness.folder.appendingPathComponent(".settings.json.icloud")
    try fm.moveItem(at: harness.fileURL, to: parked)
    try Data().write(to: placeholder)
    await macB.resolveFirstEnable(.replaceCloud)
    #expect(macB.isEnabled)
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac")

    // Relaunch while still waiting, then the download lands but the folder isn't writable.
    #expect(defaultsB.string(forKey: SettingsSyncStateKey.firstEnableMode) == "preferLocal")
    let relaunchedB = harness.makeService(defaultsB, name: "Mac B")
    try fm.removeItem(at: placeholder)
    try fm.moveItem(at: parked, to: harness.fileURL)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: harness.folder.path)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.folder.path)
    }
    harness.tick()
    await relaunchedB.syncNow()
    #expect(relaunchedB.lastError != nil)
    #expect(defaultsB.string(forKey: SettingsSyncStateKey.firstEnableMode) == "preferLocal")
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac")

    // Writable again: the original choice still applies.
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.folder.path)
    harness.tick()
    await relaunchedB.syncNow()
    #expect(relaunchedB.lastError == nil)
    #expect(defaultsB.object(forKey: SettingsSyncStateKey.firstEnableMode) == nil)
    #expect(defaultsB.string(forKey: "vocab.custom") == "this mac")
    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("this mac"))
    #expect(document.entries["transcription.language"]?.value == nil)

    harness.tick()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "this mac")
    #expect(defaultsA.object(forKey: "transcription.language") == nil)
  }

  // MARK: - Round 3: Lamport ordering

  // MARK: - Round 4: immutable versions, explicit first-enable modes

  /// Builds a service whose device ID is fixed, so version tie-breaks are predictable.
  private static func mac(
    _ harness: Harness,
    _ id: String,
    conflicts: SettingsSyncConflictSource = .none
  ) throws -> (SettingsSyncService, UserDefaults) {
    let defaults = try harness.makeDefaults()
    defaults.set(id, forKey: SettingsSyncStateKey.deviceID)
    return (harness.makeService(defaults, name: "Mac \(id)", conflicts: conflicts), defaults)
  }

  /// R4-1: a Mac that relays another Mac's value keeps that value's original version, so it
  /// can't reverse a newer edit or resurrect a reset.
  @Test func relayedValueKeepsItsOriginalVersion() async throws {
    let harness = try Harness()
    let (macA, defaultsA) = try Self.mac(harness, "A")
    defaultsA.set("base", forKey: "vocab.custom")
    await macA.setEnabled(true)
    var macs: [(SettingsSyncService, UserDefaults)] = [(macA, defaultsA)]
    for id in ["B", "C", "Z"] {
      let (mac, defaults) = try Self.mac(harness, id)
      await mac.setEnabled(true)
      await mac.resolveFirstEnable(.useCloud)
      macs.append((mac, defaults))
    }
    let (macB, defaultsB) = macs[1]
    let (macC, defaultsC) = macs[2]
    let (macZ, defaultsZ) = macs[3]

    // Concurrent edits at the same counter: B sets a value, C resets it. (2,C) > (2,B).
    defaultsB.set("b", forKey: "vocab.custom")
    macB.noteLocalChanges()
    defaultsC.removeObject(forKey: "vocab.custom")
    macC.noteLocalChanges()
    #expect(macB.pendingVersion(for: "vocab.custom") == SettingsSyncVersion(2, "B"))
    #expect(macC.pendingVersion(for: "vocab.custom") == SettingsSyncVersion(2, "C"))

    await macB.syncNow()
    await macZ.syncNow()  // Z relays B's value...
    #expect(defaultsZ.string(forKey: "vocab.custom") == "b")
    await macC.syncNow()
    await macZ.syncNow()  // ...but must not re-upload it as (2,Z) over C's (2,C) reset.
    for (mac, _) in macs { await mac.syncNow() }

    let entry = try #require(try harness.readDocument().entries["vocab.custom"])
    #expect(entry.value == nil)
    #expect(entry.version == SettingsSyncVersion(2, "C"))
    for (_, defaults) in macs {
      #expect(defaults.object(forKey: "vocab.custom") == nil)
    }
  }

  /// R4-2: "Use iCloud" adopts every cloud key, resets included, even against schema-1 entries
  /// at counter 0 and a local device ID that would win a tie.
  @Test func useICloudAdoptsEveryCloudKeyIncludingResets() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "entries": {
        "vocab.custom": {"value": {"type": "string", "value": "from v1"},
          "modifiedAt": 1000, "deviceID": "OLD"},
        "transcription.language": {"modifiedAt": 1000, "deviceID": "OLD"}
      },
      "devices": {"OLD": {"name": "Old Mac", "lastWriteAt": 1000}}
    }
    """
    try Data(json.utf8).write(to: harness.fileURL)
    let (mac, defaults) = try Self.mac(harness, "ZZZZ")
    defaults.set("mine", forKey: "vocab.custom")
    defaults.set("de", forKey: "transcription.language")
    defaults.set("local/only", forKey: "llm.model")

    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)

    #expect(defaults.string(forKey: "vocab.custom") == "from v1")
    #expect(defaults.object(forKey: "transcription.language") == nil)
    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("from v1"))
    #expect(document.entries["vocab.custom"]?.version == SettingsSyncVersion(0, "OLD"))
    #expect(document.entries["transcription.language"].map { $0.value == nil } == true)
    #expect(document.entries["llm.model"]?.value == .string("local/only"))
  }

  /// R4-3: "Replace iCloud" stamps the whole batch (identical values included) above every
  /// counter in the file and in its conflict versions, so an older offline edit can't win.
  @Test func replaceStampsWholeBatchAboveFileAndConflicts() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("cloud"), counter: 1, deviceID: "X"),
      "transcription.language": .init(value: .string("fr"), counter: 100, deviceID: "X")
    ]).encoded().write(to: harness.fileURL)
    let conflicts = FakeConflictVersions()
    conflicts.add(try SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("older offline"), counter: 99, deviceID: "Y")
    ]).encoded())

    let (mac, defaults) = try Self.mac(harness, "B", conflicts: conflicts.source)
    defaults.set("this mac", forKey: "vocab.custom")
    defaults.set("fr", forKey: "transcription.language")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.replaceCloud)

    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("this mac"))
    #expect(document.entries["vocab.custom"]?.version == SettingsSyncVersion(101, "B"))
    #expect(document.entries["transcription.language"]?.version == SettingsSyncVersion(101, "B"))
    #expect(conflicts.resolvedCount == 1)
    #expect(defaults.string(forKey: "vocab.custom") == "this mac")
    await mac.syncNow()
    #expect(defaults.string(forKey: "vocab.custom") == "this mac")
  }

  /// R4-4: a pending edit is persisted with its version when observed; after a relaunch it is
  /// uploaded with that same version, not re-stamped (which would let it win by device ID).
  @Test func pendingEditSurvivesRelaunchWithItsVersion() async throws {
    let harness = try Harness()
    let (macZ, defaultsZ) = try Self.mac(harness, "Z")
    defaultsZ.set("base", forKey: "vocab.custom")
    await macZ.setEnabled(true)
    let (macB, defaultsB) = try Self.mac(harness, "B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)

    defaultsB.set("b edit", forKey: "vocab.custom")
    macB.noteLocalChanges()
    #expect(macB.pendingVersion(for: "vocab.custom") == SettingsSyncVersion(2, "B"))
    defaultsZ.set("z edit", forKey: "vocab.custom")
    macZ.noteLocalChanges()
    await macZ.syncNow()  // (2,Z) is in the cloud; it beats (2,B)

    let relaunchedB = harness.makeService(defaultsB, name: "Mac B")
    #expect(relaunchedB.pendingVersion(for: "vocab.custom") == SettingsSyncVersion(2, "B"))
    relaunchedB.noteLocalChanges()
    await relaunchedB.syncNow()

    let entry = try #require(try harness.readDocument().entries["vocab.custom"])
    #expect(entry.version == SettingsSyncVersion(2, "Z"))
    #expect(defaultsB.string(forKey: "vocab.custom") == "z edit")
  }

  /// R4-5: equal values keep the higher version, so a recovered older edit can't win.
  @Test func equalValuesKeepTheHigherVersion() throws {
    let remote = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("X"), counter: 5, deviceID: "B")
    ])
    let local = ["vocab.custom": SettingsSyncMerger.LocalCandidate(
      value: .string("X"),
      version: SettingsSyncVersion(100, "A")
    )]
    let merged = SettingsSyncMerger.merge(
      local: local,
      remote: remote,
      deviceID: "A",
      localVersion: SettingsSyncVersion(100, "A")
    )
    #expect(merged.documentChanged)
    #expect(merged.document.entries["vocab.custom"]?.version == SettingsSyncVersion(100, "A"))

    // Through a whole transaction, with an older offline edit recovered from a conflict.
    let offline = try SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("Y"), counter: 50, deviceID: "C")
    ]).encoded()
    let plan = SettingsSyncTransaction.plan(
      SettingsSyncTransaction.Input(
        local: local,
        deviceID: "A",
        deviceName: "Mac A",
        timestamp: Date(timeIntervalSince1970: 0),
        localVersion: SettingsSyncVersion(100, "A")
      ),
      current: .contents(try remote.encoded()),
      conflicts: [offline]
    )
    #expect(plan.write?.entries["vocab.custom"]?.value == .string("X"))
    #expect(plan.write?.entries["vocab.custom"]?.version == SettingsSyncVersion(100, "A"))
    #expect(plan.incorporated == [0])
  }

  /// R4-6: deferred view-model saves triggered by a received reset are suppressed (they carry
  /// remote-apply provenance), so they can't become local edits; a genuine edit made afterwards
  /// is still persisted.
  @Test func deferredSavesAfterAReceivedResetAreNotLocalEdits() async throws {
    let defaults = AppConfig.defaults
    let keys: Set<String> = ["simple.model.selected", "simple.dictation.settings"]
    defer { keys.forEach { defaults.removeObject(forKey: $0) } }
    let vm = DictationViewModel()

    var settings = vm.simpleDictation
    settings.header = "Received header"
    defaults.set(try JSONEncoder().encode(settings), forKey: "simple.dictation.settings")
    defaults.set("received/model", forKey: "simple.model.selected")
    vm.applySyncedSettings(changedKeys: keys)
    try await Task.sleep(for: .milliseconds(200))
    #expect(vm.simpleSelectedModel == "received/model")

    // A received reset: the view model falls back to defaults and its deferred hops would
    // persist them. With provenance they are dropped.
    keys.forEach { defaults.removeObject(forKey: $0) }
    vm.applySyncedSettings(changedKeys: keys)
    try await Task.sleep(for: .milliseconds(300))
    #expect(vm.simpleSelectedModel == SimpleModeDefaults.defaultModelID)
    for key in keys {
      #expect(defaults.object(forKey: key) == nil, "\(key) was re-saved by a deferred hop")
    }

    // A genuine edit afterwards is a fresh task without provenance: it is written.
    vm.simpleSelectedModel = "user/choice"
    try await Task.sleep(for: .milliseconds(300))
    #expect(defaults.string(forKey: "simple.model.selected") == "user/choice")
  }

  /// R4-6: the provenance-aware store drops writes to synced keys inside an apply (including
  /// from tasks spawned there), and passes everything else through.
  @Test func provenanceSuppressesOnlySyncedWritesDuringApply() async throws {
    let suite = "ww.provenance.tests.\(UUID().uuidString)"
    let store = try #require(SyncProvenanceUserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    store.set("before", forKey: "vocab.custom")

    let spawned: Task<Void, Never> = SettingsSyncProvenance.applyingRemoteSettings {
      store.set("during", forKey: "vocab.custom")
      store.set(true, forKey: "llm.enabled")
      store.set(3, forKey: "history.maxEntries")
      store.set(0.5, forKey: "llm.temperature")
      store.removeObject(forKey: "vocab.custom")
      store.set("allowed", forKey: "simple.sidebar.selection")  // not synced
      return Task { store.set("from hop", forKey: "vocab.spelling") }
    }
    await spawned.value
    #expect(store.string(forKey: "vocab.custom") == "before")
    #expect(store.object(forKey: "llm.enabled") == nil)
    #expect(store.object(forKey: "history.maxEntries") == nil)
    #expect(store.object(forKey: "llm.temperature") == nil)
    #expect(store.object(forKey: "vocab.spelling") == nil)
    #expect(store.string(forKey: "simple.sidebar.selection") == "allowed")

    store.set("after", forKey: "vocab.custom")  // outside the scope: a genuine edit
    #expect(store.string(forKey: "vocab.custom") == "after")
  }

  /// R4-7: a legitimate counter far above this Mac's (here 5e9) is accepted, never treated as
  /// corrupt and overwritten; this Mac's next edit is ordered after it.
  @Test func legitimateHighCounterIsAcceptedByAFreshMac() async throws {
    let harness = try Harness()
    let (mac, defaults) = try Self.mac(harness, "A")
    defaults.set("mine", forKey: "vocab.custom")
    await mac.setEnabled(true)

    var document = try harness.readDocument()
    document.entries["vocab.custom"] = .init(value: .string("remote"), counter: 5_000_000_000,
                                             deviceID: "X")
    try document.encoded().write(to: harness.fileURL, options: .atomic)
    await mac.syncNow()
    #expect(defaults.string(forKey: "vocab.custom") == "remote")
    #expect(try harness.readDocument().entries["vocab.custom"]?.counter == 5_000_000_000)
    #expect(mac.counter == 5_000_000_000)

    defaults.set("next", forKey: "vocab.custom")
    mac.noteLocalChanges()
    await mac.syncNow()
    #expect(try harness.readDocument().entries["vocab.custom"]?.version
      == SettingsSyncVersion(5_000_000_001, "A"))
  }

  /// R4-7: a conflict version is validated on its own before combining. An over-limit counter
  /// keeps it unresolved (preserved) and it never eclipses healthy data.
  @Test func overLimitConflictIsKeptAndNeverEclipsesHealthyData() async throws {
    let harness = try Harness()
    let conflicts = FakeConflictVersions()
    let (mac, defaults) = try Self.mac(harness, "A", conflicts: conflicts.source)
    defaults.set("healthy", forKey: "vocab.custom")
    await mac.setEnabled(true)

    let overLimit = """
    {"schemaVersion": 2, "entries": {"vocab.custom": {"value": {"type": "string",
      "value": "eclipse"}, "counter": 1152921504606846976, "deviceID": "BAD"}}, "devices": {}}
    """
    conflicts.add(Data(overLimit.utf8))
    await mac.syncNow()

    #expect(defaults.string(forKey: "vocab.custom") == "healthy")
    #expect(try harness.readDocument().entries["vocab.custom"]?.value == .string("healthy"))
    #expect(conflicts.resolvedCount == 0)
    #expect(conflicts.finishCount == 0)
    #expect(conflicts.remainingCount == 1)
    #expect(mac.notice?.contains("Waiting to merge 1") == true)
  }

  /// R4-7 / R5-4: a cloud entry whose provenance can't be established (here a counter of 1e20)
  /// is preserved verbatim, backed up next to settings.json, and blocks its key (named in
  /// Settings): it is neither applied nor overwritten by ordinary syncs or local edits.
  @Test func unverifiableCloudEntryBlocksItsKeyAndIsBackedUp() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data(Self.unverifiableJSON.utf8).write(to: harness.fileURL)
    let (mac, defaults) = try Self.mac(harness, "A")
    defaults.set("mine", forKey: "vocab.custom")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)

    #expect(mac.blockedKeys == ["vocab.custom"])
    #expect(mac.notice?.contains("vocab.custom") == true)
    let backup = harness.folder.appendingPathComponent("settings.blocked-vocab.custom.json")
    let backedUp = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
    )
    #expect((backedUp["counter"] as? Double) == 1e20)

    defaults.set("edited here", forKey: "vocab.custom")
    mac.noteLocalChanges()
    await mac.syncNow()
    #expect(try Self.rawEntry("vocab.custom", in: harness)?["counter"] as? Double == 1e20)
    #expect(defaults.string(forKey: "vocab.custom") == "edited here")
    #expect(mac.blockedKeys == ["vocab.custom"], "stays blocked until repaired")
  }

  /// R5-4: Repair replaces the blocked entry with this Mac's value at a valid version above
  /// everything in the file and its conflicts, and resolves the conflict it was blocking.
  @Test func repairReplacesABlockedEntryAndResolvesBlockedConflicts() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data(Self.unverifiableJSON.utf8).write(to: harness.fileURL)
    let conflicts = FakeConflictVersions()
    let (mac, defaults) = try Self.mac(harness, "A", conflicts: conflicts.source)
    defaults.set("mine", forKey: "vocab.custom")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)
    conflicts.add(try SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("healthy offline"), counter: 7, deviceID: "Y")
    ]).encoded())
    await mac.syncNow()
    #expect(conflicts.resolvedCount == 0, "a healthy conflict touching a blocked key waits")
    #expect(mac.blockedKeys == ["vocab.custom"])

    await mac.repairBlockedKeys()

    let entry = try #require(try harness.readDocument().entries["vocab.custom"])
    #expect(entry.value == .string("mine"))
    #expect(entry.version > SettingsSyncVersion(7, "Y"))
    #expect(entry.version.writer == "A")
    #expect(conflicts.resolvedCount == 1)
    #expect(mac.blockedKeys.isEmpty)
    #expect(try harness.readDocument().opaqueEntries.isEmpty)
    let backup = harness.folder.appendingPathComponent("settings.blocked-vocab.custom.json")
    #expect(FileManager.default.fileExists(atPath: backup.path), "the bad entry stays backed up")
  }

  /// R5-4: the user's explicit "Replace iCloud" also repairs blocked keys.
  @Test func replaceICloudRepairsBlockedKeys() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try Data(Self.unverifiableJSON.utf8).write(to: harness.fileURL)
    let (mac, defaults) = try Self.mac(harness, "A")
    defaults.set("mine", forKey: "vocab.custom")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.replaceCloud)

    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("mine"))
    #expect(document.opaqueEntries.isEmpty)
    #expect(document.entries["transcription.language"].map { $0.value == nil } == true)
    #expect(mac.blockedKeys.isEmpty)
  }

  private static let unverifiableJSON = """
  {"schemaVersion": 2, "entries": {
    "vocab.custom": {"value": {"type": "string", "value": "unverifiable"}, "counter": 1e20,
      "deviceID": "X"},
    "transcription.language": {"value": {"type": "string", "value": "fr"}, "counter": 3,
      "deviceID": "X"}}, "devices": {}}
  """

  private static func rawEntry(_ key: String, in harness: Harness) throws -> [String: Any]? {
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.fileURL))
    return ((raw as? [String: Any])?["entries"] as? [String: Any])?[key] as? [String: Any]
  }

  // MARK: - Round 6

  @Test func firstCloudAdoptionVersionsAnEditMadeDuringIO() {
    var engine = SettingsSyncEngine(deviceID: "A")
    let snapshot: SettingsSyncEngine.Values = ["vocab.custom": .some(.string("before"))]
    let candidates = engine.candidates(snapshot, mode: .adopt)
    let cloud = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("cloud"), counter: 10, deviceID: "B")
    ])
    let result = SettingsSyncMerger.merge(local: candidates, remote: cloud, deviceID: "A", mode: .adopt)
    let current: SettingsSyncEngine.Values = ["vocab.custom": .some(.string("edited during IO"))]
    engine.noteLocalChanges(current)
    let completion = engine.complete(
      result, candidates: candidates, snapshot: snapshot, snapshotVersion: nil,
      current: current, isValid: { _, _ in true }
    )
    #expect(completion.apply.isEmpty)
    #expect(engine.records["vocab.custom"]?.version == SettingsSyncVersion(10, "B"))
    #expect(engine.pending["vocab.custom"]?.version == SettingsSyncVersion(11, "A"))
    let next = SettingsSyncMerger.merge(
      local: engine.candidates(current, mode: .normal), remote: cloud, deviceID: "A"
    )
    #expect(next.document.entries["vocab.custom"]?.value == .string("edited during IO"))
  }

  @Test(arguments: [false, true])
  func firstAdoptionAndReaddedKeysKeepInFlightUndos(readded: Bool) {
    let key = "vocab.custom"
    let value = SettingsSyncValue.string("before")
    let snapshot: SettingsSyncEngine.Values = [key: .some(value)]
    var engine = SettingsSyncEngine(deviceID: "A")
    if readded {
      engine.records[key] = .init(fingerprint: value.fingerprint, version: .init(1, "A"))
      engine.retain(keys: [])
    }
    engine.beginTransaction(snapshot)
    let candidates = engine.candidates(snapshot, mode: .adopt)
    let cloud = SettingsSyncDocument(entries: [
      key: .init(value: .string("cloud"), counter: 10, deviceID: "B")
    ])
    let result = SettingsSyncMerger.merge(local: candidates, remote: cloud, deviceID: "A", mode: .adopt)
    engine.noteLocalChanges([key: .some(.string("changed"))])
    engine.noteLocalChanges(snapshot)
    let completion = engine.complete(
      result, candidates: candidates, snapshot: snapshot, snapshotVersion: nil,
      current: snapshot, isValid: { _, _ in true }
    )
    #expect(completion.apply.isEmpty)
    #expect(engine.pending[key]?.version == SettingsSyncVersion(11, "A"))
    #expect(engine.pending[key]?.fingerprint == value.fingerprint)
  }

  @Test func repairReservesItsStampBeforeAnInFlightEdit() async throws {
    let harness = try Harness()
    let (mac, defaults) = try Self.mac(harness, "A")
    defaults.set("original", forKey: "vocab.custom")
    await mac.setEnabled(true)
    var cloud = try harness.readDocument()
    cloud.entries["transcription.language"] = .init(value: .string("en"), counter: 10, deviceID: "B")
    cloud.entries["vocab.custom"] = nil
    cloud.opaqueEntries["vocab.custom"] = Data("{\"counter\":-1}".utf8)
    try cloud.encoded().write(to: harness.fileURL, options: .atomic)
    await mac.syncNow()
    #expect(mac.counter == 10)
    mac.afterSnapshotForTesting = { [weak mac] in
      mac?.afterSnapshotForTesting = nil
      #expect(mac?.counter == 11)
      defaults.set("edit during repair", forKey: "vocab.custom")
      mac?.noteLocalChanges()
      #expect(mac?.counter == 12)
    }
    await mac.repairBlockedKeys()
    #expect(defaults.string(forKey: "vocab.custom") == "edit during repair")
    await mac.syncNow()
    #expect(try harness.readDocument().entries["vocab.custom"]?.value == .string("edit during repair"))
    #expect(try harness.readDocument().entries["vocab.custom"]?.version == SettingsSyncVersion(12, "A"))
  }

  @Test(arguments: [false, true])
  func firstEnableChoicesKeepAnEditDuringTheTransaction(replace: Bool) async throws {
    let harness = try Harness()
    let (macA, defaultsA) = try Self.mac(harness, "A")
    defaultsA.set("cloud", forKey: "vocab.custom")
    await macA.setEnabled(true)
    let (macB, defaultsB) = try Self.mac(harness, "B")
    defaultsB.set("before", forKey: "vocab.custom")
    await macB.setEnabled(true)
    macB.afterSnapshotForTesting = { [weak macB] in
      macB?.afterSnapshotForTesting = nil
      defaultsB.set("during IO", forKey: "vocab.custom")
      macB?.noteLocalChanges()
    }
    await macB.resolveFirstEnable(replace ? .replaceCloud : .useCloud)
    #expect(defaultsB.string(forKey: "vocab.custom") == "during IO")
    await macB.syncNow()
    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "during IO")
  }

  @Test func replaceNeverPromotesAnExhaustedEditFromAnotherMac() async throws {
    let harness = try Harness()
    let (macA, defaultsA) = try Self.mac(harness, "A")
    let (macB, defaultsB) = try Self.mac(harness, "B")
    defaultsA.set("start", forKey: "vocab.custom")
    await macA.setEnabled(true)
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    var b = try JSONDecoder().decode(
      SettingsSyncEngine.self, from: #require(defaultsB.data(forKey: SettingsSyncStateKey.localState))
    )
    b.latest = SettingsSyncVersion(SettingsSyncDocument.maxCounter, "B")
    defaultsB.set(try JSONEncoder().encode(b), forKey: SettingsSyncStateKey.localState)
    let relaunchedB = harness.makeService(defaultsB, name: "B")
    defaultsB.set("stale unversioned edit", forKey: "vocab.custom")
    relaunchedB.noteLocalChanges()
    await macA.setEnabled(false)
    defaultsA.set("explicit replacement", forKey: "vocab.custom")
    await macA.setEnabled(true)
    await macA.resolveFirstEnable(.replaceCloud)
    await relaunchedB.syncNow()
    await relaunchedB.syncNow()
    let cloud = try harness.readDocument()
    #expect(cloud.entries["vocab.custom"]?.value == .string("explicit replacement"))
    #expect(relaunchedB.isOrderingExhausted)
    let state = try JSONDecoder().decode(
      SettingsSyncEngine.self,
      from: #require(defaultsB.data(forKey: SettingsSyncStateKey.localState))
    )
    #expect(state.pending.isEmpty)
  }

  @Test func schemaThreeOmitsRemovedOrderingFieldsAndBlocksOlderWriters() throws {
    let document = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("x"), counter: 1, deviceID: "A")
    ])
    let root = try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
    #expect(root["schemaVersion"] as? Int == 3)
    let entries = try #require(root["entries"] as? [String: [String: Any]])
    #expect(Set(entries["vocab.custom"]?.keys ?? [:].keys) == ["value", "counter", "deviceID"])
    // Older schema-2 builds see 3 as newer and follow the existing never-write guard.
    #expect(SettingsSyncDocument.currentSchemaVersion > 2)
  }

  // MARK: - Round 5

  /// R5-1: an edit made while a sync's file IO runs (here X → Y → X, an undo) gets a newer
  /// version and survives completion, so a stale cloud value can't win over it.
  @Test func undoDuringAnInFlightSyncIsKept() {
    var engine = SettingsSyncEngine(deviceID: "A")
    let x = SettingsSyncValue.string("X")
    let y = SettingsSyncValue.string("Y")
    engine.records["vocab.custom"] = SettingsSyncLocalRecord(
      fingerprint: x.fingerprint,
      version: SettingsSyncVersion(1, "A")
    )
    engine.latest = SettingsSyncVersion(1, "A")

    let snapshot: SettingsSyncEngine.Values = ["vocab.custom": .some(x)]
    let snapshotVersion = engine.latest
    let candidates = engine.candidates(snapshot, mode: .normal)
    let remote = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: y, counter: 2, deviceID: "B")
    ])
    let merge = SettingsSyncMerger.merge(
      local: candidates,
      remote: remote,
      deviceID: "A",
      localVersion: snapshotVersion
    )
    #expect(merge.applyLocally["vocab.custom"] == .some(y))

    // During the file IO the user changes the value and then undoes it.
    engine.noteLocalChanges(["vocab.custom": .some(y)])
    engine.noteLocalChanges(["vocab.custom": .some(x)])
    #expect(engine.pending["vocab.custom"]?.version == SettingsSyncVersion(3, "A"))

    let completion = engine.complete(
      merge,
      candidates: candidates,
      snapshot: snapshot,
      snapshotVersion: snapshotVersion,
      current: ["vocab.custom": .some(x)],
      isValid: { _, _ in true }
    )
    #expect(completion.apply.isEmpty, "the stale cloud value overwrote the undo")
    #expect(engine.pending["vocab.custom"]?.version == SettingsSyncVersion(3, "A"))

    let next = SettingsSyncMerger.merge(
      local: engine.candidates(["vocab.custom": .some(x)], mode: .normal),
      remote: remote,
      deviceID: "A",
      localVersion: engine.latest
    )
    #expect(next.document.entries["vocab.custom"]?.version == SettingsSyncVersion(3, "A"))
    #expect(next.document.entries["vocab.custom"]?.value == x)
  }

  /// R5-2: provenance belongs to the apply operation, not to a time window: a deferred hop that
  /// runs after a long stall is still suppressed, while a long-lived worker explicitly started
  /// without provenance writes normally.
  @Test func provenanceHasNoTimeWindow() async throws {
    let suite = "ww.provenance.window.\(UUID().uuidString)"
    let store = try #require(SyncProvenanceUserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }

    let (hop, worker): (Task<Void, Never>, Task<Void, Never>) =
      SettingsSyncProvenance.applyingRemoteSettings {
        let hop = Task {
          try? await Task.sleep(for: .milliseconds(2_300))  // longer than the old 2 s window
          store.set("deferred default", forKey: "vocab.custom")
        }
        let worker = SettingsSyncProvenance.withoutRemoteApply {
          Task { store.set("monitor write", forKey: "beeper.response.filterKeywords") }
        }
        return (hop, worker)
      }
    await hop.value
    await worker.value
    #expect(store.object(forKey: "vocab.custom") == nil)
    #expect(store.string(forKey: "beeper.response.filterKeywords") == "monitor write")
  }

  @Test func exhaustedCountersNeverReuseVersionsOrOverwriteTheCloud() async throws {
    #expect(SettingsSyncDocument.maxCounter == 1 << 40)
    var engine = SettingsSyncEngine(deviceID: "A")
    engine.latest = SettingsSyncVersion(SettingsSyncDocument.maxCounter, "Z")
    engine.records["vocab.custom"] = SettingsSyncLocalRecord(fingerprint: nil, version: nil)
    engine.noteLocalChanges(["vocab.custom": .some(.string("x"))])
    #expect(engine.pending.isEmpty)
    #expect(engine.reserveVersion(after: nil) == nil)
    #expect(engine.isExhausted)

    let harness = try Harness()
    let (mac, defaults) = try Self.mac(harness, "A")
    defaults.set("start", forKey: "vocab.custom")
    await mac.setEnabled(true)
    var document = try harness.readDocument()
    document.entries["vocab.custom"] = .init(
      value: .string("at ceiling"), counter: SettingsSyncDocument.maxCounter, deviceID: "Z"
    )
    try document.encoded().write(to: harness.fileURL, options: .atomic)
    await mac.syncNow()
    defaults.set("local", forKey: "vocab.custom")
    mac.noteLocalChanges()
    await mac.syncNow()
    #expect(mac.isOrderingExhausted)
    #expect(mac.lastError == SettingsSyncService.exhaustedMessage)
    await mac.setEnabled(false)
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.replaceCloud)
    #expect(mac.isOrderingExhausted)
    #expect(try harness.readDocument().entries["vocab.custom"]?.value == .string("at ceiling"))
  }

  /// R5-3: a counter above the ceiling is an invalid entry (blocked, repairable).
  @Test func counterAboveTheCeilingIsBlocked() throws {
    let json = """
    {"schemaVersion": 2, "entries": {"vocab.custom": {"value": {"type": "string",
      "value": "x"}, "counter": \(SettingsSyncDocument.maxCounter + 1), "deviceID": "Z"}},
      "devices": {}}
    """
    let document = try SettingsSyncDocument.decode(Data(json.utf8))
    #expect(document.entries.isEmpty)
    #expect(document.opaqueEntries["vocab.custom"] != nil)
  }

  /// R5-5: a key dropped from the allowlist by one app version is forgotten; when a later
  /// version syncs it again it starts unversioned and takes the cloud's value.
  @Test func keyReaddedToTheAllowlistStartsFresh() {
    var engine = SettingsSyncEngine(deviceID: "A")
    engine.records["llm.model"] = SettingsSyncLocalRecord(
      fingerprint: SettingsSyncValue.string("old").fingerprint,
      version: SettingsSyncVersion(5, "A")
    )
    engine.pending["llm.model"] = SettingsSyncLocalRecord(
      fingerprint: nil,
      version: SettingsSyncVersion(6, "A")
    )
    engine.retain(keys: ["vocab.custom"])
    #expect(engine.records["llm.model"] == nil)
    #expect(engine.pending["llm.model"] == nil)
    let candidates = engine.candidates(["llm.model": .some(.string("local"))], mode: .normal)
    #expect(candidates["llm.model"]?.version == nil)
  }

  /// R3: a Mac whose wall clock is two days behind, after choosing "Use iCloud", takes the
  /// cloud values and never uploads its stale ones; repeated syncs don't flip-flop.
  @Test func wallClockSkewNeverChangesTheWinner() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("current", forKey: "vocab.custom")
    defaultsA.set("fr", forKey: "transcription.language")
    let macA = harness.makeService(defaultsA, name: "Mac A", clockOffset: 2 * 86_400)
    await macA.setEnabled(true)

    defaultsB.set("stale", forKey: "vocab.custom")
    defaultsB.set("en", forKey: "transcription.language")
    let macB = harness.makeService(defaultsB, name: "Mac B", clockOffset: -2 * 86_400)
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)
    #expect(defaultsB.string(forKey: "vocab.custom") == "current")
    #expect(defaultsB.string(forKey: "transcription.language") == "fr")

    let file = try Data(contentsOf: harness.fileURL)
    let writesA = macA.writeCount
    let writesB = macB.writeCount
    for _ in 0..<3 {
      harness.tick()
      await macA.syncNow()
      await macB.syncNow()
    }
    #expect(try Data(contentsOf: harness.fileURL) == file)
    #expect(macA.writeCount == writesA && macB.writeCount == writesB)
    #expect(defaultsA.string(forKey: "vocab.custom") == "current")
    #expect(defaultsB.string(forKey: "vocab.custom") == "current")
  }

  /// R3: "Replace iCloud" is authoritative even against high counters, and a setting absent
  /// on this Mac is written as a reset; the first-enable mode clears only once that is saved.
  @Test func replaceICloudWritesResetsAgainstHighCounters() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    try SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("cloud"), counter: 50_000, deviceID: "ZZZZ"),
      "transcription.language": .init(value: .string("fr"), counter: 70_000, deviceID: "ZZZZ")
    ]).encoded().write(to: harness.fileURL)

    let defaults = try harness.makeDefaults()
    defaults.set("this mac", forKey: "vocab.custom")
    let mac = harness.makeService(defaults, name: "Mac B")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.replaceCloud)

    let document = try harness.readDocument()
    #expect(document.entries["vocab.custom"]?.value == .string("this mac"))
    #expect((document.entries["vocab.custom"]?.counter ?? 0) > 50_000)
    #expect(document.entries["transcription.language"].map { $0.value == nil } == true)
    #expect((document.entries["transcription.language"]?.counter ?? 0) > 70_000)
    #expect(defaults.string(forKey: "vocab.custom") == "this mac")
    #expect(defaults.object(forKey: SettingsSyncStateKey.firstEnableMode) == nil)
  }

  /// R3: a pending edit keeps the counter it was stamped with when seen; a slow upload doesn't
  /// re-stamp it, and it still wins over the value it replaced.
  @Test func pendingEditKeepsItsCounterUntilUploaded() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    defaultsA.set("from A", forKey: "vocab.custom")
    let macA = harness.makeService(defaultsA, name: "Mac A", clockOffset: 10 * 3_600)
    await macA.setEnabled(true)
    let macB = harness.makeService(defaultsB, name: "Mac B")
    await macB.setEnabled(true)
    await macB.resolveFirstEnable(.useCloud)

    defaultsB.set("edit on B", forKey: "vocab.custom")
    macB.noteLocalChanges()
    let stamped = macB.counter
    harness.tick(3_600)  // the upload happens much later
    await macB.syncNow()
    #expect(try harness.readDocument().entries["vocab.custom"]?.counter == stamped)

    await macA.syncNow()
    #expect(defaultsA.string(forKey: "vocab.custom") == "edit on B")
  }

  /// R3: pending conflict-version work is retried even when the file's modification date is
  /// unchanged, and notices are recomputed (and cleared) on syncs that write nothing.
  @Test func deferredWorkIsRetriedAndStaleNoticesClear() async throws {
    let harness = try Harness()
    let conflicts = FakeConflictVersions()
    let defaults = try harness.makeDefaults()
    defaults.set("en", forKey: "transcription.language")
    let mac = harness.makeService(defaults, name: "Mac A", conflicts: conflicts.source)
    await mac.setEnabled(true)
    #expect(!mac.hasDeferredRemoteWork())

    let pending = conflicts.add(nil)
    await mac.syncNow()
    #expect(mac.pendingConflictCount == 1)
    #expect(mac.hasDeferredRemoteWork(), "a poll must retry even with an unchanged file")
    #expect(mac.notice?.contains("Waiting to merge 1") == true)

    conflicts.setData(pending, try SettingsSyncDocument(entries: [
      "transcription.language": .init(value: .string("fr"), counter: 900, deviceID: "OFFLINE")
    ]).encoded())
    await mac.syncNow()
    #expect(defaults.string(forKey: "transcription.language") == "fr")
    #expect(!mac.hasDeferredRemoteWork())
    #expect(mac.notice == nil)

    // A rejected value produces a notice; once the cloud value is fixed elsewhere, a sync that
    // writes nothing clears it.
    var document = try harness.readDocument()
    document.entries["llm.temperature"] = .init(value: .string("hot"), counter: 2_000,
                                                deviceID: "X")
    try document.encoded().write(to: harness.fileURL, options: .atomic)
    await mac.syncNow()
    #expect(mac.notice?.contains("Ignored 1 setting") == true)
    document.entries["llm.temperature"] = .init(value: .double(0.4), counter: 2_001,
                                                deviceID: "X")
    try document.encoded().write(to: harness.fileURL, options: .atomic)
    let writes = mac.writeCount
    await mac.syncNow()
    #expect(mac.writeCount == writes)
    #expect(mac.notice == nil)
  }

  /// R3: a schema-1 file (wall-clock `modifiedAt`, no counters) keeps its values, loses its
  /// ordering metadata, and is rewritten as schema 2.
  @Test func schemaOneDocumentIsMigrated() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "entries": {
        "vocab.custom": {"value": {"type": "string", "value": "from v1"},
          "modifiedAt": 4102444800000, "deviceID": "OLD"}
      },
      "devices": {"OLD": {"name": "Old Mac", "lastWriteAt": 1000}}
    }
    """
    try Data(json.utf8).write(to: harness.fileURL)
    let decoded = try SettingsSyncDocument.decode(Data(json.utf8))
    #expect(decoded.entries["vocab.custom"]?.counter == 0)

    let defaults = try harness.makeDefaults()
    defaults.set("de", forKey: "transcription.language")
    let mac = harness.makeService(defaults, name: "Mac A")
    await mac.setEnabled(true)
    await mac.resolveFirstEnable(.useCloud)
    #expect(defaults.string(forKey: "vocab.custom") == "from v1")
    let migrated = try harness.readDocument()
    #expect(migrated.schemaVersion == SettingsSyncDocument.currentSchemaVersion)
    let raw = try String(contentsOf: harness.fileURL, encoding: .utf8)
    #expect(!raw.contains("modifiedAt"))
  }

  /// R2-5: cancelling after the merge is prepared but before the commit stops the save, the
  /// quarantine backup and the conflict cleanup.
  @Test func cancelInsideTheCommitGapStopsTheWrite() throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let corrupt = Data("{ broken".utf8)
    try corrupt.write(to: harness.fileURL)
    let conflicts = FakeConflictVersions()
    conflicts.add(try SettingsSyncDocument(entries: [
      "llm.model": .init(value: .string("offline"), counter: 1, deviceID: "O")
    ]).encoded())
    let token = SettingsSyncCancellation()
    let store = SettingsSyncFileStore(
      directory: harness.folder,
      conflicts: conflicts.source,
      beforeCommit: { token.cancel() }  // sync turned off while encoding/preparing
    )
    let input = SettingsSyncFileStore.TransactionInput(
      local: ["vocab.custom": .init(value: .string("x"), version: SettingsSyncVersion(1, "A"))],
      deviceID: "A",
      deviceName: "Mac A",
      timestamp: harness.clock
    )
    let outcome = try store.transact(input, cancellation: token)

    #expect(outcome.cancelled)
    #expect(!outcome.wrote)
    #expect(try Data(contentsOf: harness.fileURL) == corrupt)
    let names = try FileManager.default.contentsOfDirectory(atPath: harness.folder.path)
    #expect(!names.contains { $0.hasPrefix("settings.unreadable-") })
    #expect(conflicts.resolvedCount == 0)
    #expect(conflicts.finishCount == 0)
  }

  /// R2-6: a received reset (key removed) puts live settings back to their launch defaults
  /// without the property side effects recreating the removed keys.
  @Test func receivedResetsRestoreLaunchDefaults() async throws {
    let defaults = AppConfig.defaults
    let keys: Set<String> = [
      AppConfig.responseWindowFontSizeKey, "history.maxEntries",
      "pasteShortcut.keyCode", "pasteShortcut.modifiers"
    ]
    defer { keys.forEach { defaults.removeObject(forKey: $0) } }
    let vm = DictationViewModel()
    // Retention only moves between values at or above the loaded page, so no real history
    // entry can ever be trimmed by this test.
    try #require(vm.history.entries.count <= DictationViewModel.defaultHistoryMaxEntries)

    defaults.set(21.0, forKey: AppConfig.responseWindowFontSizeKey)
    defaults.set(1000, forKey: "history.maxEntries")
    defaults.set(9, forKey: "pasteShortcut.keyCode")
    defaults.set(256, forKey: "pasteShortcut.modifiers")
    vm.applySyncedSettings(changedKeys: keys)
    #expect(vm.responseWindowFontSize == 21)
    #expect(vm.history.maxEntries == 1000)
    #expect(vm.pasteShortcut == HotkeyManager.Shortcut(keyCode: 9, modifiers: 256))

    keys.forEach { defaults.removeObject(forKey: $0) }
    vm.applySyncedSettings(changedKeys: keys)
    #expect(vm.responseWindowFontSize == DictationViewModel.defaultResponseWindowFontSize)
    #expect(vm.history.maxEntries == DictationViewModel.defaultHistoryMaxEntries)
    #expect(vm.pasteShortcut == DictationViewModel.defaultPasteShortcut)
    // Checked before yielding the main actor: the didSet writes must already be undone.
    for key in keys {
      #expect(defaults.object(forKey: key) == nil, "\(key) was recreated")
    }

    // And still gone after deferred persistence hops. The paste shortcut is left out here:
    // other suites running in parallel create view models whose init writes it to the shared
    // scratch defaults.
    try await Task.sleep(for: .milliseconds(100))
    for key in [AppConfig.responseWindowFontSizeKey, "history.maxEntries"] {
      #expect(defaults.object(forKey: key) == nil, "\(key) was recreated later")
    }
  }

  /// R3-5: an edit made right after a received reset, before any deferred work runs, is kept:
  /// nothing removes the key again later.
  @Test func editRightAfterAReceivedResetIsKept() async throws {
    let defaults = AppConfig.defaults
    let key = AppConfig.responseWindowFontSizeKey
    defer { defaults.removeObject(forKey: key) }
    let vm = DictationViewModel()
    defaults.set(21.0, forKey: key)
    vm.applySyncedSettings(changedKeys: [key])

    defaults.removeObject(forKey: key)
    vm.applySyncedSettings(changedKeys: [key])
    vm.responseWindowFontSize = 25  // the user edits before the main actor yields

    try await Task.sleep(for: .milliseconds(100))
    #expect(vm.responseWindowFontSize == 25)
    #expect(defaults.object(forKey: key) as? Double == 25)
  }

  /// Earlier standalone state keys are deleted on launch, and counters at the limit never
  /// overflow: at the ceiling nothing new is stamped (and no version is reused).
  @Test func legacyStateIsDeletedAndCountersNeverOverflow() throws {
    let harness = try Harness()
    let defaults = try harness.makeDefaults()
    defaults.set(NSNumber(value: Int64.max), forKey: SettingsSyncStateKey.legacyCounter)
    let year2100Millis = NSNumber(value: Int64(4_102_444_800_000))
    defaults.set(year2100Millis, forKey: SettingsSyncStateKey.legacyClock)
    _ = harness.makeService(defaults, name: "Mac A")
    #expect(defaults.object(forKey: SettingsSyncStateKey.legacyCounter) == nil)
    #expect(defaults.object(forKey: SettingsSyncStateKey.legacyClock) == nil)

    var engine = SettingsSyncEngine(deviceID: "A")
    engine.latest = SettingsSyncVersion(SettingsSyncDocument.maxCounter, "A")
    engine.records["vocab.custom"] = SettingsSyncLocalRecord(fingerprint: nil, version: nil)
    engine.noteLocalChanges(["vocab.custom": .some(.string("x"))])
    #expect(engine.counter == SettingsSyncDocument.maxCounter)
    #expect(engine.pending.isEmpty, "a version was reused at the ceiling")

    let atLimit = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("x"), counter: SettingsSyncDocument.maxCounter,
                            deviceID: "Z")
    ])
    let replaced = SettingsSyncMerger.merge(
      local: ["vocab.custom": .init(value: .string("y"), version: nil)],
      remote: atLimit,
      deviceID: "A",
      mode: .replace
    )
    #expect(replaced.exhausted)
    #expect(replaced.document.entries["vocab.custom"]?.value == .string("x"))
  }

  @Test func statusLineReadsNaturally() {
    let date = Date()
    let text = { SettingsSyncSection.statusText(lastSyncedAt: date, deviceCount: $0) }
    #expect(text(2).hasSuffix("· 2 Macs"))
    #expect(text(1).hasSuffix("· 1 Mac"))
    #expect(text(nil).hasPrefix("Synced"))
  }
}

/// Stands in for `NSFileVersion` conflict versions, which only iCloud itself can create.
/// Each version has an identity; resolving one removes only that one. `finish` mirrors
/// `removeOtherVersionsOfItem` and clears everything.
private final class FakeConflictVersions: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [(id: UUID, data: Data?)] = []
  private var resolved = 0
  private var finished = 0

  @discardableResult
  func add(_ data: Data?) -> UUID {
    let id = UUID()
    lock.withLock { stored.append((id, data)) }
    return id
  }

  func setData(_ id: UUID, _ data: Data?) {
    lock.withLock {
      if let index = stored.firstIndex(where: { $0.id == id }) { stored[index].data = data }
    }
  }

  var remainingCount: Int { lock.withLock { stored.count } }
  var resolvedCount: Int { lock.withLock { resolved } }
  var finishCount: Int { lock.withLock { finished } }

  var source: SettingsSyncConflictSource {
    SettingsSyncConflictSource(
      unresolved: { [self] _ in
        lock.withLock { stored }.map { version in
          SettingsSyncConflictSource.Version(data: version.data) { [self] in
            lock.withLock {
              resolved += 1
              stored.removeAll { $0.id == version.id }
            }
          }
        }
      },
      finish: { [self] _ in
        lock.withLock {
          finished += 1
          stored = []
        }
      }
    )
  }
}
