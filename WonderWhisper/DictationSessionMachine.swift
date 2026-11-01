import Foundation

/// Tracks one push-to-talk or toggle dictation from key-down to the end of processing, so that
/// hotkey events arriving while it is still starting or already stopping are handled once:
///
/// - a release (or second press) during startup is remembered and stops the session as soon as
///   the recorder is running;
/// - repeated stop requests finalise once;
/// - a cancel during startup ends the session as soon as the recorder is running.
struct DictationSessionMachine {
  enum Phase: Equatable {
    case idle
    case starting
    case recording
    case stopping
  }

  enum StopDecision: Equatable {
    /// Stop now (the session was recording).
    case stop
    /// Still starting: the request is remembered and returned by `startFinished`.
    case deferred
    /// Nothing to stop, or a stop is already under way.
    case ignored
  }

  enum StartOutcome: Equatable {
    /// Recording; keep going until a stop arrives.
    case recording
    /// A stop arrived during startup: stop now with this trigger.
    case stop(DictationTriggerTimes)
    /// A cancel arrived during startup: cancel the recording now.
    case cancel
    /// The recorder did not start; the session is over.
    case failed
  }

  private(set) var phase: Phase = .idle
  private(set) var sessionID = 0
  private(set) var promptID: UUID?
  private var pendingStop: DictationTriggerTimes?
  private var cancelRequested = false

  var isActive: Bool { phase != .idle }

  /// Begins a session. Nil when one is already active.
  mutating func begin(promptID: UUID) -> Int? {
    guard phase == .idle else { return nil }
    sessionID += 1
    phase = .starting
    self.promptID = promptID
    pendingStop = nil
    cancelRequested = false
    return sessionID
  }

  /// The recorder start for `session` finished (`started` false if it failed).
  mutating func startFinished(session: Int, started: Bool) -> StartOutcome {
    guard session == sessionID, phase == .starting else { return .failed }
    guard started else {
      reset()
      return .failed
    }
    if cancelRequested {
      phase = .stopping
      return .cancel
    }
    if let pendingStop {
      self.pendingStop = nil
      phase = .stopping
      return .stop(pendingStop)
    }
    phase = .recording
    return .recording
  }

  mutating func requestStop(_ trigger: DictationTriggerTimes) -> StopDecision {
    switch phase {
    case .idle, .stopping:
      return .ignored
    case .starting:
      if pendingStop == nil { pendingStop = trigger }
      return .deferred
    case .recording:
      phase = .stopping
      return .stop
    }
  }

  /// Escape or cancel. True when the caller should cancel the recorder now; during startup the
  /// cancel is applied by `startFinished` instead.
  mutating func requestCancel() -> Bool {
    switch phase {
    case .idle:
      return false
    case .starting:
      cancelRequested = true
      return false
    case .recording, .stopping:
      phase = .stopping
      return true
    }
  }

  /// Processing (or cancelling) for `session` is complete.
  mutating func finished(session: Int) {
    guard session == sessionID else { return }
    reset()
  }

  private mutating func reset() {
    phase = .idle
    promptID = nil
    pendingStop = nil
    cancelRequested = false
  }
}
