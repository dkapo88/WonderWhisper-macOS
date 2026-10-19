import Foundation

/// One voice in a meeting transcript: the microphone, which is always the user, or one
/// speaker on another source. `label` is the diarizer's speaker label ("1", "2"); nil when
/// the source was not split into speakers.
struct MeetingSpeakerKey: Hashable, Sendable {
  let source: MeetingAudioSource
  let label: String?

  static let microphone = MeetingSpeakerKey(source: .microphone, label: nil)

  init(source: MeetingAudioSource, label: String?) {
    self.source = source
    let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // Everything on the microphone is the user, whatever a provider labels it.
    self.label = source == .microphone || trimmed.isEmpty ? nil : trimmed
  }

  init(token: MeetingTranscriptToken) {
    self.init(source: token.source, label: token.speaker)
  }

  /// The stored form: `microphone`, `systemAudio`, or `systemAudio:2`.
  init?(rawValue: String) {
    let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first,
          let source = MeetingAudioSource(rawValue: String(first)) else { return nil }
    self.init(source: source, label: parts.count == 2 ? String(parts[1]) : nil)
  }

  var rawValue: String {
    label.map { "\(source.rawValue):\($0)" } ?? source.rawValue
  }

  var isMicrophone: Bool {
    source == .microphone
  }
}
