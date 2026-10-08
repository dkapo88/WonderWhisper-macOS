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

    func makeService(_ defaults: UserDefaults, name: String) -> SettingsSyncService {
      SettingsSyncService(
        defaults: defaults,
        directory: folder,
        iCloudRoot: root,
        deviceName: name,
        now: { [unowned self] in self.clock },
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

  /// A deterministic value of a rotating type for each key, so every plist type is exercised.
  private static func sampleValue(for key: String, index: Int) -> SettingsSyncValue {
    switch index % 6 {
    case 0: return .string("value-\(key)")
    case 1: return .bool(index % 4 == 1)
    case 2: return .int(index * 7)
    case 3: return .double(Double(index) + 0.25)
    case 4: return .strings(["a-\(index)", "b-\(key)"])
    default: return .data(Data("{\"key\":\"\(key)\",\"n\":\(index)}".utf8))
    }
  }

  // MARK: - Round trip

  @Test func everyAllowlistedKeyRoundTripsToAnotherMac() async throws {
    let harness = try Harness()
    let defaultsA = try harness.makeDefaults()
    let defaultsB = try harness.makeDefaults()
    let keys = SettingsSyncRegistry.synced.map(\.key)
    for (index, key) in keys.enumerated() {
      SettingsSyncValue.write(Self.sampleValue(for: key, index: index), key: key, to: defaultsA)
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

    for (index, key) in keys.enumerated() {
      #expect(
        SettingsSyncValue.read(key, from: defaultsB) == Self.sampleValue(for: key, index: index),
        "\(key) did not round-trip"
      )
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

  @Test func statusLineReadsNaturally() {
    let date = Date()
    let text = { SettingsSyncSection.statusText(lastSyncedAt: date, deviceCount: $0) }
    #expect(text(2).hasSuffix("· 2 Macs"))
    #expect(text(1).hasSuffix("· 1 Mac"))
    #expect(text(nil).hasPrefix("Synced"))
  }
}
