import Foundation

/// What the microphone gate needs to treat a meeting's microphone audio: the gate mode the
/// meeting was recorded with and the times the user muted the microphone.
struct MeetingMicrophoneGateSettings: Equatable, Sendable {
  var mode: MeetingMicrophoneGateMode
  var mutedRanges: [MeetingTimeRange]

  static let passThrough = Self(mode: .off, mutedRanges: [])

  init(mode: MeetingMicrophoneGateMode, mutedRanges: [MeetingTimeRange] = []) {
    self.mode = mode
    self.mutedRanges = mutedRanges
  }

  init(session: MeetingSession) {
    self.init(
      mode: session.microphoneGateMode ?? .off,
      mutedRanges: session.microphoneMutedRanges
    )
  }

  /// False when the microphone audio passes through unchanged.
  var changesAudio: Bool {
    mode != .off || !mutedRanges.isEmpty
  }
}
