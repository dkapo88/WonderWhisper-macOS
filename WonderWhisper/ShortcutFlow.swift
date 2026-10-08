import Foundation

/// A voice flow that can own a single-key activation shortcut. Each key can drive only one
/// flow; `owner(of:in:excluding:)` finds who already holds a key so pickers can mark it.
enum ShortcutFlow: String, CaseIterable, Identifiable {
  case dictation
  case command
  case hermes
  case beeper
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dictation: return "Dictation"
    case .command: return "Command"
    case .hermes: return "Hermes"
    case .beeper: return "Beeper"
    case .codex: return "Codex"
    }
  }

  var detail: String {
    switch self {
    case .dictation: return "Hold to dictate into the focused app."
    case .command: return "Transform selected or on-screen text."
    case .hermes: return "Talk to the Hermes agent."
    case .beeper: return "Record and send a Beeper message."
    case .codex: return "Create or reply to a Codex task."
    }
  }

  /// The flow (other than `flow`) that currently uses `selection`, if any.
  static func owner(
    of selection: HotkeyManager.Selection,
    in assignments: [ShortcutFlow: HotkeyManager.Selection],
    excluding flow: ShortcutFlow
  ) -> ShortcutFlow? {
    allCases.first { $0 != flow && assignments[$0] == selection }
  }
}
