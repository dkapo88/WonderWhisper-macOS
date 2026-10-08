import Foundation

/// The single list of preferences that iCloud settings sync carries between Macs.
///
/// Sync is an explicit allowlist: a UserDefaults key travels only if it is listed in `synced`.
/// To sync a new preference, add its existing key here (never rename the key itself) and, if a
/// view model caches the value, re-read it in `SettingsSyncLiveApply.swift`.
/// API keys live in the Keychain and are never read by sync.
enum SettingsSyncRegistry {
  enum Group: String, CaseIterable {
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

  struct Setting: Hashable {
    let key: String
    let group: Group
  }

  static let synced: [Setting] = [
    // Vocabulary
    Setting(key: "vocab.custom", group: .vocabulary),
    Setting(key: "vocab.spelling", group: .vocabulary),
    Setting(key: "qwen.injectVocabulary", group: .vocabulary),

    // Dictation and Command prompts (header/rules/footer, context toggles, hotkey) + templates
    Setting(key: "simple.dictation.settings", group: .prompts),
    Setting(key: "simple.command.settings", group: .prompts),
    Setting(key: "simple.dictation.promptTemplates", group: .prompts),

    // Favorite and custom models
    Setting(key: "simple.openrouter.favorites", group: .models),
    Setting(key: "simple.model.custom", group: .models),

    // Current LLM selection, routing and reasoning
    Setting(key: "simple.model.selected", group: .modelSelection),
    Setting(key: "llm.model", group: .modelSelection),
    Setting(key: "simple.llm.enabled", group: .modelSelection),
    Setting(key: "llm.enabled", group: .modelSelection),
    Setting(key: "llm.openrouter.routing", group: .modelSelection),
    Setting(key: "llm.openrouter.reasoning", group: .modelSelection),
    Setting(key: "llm.temperature", group: .modelSelection),

    // Transcription engine, model and language
    Setting(key: "simple.voice.engine", group: .transcription),
    Setting(key: "transcription.model", group: .transcription),
    Setting(key: "transcription.language", group: .transcription),
    Setting(key: "transcription.openrouter.model", group: .transcription),
    Setting(key: "transcription.timeout", group: .transcription),
    Setting(key: "parakeet.version", group: .transcription),

    // Meetings: engine, summary/context models, prompt, toggles, trigger apps
    Setting(key: "meeting.transcription.engine", group: .meetings),
    Setting(key: "meeting.notes.generate", group: .meetings),
    Setting(key: "meeting.notes.model", group: .meetings),
    Setting(key: "meeting.notes.prompt", group: .meetings),
    Setting(key: "meeting.context.enabled", group: .meetings),
    Setting(key: "meeting.context.model", group: .meetings),
    Setting(key: "meeting.overlay.enabled", group: .meetings),
    Setting(key: "meeting.obsidian.autoExport", group: .meetings),
    Setting(key: "meeting.autoDetection.enabled", group: .meetings),
    Setting(key: "meeting.autoDetection.triggerRules", group: .meetings),
    Setting(key: "meeting.ticketBaseURL", group: .meetings),

    // Beeper chats (IDs + aliases) and response monitoring
    Setting(key: "beeper.chats", group: .beeper),
    Setting(key: "beeper.response.monitoring.enabled", group: .beeper),
    Setting(key: "beeper.response.filterKeywords", group: .beeper),
    Setting(key: "beeper.response.polling.intervalSeconds", group: .beeper),
    Setting(key: "beeper.response.suppressWhenChatAppFrontmost", group: .beeper),
    Setting(key: "beeper.postProcessing.enabled", group: .beeper),
    Setting(key: "beeper.context.clipboard.enabled", group: .beeper),
    Setting(key: "beeper.context.clipboard.timeoutSeconds", group: .beeper),

    // Hotkeys (Dictation/Command hotkeys travel inside their prompt settings above)
    Setting(key: "hermes.shortcut.selection", group: .hotkeys),
    Setting(key: "beeper.shortcut.selection", group: .hotkeys),
    Setting(key: "codex.shortcut.selection", group: .hotkeys),
    Setting(key: "pasteShortcut.keyCode", group: .hotkeys),
    Setting(key: "pasteShortcut.modifiers", group: .hotkeys),

    // General UX toggles
    Setting(key: "insertion.pasteFormatted", group: .general),
    Setting(key: "insertion.useAX", group: .general),
    Setting(key: "screenContext.enabled", group: .general),
    Setting(key: "screenContext.captureMode", group: .general),
    Setting(key: "clipboardContext.enabled", group: .general),
    Setting(key: "recording.autoMute.enabled", group: .general),
    Setting(key: "audio.chime.volume", group: .general),
    Setting(key: "response.window.fontSize", group: .general),
    Setting(key: "history.maxEntries", group: .general),
    Setting(key: "hermes.context.screenText.enabled", group: .general),
    Setting(key: "hermes.context.screenshot.enabled", group: .general),
    Setting(key: "hermes.context.clipboard.enabled", group: .general),
    Setting(key: "hermes.context.clipboard.timeoutSeconds", group: .general),
    Setting(key: "hermes.postProcessing.enabled", group: .general),
    Setting(key: "codex.pinNewTasks", group: .general),
    Setting(key: "codex.monitorProjectlessTasks", group: .general),
    Setting(key: "codex.postProcessing.enabled", group: .general),
    Setting(key: "codex.context.clipboard.enabled", group: .general),
    Setting(key: "codex.context.clipboard.timeoutSeconds", group: .general)
  ]

  static let syncedKeys: Set<String> = Set(synced.map(\.key))

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
    SettingsSyncService.enabledKey: "sync metadata",
    SettingsSyncService.deviceIDKey: "sync metadata",
    SettingsSyncService.localStateKey: "sync metadata",
    SettingsSyncService.lastSyncedAtKey: "sync metadata"
  ]

  static func isSynced(_ key: String) -> Bool {
    syncedKeys.contains(key)
  }
}
