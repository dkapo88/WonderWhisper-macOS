import Foundation
import Testing
@testable import WonderWhisper

/// iCloud settings sync, run entirely against temp folders and throwaway UserDefaults suites.
/// Nothing here touches the real iCloud Drive folder or the user's preferences.
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

    /// - Parameter clockOffset: how far this Mac's wall clock is ahead of the shared clock.
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

    // Concurrent edits: A edits vocabulary first, B edits it later, and A also edits language.
    // In the app the defaults change notification calls `noteLocalChanges()` at edit time.
    harness.tick()
    defaultsA.set("from A", forKey: "vocab.custom")
    defaultsA.set("fr", forKey: "transcription.language")
    macA.noteLocalChanges()
    harness.tick()
    defaultsB.set("from B", forKey: "vocab.custom")
    macB.noteLocalChanges()
    harness.tick()

    await macB.syncNow()
    // A syncs last, but its vocabulary edit is older than B's; its language edit is new.
    await macA.syncNow()
    await macB.syncNow()

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
    let date = Date(timeIntervalSince1970: 100)
    let remote = SettingsSyncDocument(entries: [
      "vocab.custom": .init(value: .string("remote"), modifiedAt: date, deviceID: "AAAA")
    ])
    let local = [
      "vocab.custom": SettingsSyncMerger.LocalEntry(value: .string("local"), modifiedAt: date)
    ]
    let higher = SettingsSyncMerger.merge(local: local, remote: remote, deviceID: "ZZZZ")
    #expect(higher.documentChanged)
    #expect(higher.applyLocally.isEmpty)
    let lower = SettingsSyncMerger.merge(local: local, remote: remote, deviceID: "0000")
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

  @Test func unknownKeysAndValueTypesAreIgnoredButKept() async throws {
    let harness = try Harness()
    try FileManager.default.createDirectory(at: harness.folder, withIntermediateDirectories: true)
    let json = """
    {
      "schemaVersion": 1,
      "entries": {
        "future.setting": {"value": {"type": "string", "value": "x"}, "modifiedAt": 1000,
          "deviceID": "OTHER"},
        "vocab.spelling": {"value": {"type": "hologram", "value": 3}, "modifiedAt": 1000,
          "deviceID": "OTHER"},
        "vocab.custom": {"value": {"type": "string", "value": "cloud"}, "modifiedAt": 1000,
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
    let document = try harness.readDocument()
    #expect(document.entries["future.setting"]?.value == .string("x"))
    #expect(document.entries["vocab.spelling"]?.value == .string("mine"))
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
          modifiedAt: Date(timeIntervalSince1970: 1000),
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
    let clock = harness.clock
    mac.beforeTransactionForTesting = { [weak mac] in
      mac?.beforeTransactionForTesting = nil
      var installed = try? SettingsSyncDocument.decode(Data(contentsOf: fileURL))
      installed?.entries["transcription.language"] = .init(
        value: .string("de"),
        modifiedAt: clock,
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
      "vocab.custom": .init(value: .string("repaired"), modifiedAt: harness.clock, deviceID: "B")
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
          modifiedAt: harness.clock,
          deviceID: "OFFLINE"
        )
      ],
      devices: ["OFFLINE": .init(name: "Offline Mac", lastWriteAt: harness.clock)]
    )
    conflicts.versions = [try losingVersion.encoded()]
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
    conflicts.versions = [try SettingsSyncDocument().encoded()]
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
    defaultsA.removeObject(forKey: "vocab.spelling")
    macA.noteLocalChanges()
    harness.tick()
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
      local: ["vocab.custom": .init(value: .string("x"), modifiedAt: harness.clock)],
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
    let later = harness.clock
    hostile.entries["pasteShortcut.keyCode"] = .init(
      value: .int(-1),
      modifiedAt: later,
      deviceID: "X"
    )
    hostile.entries["simple.dictation.settings"] = .init(
      value: .data(Data("not json".utf8)),
      modifiedAt: later,
      deviceID: "X"
    )
    hostile.entries["vocab.custom"] = .init(value: .int(5), modifiedAt: later, deviceID: "X")
    hostile.entries["simple.voice.engine"] = .init(
      value: .string("no-such-engine"),
      modifiedAt: later,
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
    #expect(SettingsSyncRegistry.excluded[SettingsSyncStateKey.clock] != nil)
  }

  private nonisolated static func requireSendable<T: Sendable>(_: T.Type) {}

  @Test func statusLineReadsNaturally() {
    let date = Date()
    let text = { SettingsSyncSection.statusText(lastSyncedAt: date, deviceCount: $0) }
    #expect(text(2).hasSuffix("· 2 Macs"))
    #expect(text(1).hasSuffix("· 1 Mac"))
    #expect(text(nil).hasPrefix("Synced"))
  }
}

/// Stands in for `NSFileVersion` conflict versions, which only iCloud itself can create.
private final class FakeConflictVersions: @unchecked Sendable {
  private let lock = NSLock()
  private var storedVersions: [Data] = []
  private var resolved = 0
  private var finished = 0

  var versions: [Data] {
    get { lock.withLock { storedVersions } }
    set { lock.withLock { storedVersions = newValue } }
  }

  var resolvedCount: Int { lock.withLock { resolved } }
  var finishCount: Int { lock.withLock { finished } }

  var source: SettingsSyncConflictSource {
    SettingsSyncConflictSource(
      unresolved: { [self] _ in
        versions.map { data in
          SettingsSyncConflictSource.Version(data: data) { [self] in
            lock.withLock { resolved += 1 }
          }
        }
      },
      finish: { [self] _ in
        lock.withLock {
          finished += 1
          storedVersions = []
        }
      }
    )
  }
}
