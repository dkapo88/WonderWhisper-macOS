import Foundation
import Testing
@testable import WonderWhisper

struct SettingsWindowTests {
  @Test func settingsTabsFollowProposedOrder() {
    #expect(SettingsTab.allCases.map(\.title) == [
      "General", "Transcription", "Models", "Audio", "Meetings", "Shortcuts", "Integrations",
      "Permissions"
    ])
    #expect(SettingsTab.Integration.allCases.map(\.title) == ["Codex", "Beeper", "Hermes"])
  }

  @Test func shortcutOwnerIgnoresTheFlowBeingEdited() {
    let assignments: [ShortcutFlow: HotkeyManager.Selection] = [
      .dictation: .fnGlobe,
      .hermes: .backslash
    ]
    #expect(ShortcutFlow.owner(of: .fnGlobe, in: assignments, excluding: .command) == .dictation)
    #expect(ShortcutFlow.owner(of: .fnGlobe, in: assignments, excluding: .dictation) == nil)
    #expect(ShortcutFlow.owner(of: .backslash, in: assignments, excluding: .beeper) == .hermes)
    #expect(ShortcutFlow.owner(of: .f5, in: assignments, excluding: .beeper) == nil)
  }

  @Test func settingsNoticeClassifiesSaveAndFailureMessages() {
    #expect(SettingsNotice.kind(for: "Groq API key saved.") == .ok)
    #expect(SettingsNotice.kind(for: "Codex App Server is ready.") == .ok)
    #expect(SettingsNotice.kind(for: "Could not save Soniox API key: denied") == .error)
    #expect(SettingsNotice.kind(for: "Groq API keys should start with gsk_ and must not include spaces or extra text.") == .error)
    #expect(SettingsNotice.kind(for: "That shortcut is already assigned to Hermes.") == .error)
    #expect(SettingsNotice.kind(for: "Testing Codex App Server...") == .neutral)
  }

  @Test func coreAudioAggregateDevicesAreNotSelectableMicrophones() {
    #expect(!AudioDeviceManager.isUserSelectableInput(uid: "CADefaultDeviceAggregate-1234-5"))
    #expect(AudioDeviceManager.isUserSelectableInput(uid: "BuiltInMicrophoneDevice"))

    let merged = AudioDeviceManager.mergedInputPriorities(
      stored: [
        AudioDeviceInfo(uid: "CADefaultDeviceAggregate-99-1", name: "CADefaultDeviceAggregate-99-1"),
        AudioDeviceInfo(uid: "usb-mic", name: "USB Mic")
      ],
      available: [AudioDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Microphone")],
      selection: .systemDefault
    )
    #expect(merged.map(\.uid) == ["usb-mic", "BuiltInMicrophoneDevice"])
  }
}
