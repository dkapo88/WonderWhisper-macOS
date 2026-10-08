import Foundation
import AppKit
import Carbon.HIToolbox

/// Re-reads synced preferences into the live view models after iCloud settings sync wrote newer
/// values into UserDefaults, so changes from another Mac show up without a relaunch.
///
/// Each property is assigned only when the value actually differs, so unchanged settings don't
/// re-run their `didSet` side effects. Keys that are read on use (`parakeet.version`,
/// `qwen.injectVocabulary`, `meeting.ticketBaseURL`) need no entry here.
extension DictationViewModel {
  /// Applies one received batch. Every value is already in UserDefaults; the batch wrapper
  /// keeps property side effects from writing stale siblings back before all are assigned.
  ///
  /// A received key that is absent means "reset to default": the property gets the same
  /// fallback the app uses at launch, and any copy its `didSet` writes back is removed again
  /// (now, and once more after the view model's deferred persistence hops have run) so the
  /// reset isn't turned into an explicit value and re-uploaded.
  func applySyncedSettings(changedKeys keys: Set<String>) {
    let defaults = AppConfig.defaults
    let removed = keys.filter { defaults.object(forKey: $0) == nil }
    withSyncedSettingsBatch {
      applySyncedValues(changedKeys: keys)
    }
    guard !removed.isEmpty else { return }
    removed.forEach { defaults.removeObject(forKey: $0) }
    Task { @MainActor in
      removed.forEach { defaults.removeObject(forKey: $0) }
    }
  }

  /// Launch fallbacks for settings whose initializers don't go through a shared loader.
  static let defaultPasteShortcut = HotkeyManager.Shortcut(
    keyCode: UInt32(kVK_ANSI_V),
    modifiers: UInt32(cmdKey | controlKey)
  )
  static let defaultHistoryMaxEntries = 50
  static var defaultResponseWindowFontSize: Double { Double(NSFont.systemFontSize) }

  private func applySyncedValues(changedKeys keys: Set<String>) {
    let defaults = AppConfig.defaults
    func has(_ key: String) -> Bool { keys.contains(key) }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key) as? Bool ?? fallback
    }
    func double(_ key: String, _ fallback: Double) -> Double {
      defaults.object(forKey: key) as? Double ?? fallback
    }

    // Vocabulary
    if has("vocab.custom") { update(\.vocabCustom, defaults.string(forKey: "vocab.custom") ?? "") }
    if has("vocab.spelling") {
      update(\.vocabSpelling, defaults.string(forKey: "vocab.spelling") ?? "")
    }

    // Prompts, templates, favorites, model/engine selections and the Hermes/Beeper/Codex
    // hotkeys use loaders private to DictationViewModel.swift.
    reloadFileScopedSyncedSettings(changedKeys: keys)

    // Models
    if has("llm.model") {
      update(\.llmModel, defaults.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel)
    }
    if has("llm.enabled") { update(\.llmEnabled, bool("llm.enabled", true)) }
    if has("llm.openrouter.routing") {
      update(\.openrouterRouting, defaults.string(forKey: "llm.openrouter.routing") ?? "auto")
    }
    if has("llm.temperature") { update(\.llmTemperature, double("llm.temperature", 0.2)) }

    // Transcription
    if has("transcription.model") {
      update(
        \.transcriptionModel,
        defaults.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel
      )
    }
    if has("transcription.language") {
      update(\.transcriptionLanguage, defaults.string(forKey: "transcription.language") ?? "en")
    }
    if has("transcription.timeout") {
      update(\.transcriptionTimeoutSeconds, max(5, min(120, double("transcription.timeout", 10))))
    }

    // Beeper
    if has("beeper.chats") { update(\.beeperChats, Self.loadBeeperChats()) }
    if has("beeper.response.monitoring.enabled") {
      update(\.beeperResponseMonitoringEnabled, bool("beeper.response.monitoring.enabled", true))
    }
    if has("beeper.response.filterKeywords") {
      update(
        \.beeperResponseFilterKeywords,
        defaults.string(forKey: "beeper.response.filterKeywords") ?? ""
      )
    }
    if has("beeper.response.polling.intervalSeconds") {
      update(
        \.beeperResponsePollingIntervalSeconds,
        max(2, min(60, double("beeper.response.polling.intervalSeconds", 10)))
      )
    }
    if has("beeper.response.suppressWhenChatAppFrontmost") {
      update(
        \.beeperSuppressWhenChatAppFrontmost,
        bool("beeper.response.suppressWhenChatAppFrontmost", false)
      )
    }
    if has("beeper.postProcessing.enabled") {
      update(\.beeperPostProcessingEnabled, bool("beeper.postProcessing.enabled", true))
    }
    if has("beeper.context.clipboard.enabled") {
      update(\.beeperClipboardContextEnabled, bool("beeper.context.clipboard.enabled", true))
    }
    if has("beeper.context.clipboard.timeoutSeconds") {
      update(
        \.beeperClipboardTimeoutSeconds,
        clipboardWindow("beeper.context.clipboard.timeoutSeconds")
      )
    }

    // Hotkeys
    // Sync validates ranges before writing; the exact conversion is a second line of defense.
    if has("pasteShortcut.keyCode") || has("pasteShortcut.modifiers") {
      // Same rule as launch: both keys present → stored shortcut, otherwise the default.
      if defaults.object(forKey: "pasteShortcut.keyCode") != nil,
         defaults.object(forKey: "pasteShortcut.modifiers") != nil {
        if let keyCode = UInt32(exactly: defaults.integer(forKey: "pasteShortcut.keyCode")),
           let modifiers = UInt32(exactly: defaults.integer(forKey: "pasteShortcut.modifiers")) {
          update(\.pasteShortcut, HotkeyManager.Shortcut(keyCode: keyCode, modifiers: modifiers))
        }
      } else {
        update(\.pasteShortcut, Self.defaultPasteShortcut)
      }
    }

    // General
    if has("insertion.pasteFormatted") {
      update(\.pasteFormatted, bool("insertion.pasteFormatted", false))
    }
    if has("insertion.useAX") { update(\.useAXInsertion, bool("insertion.useAX", false)) }
    if has("screenContext.enabled") {
      update(\.screenContextEnabled, bool("screenContext.enabled", true))
    }
    if has("screenContext.captureMode") {
      let raw = defaults.string(forKey: "screenContext.captureMode") ?? ""
      update(\.screenContextCaptureMode, ScreenContextCaptureMode(rawValue: raw) ?? .image)
    }
    if has("clipboardContext.enabled") {
      update(\.clipboardContextEnabled, bool("clipboardContext.enabled", true))
    }
    if has("recording.autoMute.enabled") {
      update(\.autoMuteEnabled, bool("recording.autoMute.enabled", false))
    }
    if has("audio.chime.volume") {
      update(\.chimeVolume, max(0, min(1, double("audio.chime.volume", 1))))
    }
    if has(AppConfig.responseWindowFontSizeKey) {
      update(
        \.responseWindowFontSize,
        double(AppConfig.responseWindowFontSizeKey, Self.defaultResponseWindowFontSize)
      )
    }
    if has("history.maxEntries") {
      let maxEntries = defaults.object(forKey: "history.maxEntries") as? Int
        ?? Self.defaultHistoryMaxEntries
      if history.maxEntries != maxEntries { history.maxEntries = maxEntries }
    }
    if has("hermes.context.screenText.enabled") {
      update(\.hermesScreenContextEnabled, bool("hermes.context.screenText.enabled", true))
    }
    if has("hermes.context.screenshot.enabled") {
      update(\.hermesScreenshotEnabled, bool("hermes.context.screenshot.enabled", true))
    }
    if has("hermes.context.clipboard.enabled") {
      update(\.hermesClipboardContextEnabled, bool("hermes.context.clipboard.enabled", true))
    }
    if has("hermes.context.clipboard.timeoutSeconds") {
      update(
        \.hermesClipboardTimeoutSeconds,
        clipboardWindow("hermes.context.clipboard.timeoutSeconds")
      )
    }
    if has("hermes.postProcessing.enabled") {
      update(\.hermesPostProcessingEnabled, bool("hermes.postProcessing.enabled", true))
    }
    if has("codex.pinNewTasks") { update(\.codexPinNewTasks, bool("codex.pinNewTasks", true)) }
    if has("codex.monitorProjectlessTasks") {
      update(\.codexMonitorProjectlessTasks, bool("codex.monitorProjectlessTasks", true))
    }
    if has("codex.postProcessing.enabled") {
      update(\.codexPostProcessingEnabled, bool("codex.postProcessing.enabled", true))
    }
    if has("codex.context.clipboard.enabled") {
      update(\.codexClipboardContextEnabled, bool("codex.context.clipboard.enabled", true))
    }
    if has("codex.context.clipboard.timeoutSeconds") {
      update(
        \.codexClipboardTimeoutSeconds,
        clipboardWindow("codex.context.clipboard.timeoutSeconds")
      )
    }

    meetingCoordinator.applySyncedSettings(changedKeys: keys)
  }

  private func clipboardWindow(_ key: String) -> Double {
    let value = AppConfig.defaults.object(forKey: key) as? Double
      ?? HermesClipboardContextPolicy.defaultRetentionWindow
    return HermesClipboardContextPolicy.clampedRetentionWindow(value)
  }

  private func update<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<DictationViewModel, Value>,
    _ value: Value
  ) {
    if self[keyPath: keyPath] != value {
      self[keyPath: keyPath] = value
    }
  }
}

extension MeetingCoordinator {
  func applySyncedSettings(changedKeys keys: Set<String>) {
    let defaults = AppConfig.defaults
    func has(_ key: String) -> Bool { keys.contains(key) }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key) as? Bool ?? fallback
    }

    if has("meeting.transcription.engine") {
      let engine = MeetingTranscriptionEngine.selected(defaults: defaults)
      if transcriptionEngine != engine { transcriptionEngine = engine }
    }
    if has("meeting.notes.generate") {
      let value = bool("meeting.notes.generate", false)
      if generateMeetingNotes != value { generateMeetingNotes = value }
    }
    if has("meeting.notes.model") {
      let value = defaults.string(forKey: "meeting.notes.model") ?? "openai/gpt-5.4-nano"
      if noteModel != value { noteModel = value }
    }
    if has(MeetingNoteGenerator.promptDefaultsKey) {
      let value = MeetingNoteGenerator.resolvedPrompt(
        defaults.string(forKey: MeetingNoteGenerator.promptDefaultsKey)
      )
      if notePrompt != value { notePrompt = value }
    }
    if has("meeting.context.enabled") {
      let value = bool("meeting.context.enabled", false)
      if liveObsidianContextEnabled != value { liveObsidianContextEnabled = value }
    }
    if has("meeting.context.model") {
      let value = defaults.string(forKey: "meeting.context.model") ?? "openai/gpt-5.4-nano"
      if contextModel != value { contextModel = value }
    }
    if has("meeting.overlay.enabled") {
      let value = bool("meeting.overlay.enabled", true)
      if meetingOverlayEnabled != value { meetingOverlayEnabled = value }
    }
    if has("meeting.obsidian.autoExport") {
      let value = bool("meeting.obsidian.autoExport", true)
      if automaticallyExportToObsidian != value { automaticallyExportToObsidian = value }
    }
    if has("meeting.autoDetection.enabled") {
      let value = bool("meeting.autoDetection.enabled", false)
      if automaticDetectionEnabled != value { automaticDetectionEnabled = value }
    }
    if has(MeetingTriggerRule.defaultsKey) {
      reloadTriggerRulesFromDefaults()
    }
  }
}
