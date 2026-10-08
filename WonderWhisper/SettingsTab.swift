import Foundation

/// Tabs of the Settings window (Cmd+,), in display order.
enum SettingsTab: String, CaseIterable, Identifiable {
  case general
  case transcription
  case models
  case audio
  case meetings
  case shortcuts
  case integrations
  case permissions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .transcription: return "Transcription"
    case .models: return "Models"
    case .audio: return "Audio"
    case .meetings: return "Meetings"
    case .shortcuts: return "Shortcuts"
    case .integrations: return "Integrations"
    case .permissions: return "Permissions"
    }
  }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .transcription: return "waveform"
    case .models: return "sparkles"
    case .audio: return "mic"
    case .meetings: return "person.2"
    case .shortcuts: return "keyboard"
    case .integrations: return "puzzlepiece.extension"
    case .permissions: return "lock.shield"
    }
  }

  /// Integrations shown as a sub-list inside the Integrations tab.
  enum Integration: String, CaseIterable, Identifiable {
    case codex
    case beeper
    case hermes

    var id: String { rawValue }

    var title: String {
      switch self {
      case .codex: return "Codex"
      case .beeper: return "Beeper"
      case .hermes: return "Hermes"
      }
    }
  }
}
