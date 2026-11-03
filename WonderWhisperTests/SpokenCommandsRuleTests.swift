import Foundation
import Testing
@testable import WonderWhisper

/// The spoken formatting commands cleanup rule, how it reaches existing installs, and the
/// raw paths (cleanup off, cleanup failure) that keep the words as spoken.
@Suite(.serialized)
struct SpokenCommandsRuleTests {
  private static let ruleMarker = "- Apply spoken formatting commands"

  private static var currentDefault: String { SimpleModeDefaults.defaultRules(for: .dictation) }

  /// The default before this rule: the current default without the spoken commands line.
  private static var previousDefault: String {
    currentDefault
      .components(separatedBy: "\n")
      .filter { !$0.hasPrefix(ruleMarker) }
      .joined(separator: "\n")
  }

  private static var spokenCommandsLine: String? {
    currentDefault.components(separatedBy: "\n").first { $0.hasPrefix(ruleMarker) }
  }

  // MARK: - Prompt content

  @Test func defaultRulesCarryOneBoundedSpokenCommandsBulletUnderPunctuation() throws {
    let lines = Self.currentDefault.components(separatedBy: "\n")
    #expect(lines.filter { $0.hasPrefix(Self.ruleMarker) }.count == 1)
    let line = try #require(Self.spokenCommandsLine)

    // It sits inside the Punctuation & Formatting section.
    let section = try #require(Self.currentDefault
      .components(separatedBy: "\n\n- **")
      .first { $0.hasPrefix("Punctuation & Formatting**") })
    #expect(section.contains(line))

    for command in [
      "\"new line\" → line break", "\"new paragraph\" → blank line",
      "\"period\" or \"full stop\" → \".\"", "\"comma\" → \",\"",
      "\"question mark\" → \"?\"", "\"exclamation mark\" → \"!\""
    ] {
      #expect(line.contains(command), "\(command)")
    }
    #expect(line.contains("words of this transcript only"))
    #expect(line.contains(
      "\"scratch that\" → drop the sentence spoken just before it in this transcript, "
        + "never earlier dictations, selected text or anything else in the app"
    ))
    #expect(line.contains("Keep literal and quoted uses as words"))
    #expect(line.contains("\"the trial period\""))
    #expect(line.contains("\"type the words new line\""))
    #expect(!line.contains("—") && !line.contains("–"))
  }

  @Test func theRuleReachesTheCleanupPromptForEveryEngine() {
    let settings = SimpleModeDefaults.settings(for: .dictation)
    let prompts = SimpleVoiceEngine.allCases.map { engine in
      SimplePromptComposer.configuration(
        for: .dictation,
        settings: settings,
        llmModel: SimpleModeDefaults.defaultModelID,
        voiceModel: engine.transcriptionModel
      ).systemPrompt
    }
    #expect(Set(prompts).count == 1)
    #expect(prompts.allSatisfy { $0.contains(Self.ruleMarker) })
  }

  @Test func commandModeAndMeetingNotesDoNotCarryTheRule() {
    #expect(!SimpleModeDefaults.defaultRules(for: .command).contains("scratch that"))
    #expect(!MeetingNoteGenerator.systemPrompt(customPrompt: "").contains("scratch that"))
    #expect(!MeetingNoteGenerator.systemPrompt(customPrompt: "").contains("new paragraph"))
  }

  @Test func builtInDefaultTemplateCarriesTheNewRules() {
    let template = SimplePromptTemplateLibrary.builtInDictationTemplates
      .first { $0.id == SimplePromptTemplateLibrary.defaultTemplateID }
    #expect(template?.rules == Self.currentDefault)
  }

  // MARK: - Upgrade

  @Test func onlyAnExactPreviousDefaultIsUpgraded() {
    #expect(SimpleModeDefaults.upgradedDictationRules(Self.previousDefault) == Self.currentDefault)
    #expect(SimpleModeDefaults.upgradedDictationRules(Self.currentDefault) == nil)
    #expect(SimpleModeDefaults.upgradedDictationRules(Self.previousDefault + " ") == nil)
    #expect(SimpleModeDefaults.upgradedDictationRules(Self.previousDefault + "\n\n- Mine") == nil)
    #expect(SimpleModeDefaults.upgradedDictationRules("- Keep it short") == nil)
    #expect(SimpleModeDefaults.upgradedDictationRules("") == nil)
  }

  private static func suite() -> (UserDefaults, String) {
    let name = "SpokenCommandsRuleTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
  }

  private static func store(_ settings: SimplePromptSettings, kind: SimplePromptKind, in defaults: UserDefaults) throws {
    let key = kind == .dictation ? SimpleDefaultsKey.dictationSettings : SimpleDefaultsKey.commandSettings
    defaults.set(try JSONEncoder().encode(settings), forKey: key)
  }

  private static func saved(_ kind: SimplePromptKind, in defaults: UserDefaults) throws -> SimplePromptSettings {
    let key = kind == .dictation ? SimpleDefaultsKey.dictationSettings : SimpleDefaultsKey.commandSettings
    let data = try #require(defaults.data(forKey: key))
    return try JSONDecoder().decode(SimplePromptSettings.self, from: data)
  }

  @MainActor @Test func freshInstallGetsTheNewRules() {
    let (defaults, name) = Self.suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let loaded = DictationViewModel.loadSimpleSettings(for: .dictation, defaults: defaults)
    #expect(loaded.rules == Self.currentDefault)
    #expect(loaded.rules.contains(Self.ruleMarker))
  }

  @MainActor @Test func savedUnchangedPreviousDefaultIsUpgradedOnceAndOtherSettingsStay() throws {
    let (defaults, name) = Self.suite()
    defer { defaults.removePersistentDomain(forName: name) }
    var old = SimpleModeDefaults.settings(for: .dictation)
    old.rules = Self.previousDefault
    old.header = "My own header"
    old.footer = "My own footer"
    old.enableScreenContext = false
    old.enableClipboardContext = true
    old.enableSelectedText = true
    old.enableActiveTextField = false
    old.includeScreenImage = true
    try Self.store(old, kind: .dictation, in: defaults)
    let command = SimplePromptSettings(
      rules: "- my command rules", header: "cmd header", footer: "cmd footer",
      enableScreenContext: false, enableClipboardContext: true, enableSelectedText: true,
      enableActiveTextField: false, selection: .rightOption, includeScreenImage: false
    )
    try Self.store(command, kind: .command, in: defaults)
    let templates = Data("[{\"custom\":true}]".utf8)
    defaults.set(templates, forKey: SimpleDefaultsKey.dictationPromptTemplates)
    let commandData = defaults.data(forKey: SimpleDefaultsKey.commandSettings)

    let loaded = DictationViewModel.loadSimpleSettings(for: .dictation, defaults: defaults)
    var expected = old
    expected.rules = Self.currentDefault
    #expect(loaded == expected)
    #expect(try Self.saved(.dictation, in: defaults) == expected)

    // Relaunch: same result, nothing rewritten.
    let afterFirstLoad = defaults.data(forKey: SimpleDefaultsKey.dictationSettings)
    let relaunched = DictationViewModel.loadSimpleSettings(for: .dictation, defaults: defaults)
    #expect(relaunched == expected)
    #expect(defaults.data(forKey: SimpleDefaultsKey.dictationSettings) == afterFirstLoad)

    // Command settings and prompt templates are untouched.
    #expect(DictationViewModel.loadSimpleSettings(for: .command, defaults: defaults) == command)
    #expect(defaults.data(forKey: SimpleDefaultsKey.commandSettings) == commandData)
    #expect(defaults.data(forKey: SimpleDefaultsKey.dictationPromptTemplates) == templates)
  }

  @MainActor @Test func customisedRulesAreNeverTouched() throws {
    let (defaults, name) = Self.suite()
    defer { defaults.removePersistentDomain(forName: name) }
    for custom in [
      Self.previousDefault + "\n\n- Always sign off with Cheers",
      Self.previousDefault.replacingOccurrences(of: "British", with: "American"),
      "- Keep it short"
    ] {
      var settings = SimpleModeDefaults.settings(for: .dictation)
      settings.rules = custom
      try Self.store(settings, kind: .dictation, in: defaults)
      let data = defaults.data(forKey: SimpleDefaultsKey.dictationSettings)
      let loaded = DictationViewModel.loadSimpleSettings(for: .dictation, defaults: defaults)
      #expect(loaded.rules == custom)
      #expect(defaults.data(forKey: SimpleDefaultsKey.dictationSettings) == data)
    }
  }

  @MainActor @Test func legacyRuleArrayMatchingThePreviousDefaultIsUpgraded() throws {
    let (defaults, name) = Self.suite()
    defer { defaults.removePersistentDomain(forName: name) }
    // The pre-string format: one rule object per bullet, joined on decode.
    let rules = Self.previousDefault
      .components(separatedBy: "\n\n- ")
      .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
      .map { ["id": UUID().uuidString, "text": $0] }
    let legacy: [String: Any] = [
      "rules": rules, "header": "", "footer": "",
      "enableScreenContext": true, "enableClipboardContext": false, "enableSelectedText": false
    ]
    defaults.set(
      try JSONSerialization.data(withJSONObject: legacy),
      forKey: SimpleDefaultsKey.dictationSettings
    )
    let loaded = DictationViewModel.loadSimpleSettings(for: .dictation, defaults: defaults)
    #expect(loaded.rules == Self.currentDefault)
  }

  // MARK: - Raw paths keep the words as spoken

  actor ScriptedTranscriber: TranscriptionProvider {
    let text: String
    init(_ text: String) { self.text = text }
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String { text }
  }

  private static let spoken =
    "book the room for Tuesday scratch that book it for Wednesday new line "
    + "the trial period ends on the 15th full stop"

  private func runDictation(llmEnabled: Bool) async -> [String] {
    let recorder = DictationControllerSessionTests.FakeRecorder(
      samples: DictationAudioFixtures.sine(seconds: 0.5, rmsDBFS: -25)
    )
    let inserter = DictationControllerSessionTests.FakeInserter()
    var llmSettings = LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: "test")
    llmSettings = LLMSettings(
      endpoint: llmSettings.endpoint,
      model: llmSettings.model,
      systemPrompt: SimplePromptComposer.systemPrompt(
        settings: SimpleModeDefaults.settings(for: .dictation)
      )
    )
    let controller = DictationController(
      recorder: recorder,
      transcriber: ScriptedTranscriber(Self.spoken),
      transcriberSettings: TranscriptionSettings(
        endpoint: URL(string: "https://localhost")!, model: "parakeet-local"
      ),
      // No key: every cleanup request fails before reaching the network.
      llm: OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { nil })),
      llmSettings: llmSettings,
      inserter: inserter,
      releaseTail: 0
    )
    await controller.updateLLMEnabled(llmEnabled)
    await controller.updateScreenContextEnabled(false)
    await controller.updateClipboardContextEnabled(false)
    await controller.updateSelectedTextEnabled(false)
    await controller.updateActiveTextFieldEnabled(false)
    await controller.toggle(userPrompt: "")
    await controller.finish(userPrompt: "")
    if let url = recorder.recordingURL { try? FileManager.default.removeItem(at: url) }
    return inserter.inserted
  }

  @Test func cleanupOffInsertsTheCommandsAsSpokenWords() async {
    #expect(await runDictation(llmEnabled: false) == [Self.spoken + " "])
  }

  @Test func cleanupFailureInsertsTheCommandsAsSpokenWords() async {
    #expect(await runDictation(llmEnabled: true) == [Self.spoken + " "])
  }
}
