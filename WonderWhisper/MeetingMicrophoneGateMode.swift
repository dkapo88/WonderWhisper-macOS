import Foundation

/// How hard the meeting microphone gate works. The gate sends silence instead of room noise
/// while the user is not speaking, so the transcriber cannot invent words from near-silence
/// or pick up quiet voices in the background.
enum MeetingMicrophoneGateMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case off
  case normal
  case strict

  static let defaultsKey = "meeting.microphone.gate"

  static func selected(defaults: UserDefaults = AppConfig.defaults) -> Self {
    defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .normal
  }

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .off: return "Off"
    case .normal: return "Normal"
    case .strict: return "Strict"
    }
  }

  var detail: String {
    switch self {
    case .off:
      return "Everything the microphone hears is transcribed."
    case .normal:
      return "Silence, background noise and much quieter voices are not transcribed. Never "
        + "loses you for long if you get quieter."
    case .strict:
      return "Also leaves out quieter voices in the room. If you switch to a quieter microphone, "
        + "your speech may be cut for up to two minutes."
    }
  }
}
