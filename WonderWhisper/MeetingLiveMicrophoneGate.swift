import Foundation

/// The microphone gate for a live meeting stream. The coordinator's ingestion task hands
/// chunks over one at a time; the lock keeps `flush` at finish safe alongside it.
final class MeetingLiveMicrophoneGate: @unchecked Sendable {
  private let lock = NSLock()
  private var gate: MeetingMicrophoneGate
  private let muteRecorder: MeetingMicrophoneMuteRecorder?

  init(mode: MeetingMicrophoneGateMode, muteRecorder: MeetingMicrophoneMuteRecorder?) {
    gate = MeetingMicrophoneGate(mode: mode)
    self.muteRecorder = muteRecorder
  }

  func process(_ chunk: MeetingAudioChunk) -> [MeetingAudioChunk] {
    let muted = chunk.source == .microphone && muteRecorder?.covers(
      start: chunk.startTime,
      end: chunk.startTime + chunk.duration
    ) == true
    lock.lock()
    defer { lock.unlock() }
    return gate.process(chunk, muted: muted)
  }

  func flush() -> [MeetingAudioChunk] {
    lock.lock()
    defer { lock.unlock() }
    return gate.flush()
  }
}
