import Foundation

/// The single list of preferences that iCloud settings sync carries between Macs.
///
/// Sync is an explicit allowlist: a UserDefaults key travels only if it is listed in `synced`.
/// To sync a new preference, add its existing key here (never rename the key itself) with the
/// shape a received value must have, and, if a view model caches the value, re-read it in
/// `SettingsSyncLiveApply.swift`. API keys live in the Keychain and are never read by sync.
enum SettingsSyncRegistry {
  enum Group: String, CaseIterable, Sendable {
    case vocabulary
    case prompts
    case models
    case modelSelection
    case transcription
    case meetings
    case beeper
    case hotkeys
    case general
  }

  /// JSON payloads stored as Data, each checked by decoding with the type that reads it.
  enum JSONShape: Hashable, Sendable {
    case promptSettings
    case promptTemplates
    case favoriteModels
    case beeperChats
    case meetingTriggerRules
  }

  /// What a received value must look like before it may replace this Mac's value.
  enum Expectation: Hashable, Sendable {
    case bool
    case string
    case oneOf(Set<String>)
    case int(ClosedRange<Int>)
    case double(ClosedRange<Double>)
    case strings
    case json(JSONShape)
  }

  struct Setting: Hashable, Sendable {
    let key: String
    let group: Group
    let expect: Expectation

    init(_ key: String, _ group: Group, _ expect: Expectation) {
      self.key = key
      self.group = group
      self.expect = expect
    }
  }

  private static let reasoningModes = Set(OpenRouterReasoningMode.allCases.map(\.rawValue))
  private static let voiceEngines = Set(SimpleVoiceEngine.allCases.map(\.rawValue))
  private static let meetingEngines = Set(MeetingTranscriptionEngine.allCases.map(\.rawValue))
  private static let hotkeys = Set(HotkeyManager.Selection.allCases.map(\.rawValue))
  private static let captureModes = Set(ScreenContextCaptureMode.allCases.map(\.rawValue))
  private static let seconds: Expectation = .double(1...600)

  static let synced: [Setting] = [
    // Vocabulary
    Setting("vocab.custom", .vocabulary, .string),
    Setting("vocab.spelling", .vocabulary, .string),
    Setting("qwen.injectVocabulary", .vocabulary, .bool),

    // Dictation and Command prompts (header/rules/footer, context toggles, hotkey) + templates
    Setting("simple.dictation.settings", .prompts, .json(.promptSettings)),
    Setting("simple.command.settings", .prompts, .json(.promptSettings)),
    Setting("simple.dictation.promptTemplates", .prompts, .json(.promptTemplates)),

    // Favorite and custom models
    Setting("simple.openrouter.favorites", .models, .json(.favoriteModels)),
    Setting("simple.model.custom", .models, .strings),

    // Current LLM selection, routing and reasoning
    Setting("simple.model.selected", .modelSelection, .string),
    Setting("llm.model", .modelSelection, .string),
    Setting("simple.llm.enabled", .modelSelection, .bool),
    Setting("llm.enabled", .modelSelection, .bool),
    Setting("llm.openrouter.routing", .modelSelection, .string),
    Setting("llm.openrouter.reasoning", .modelSelection, .oneOf(reasoningModes)),
    Setting("llm.temperature", .modelSelection, .double(0...2)),

    // Transcription engine, model and language
    Setting("simple.voice.engine", .transcription, .oneOf(voiceEngines)),
    Setting("transcription.model", .transcription, .string),
    Setting("transcription.language", .transcription, .string),
    Setting("transcription.openrouter.model", .transcription, .string),
    Setting("transcription.timeout", .transcription, seconds),
    // Free-form: values differ across app versions ("unified", "v3", "ultra").
    Setting("parakeet.version", .transcription, .string),

    // Meetings: engine, summary/context models, prompt, toggles, trigger apps
    Setting("meeting.transcription.engine", .meetings, .oneOf(meetingEngines)),
    Setting("meeting.notes.generate", .meetings, .bool),
    Setting("meeting.notes.model", .meetings, .string),
    Setting("meeting.notes.prompt", .meetings, .string),
    Setting("meeting.context.enabled", .meetings, .bool),
    Setting("meeting.context.model", .meetings, .string),
    Setting("meeting.overlay.enabled", .meetings, .bool),
    Setting("meeting.obsidian.autoExport", .meetings, .bool),
    Setting("meeting.autoDetection.enabled", .meetings, .bool),
    Setting("meeting.autoDetection.triggerRules", .meetings, .json(.meetingTriggerRules)),
    Setting("meeting.ticketBaseURL", .meetings, .string),

    // Beeper chats (IDs + aliases) and response monitoring
    Setting("beeper.chats", .beeper, .json(.beeperChats)),
    Setting("beeper.response.monitoring.enabled", .beeper, .bool),
    Setting("beeper.response.filterKeywords", .beeper, .string),
    Setting("beeper.response.polling.intervalSeconds", .beeper, seconds),
    Setting("beeper.response.suppressWhenChatAppFrontmost", .beeper, .bool),
    Setting("beeper.postProcessing.enabled", .beeper, .bool),
    Setting("beeper.context.clipboard.enabled", .beeper, .bool),
    Setting("beeper.context.clipboard.timeoutSeconds", .beeper, seconds),

    // Hotkeys (Dictation/Command hotkeys travel inside their prompt settings above)
    Setting("hermes.shortcut.selection", .hotkeys, .oneOf(hotkeys)),
    Setting("beeper.shortcut.selection", .hotkeys, .oneOf(hotkeys)),
    Setting("codex.shortcut.selection", .hotkeys, .oneOf(hotkeys)),
    Setting("pasteShortcut.keyCode", .hotkeys, .int(0...0xFFFF)),
    Setting("pasteShortcut.modifiers", .hotkeys, .int(0...Int(UInt32.max))),

    // General UX toggles
    Setting("insertion.pasteFormatted", .general, .bool),
    Setting("insertion.useAX", .general, .bool),
    Setting("screenContext.enabled", .general, .bool),
    Setting("screenContext.captureMode", .general, .oneOf(captureModes)),
    Setting("clipboardContext.enabled", .general, .bool),
    Setting("recording.autoMute.enabled", .general, .bool),
    Setting("audio.chime.volume", .general, .double(0...1)),
    Setting("response.window.fontSize", .general, .double(6...72)),
    Setting("history.maxEntries", .general, .int(1...100_000)),
    Setting("hermes.context.screenText.enabled", .general, .bool),
    Setting("hermes.context.screenshot.enabled", .general, .bool),
    Setting("hermes.context.clipboard.enabled", .general, .bool),
    Setting("hermes.context.clipboard.timeoutSeconds", .general, seconds),
    Setting("hermes.postProcessing.enabled", .general, .bool),
    Setting("codex.pinNewTasks", .general, .bool),
    Setting("codex.monitorProjectlessTasks", .general, .bool),
    Setting("codex.postProcessing.enabled", .general, .bool),
    Setting("codex.context.clipboard.enabled", .general, .bool),
    Setting("codex.context.clipboard.timeoutSeconds", .general, seconds)
  ]

  static let syncedKeys: Set<String> = Set(synced.map(\.key))

  static let expectations: [String: Expectation] = Dictionary(
    uniqueKeysWithValues: synced.map { ($0.key, $0.expect) }
  )

  /// Keys deliberately kept on each Mac, with the reason. Documentation and a test guard:
  /// nothing here may ever appear in `synced`.
  static let excluded: [String: String] = [
    // Device hardware and audio
    "audio.input.uid": "microphone is per-Mac hardware",
    "audio.input.priorities": "microphone priority is per-Mac hardware",
    "audio.voiceProcessing.enabled": "depends on this Mac's microphone",
    "audio.streaming.rmsGate": "audio tuning for this Mac's microphone",
    // File and folder paths
    "meeting.obsidian.vaultRoot": "local folder path",
    "meeting.obsidian.exportFolder": "local folder path",
    "codex.rootFolder": "local folder path",
    // Per-Mac integration setup (paired with per-Mac API keys and installed apps)
    "hermes.agent.enabled": "integration switch depends on this Mac's Hermes key",
    "hermes.api.baseURL": "connection setting paired with the per-Mac Hermes key",
    "hermes.model": "connection setting paired with the per-Mac Hermes key",
    "hermes.profile.name": "connection setting paired with the per-Mac Hermes key",
    "hermes.conversation.name": "conversation identity is per Mac",
    "hermes.timeout": "connection setting paired with the per-Mac Hermes key",
    "beeper.enabled": "integration switch depends on this Mac's Beeper Desktop and token",
    "beeper.api.baseURL": "points at this Mac's Beeper Desktop",
    "codex.enabled": "integration switch depends on this Mac's Codex install",
    // State, history and window state
    "codex.ownedThreadIDs": "conversation state",
    "simple.sidebar.selection": "window state",
    "hermes.chat.maxMessages": "conversation history limit",
    "hermes.sessions.maxSessions": "conversation history limit",
    // Legacy and debug
    "beeper.chat.id": "legacy, migrated into beeper.chats",
    "prompts.library": "legacy prompt library",
    "prompts.selected.id": "legacy prompt library",
    "llm.systemPrompt": "legacy prompt",
    "llm.userMessage": "legacy prompt",
    "llm.userPrompt": "legacy prompt",
    "parakeet.raw.mode": "debug flag",
    "groq.file.debugResponse": "debug flag",
    "soniox.debugMessages": "debug flag",
    "insertion.fastMode": "debug flag",
    "insertion.useAppleScriptPaste": "debug flag",
    // Sync's own state
    SettingsSyncStateKey.enabled: "sync metadata",
    SettingsSyncStateKey.deviceID: "sync metadata",
    SettingsSyncStateKey.localState: "sync metadata",
    SettingsSyncStateKey.lastSyncedAt: "sync metadata",
    SettingsSyncStateKey.legacyCounter: "sync metadata (round-3 format, deleted on launch)",
    SettingsSyncStateKey.legacyClock: "sync metadata (schema 1, deleted on launch)",
    SettingsSyncStateKey.firstEnableMode: "sync metadata"
  ]

  static func isSynced(_ key: String) -> Bool {
    syncedKeys.contains(key)
  }

  /// True when a value received from iCloud is safe to write into this Mac's preferences:
  /// right type, in range, and (for JSON blobs) decodable by the type that reads it.
  /// A nil value (reset to default) is always acceptable for a synced key.
  static func isValid(_ value: SettingsSyncValue?, for key: String) -> Bool {
    guard let expectation = expectations[key] else { return false }
    guard let value else { return true }
    switch (expectation, value) {
    case (.bool, .bool), (.string, .string), (.strings, .strings):
      return true
    case (.oneOf(let allowed), .string(let raw)):
      return allowed.contains(raw)
    case (.int(let range), .int(let number)):
      return range.contains(number)
    case (.double(let range), .double(let number)):
      return number.isFinite && range.contains(number)
    case (.double(let range), .int(let number)):
      return range.contains(Double(number))
    case (.json(let shape), .data(let data)):
      return decodes(data, as: shape)
    default:
      return false
    }
  }

  private static func decodes(_ data: Data, as shape: JSONShape) -> Bool {
    let decoder = JSONDecoder()
    switch shape {
    case .promptSettings:
      return (try? decoder.decode(SimplePromptSettings.self, from: data)) != nil
    case .promptTemplates:
      return (try? decoder.decode([SimplePromptTemplate].self, from: data)) != nil
    case .favoriteModels:
      return (try? decoder.decode([FavoriteOpenRouterModel].self, from: data)) != nil
    case .beeperChats:
      return (try? decoder.decode([BeeperChatEntry].self, from: data)) != nil
    case .meetingTriggerRules:
      return (try? decoder.decode([MeetingTriggerRule].self, from: data)) != nil
    }
  }
}

/// UserDefaults keys for sync's own per-Mac state. Never synced. Kept outside the main-actor
/// service so the nonisolated registry can reference them.
enum SettingsSyncStateKey {
  static let enabled = "settingsSync.enabled"
  static let deviceID = "settingsSync.deviceID"
  /// The whole `SettingsSyncEngine` (agreed records, pending edits, counter) as JSON.
  static let localState = "settingsSync.localState"
  static let lastSyncedAt = "settingsSync.lastSyncedAt"
  /// Round-3 standalone counter; the engine state in `localState` now holds it. Deleted.
  static let legacyCounter = "settingsSync.counter"
  /// Schema 1 wall-clock "clock"; only referenced so it can be deleted.
  static let legacyClock = "settingsSync.clock"
  /// The unfinished first-enable choice, kept until a sync succeeds.
  static let firstEnableMode = "settingsSync.firstEnableMode"
}
