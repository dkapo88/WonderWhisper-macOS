import Foundation
import Darwin

/// Uptime clock (seconds since boot) shared by hotkey events and the dictation pipeline. It is
/// the base of `ProcessInfo.systemUptime`, Carbon `GetEventTime` and `NSEvent.timestamp`.
enum DictationClock {
  static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// Converts a `CGEvent.timestamp` to uptime seconds. The field is documented as nanoseconds,
  /// but some hardware fills it with Mach ticks, so whichever reading lands just before `now`
  /// wins. An implausible value (synthetic events often carry 0) falls back to `now`.
  static func uptime(
    fromEventTimestamp raw: UInt64,
    now: TimeInterval = now(),
    ticksToNanoseconds: Double = machTicksToNanoseconds
  ) -> TimeInterval {
    guard raw > 0 else { return now }
    let plausible = (now - 30)...(now + 0.05)
    let asNanoseconds = Double(raw) / 1_000_000_000
    if plausible.contains(asNanoseconds) { return asNanoseconds }
    let asTicks = Double(raw) * ticksToNanoseconds / 1_000_000_000
    if plausible.contains(asTicks) { return asTicks }
    return now
  }

  static let machTicksToNanoseconds: Double = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
    return Double(info.numer) / Double(info.denom)
  }()
}

/// Times the app knows about a dictation's start or stop request before it reaches the
/// controller: when the key physically moved and when the hotkey callback ran.
struct DictationTriggerTimes: Sendable, Equatable {
  var keyEvent: TimeInterval?
  var callback: TimeInterval

  init(keyEvent: TimeInterval? = nil, callback: TimeInterval = DictationClock.now()) {
    self.keyEvent = keyEvent
    self.callback = callback
  }
}

/// Per-dictation stage timeline, logged as one `[Timing]` line when the dictation ends.
/// The line carries durations, the engine id and the audio length only, never transcript text.
/// "Paste issued" is when the paste was sent to the target app, not a verified insertion.
struct DictationStageTimings: Sendable, Equatable {
  var session: Int
  var engine: String
  // Uptime instants.
  var physicalKeyDown: TimeInterval?
  var hotkeyCallback: TimeInterval?
  var recorderStarted: TimeInterval?
  var keyUp: TimeInterval?
  var captureStopped: TimeInterval?
  var pasteIssued: TimeInterval?
  // Stage durations, seconds.
  var audioPrep: TimeInterval?
  var asr: TimeInterval?
  var vocabulary: TimeInterval?
  var llm: TimeInterval?
  var pasteIssue: TimeInterval?
  // Context for bucketing measurements.
  var audioSeconds: Double?
  var modelWarmAtStart: Bool?
  var modelWarmAtASR: Bool?
  var outcome = "unknown"

  init(session: Int, engine: String) {
    self.session = session
    self.engine = engine
  }

  /// `[Timing] session=3 engine=parakeet-local outcome=pasted audioMs=3120 ...`
  func logLine() -> String {
    var fields: [(String, String)] = [
      ("session", "\(session)"),
      ("engine", engine),
      ("outcome", outcome),
      ("audioMs", Self.ms(audioSeconds)),
      ("warmAtStart", Self.flag(modelWarmAtStart)),
      ("warmAtAsr", Self.flag(modelWarmAtASR))
    ]
    fields += [
      ("keyDownToCallbackMs", Self.ms(Self.span(physicalKeyDown, hotkeyCallback))),
      ("callbackToRecorderMs", Self.ms(Self.span(hotkeyCallback, recorderStarted))),
      ("keyDownToRecorderMs", Self.ms(Self.span(physicalKeyDown ?? hotkeyCallback, recorderStarted))),
      ("keyUpToCaptureStoppedMs", Self.ms(Self.span(keyUp, captureStopped))),
      ("audioPrepMs", Self.ms(audioPrep)),
      ("asrMs", Self.ms(asr)),
      ("vocabMs", Self.ms(vocabulary)),
      ("llmMs", Self.ms(llm)),
      ("pasteIssueMs", Self.ms(pasteIssue)),
      ("keyUpToPasteIssuedMs", Self.ms(Self.span(keyUp, pasteIssued)))
    ]
    return "[Timing] " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
  }

  static func span(_ start: TimeInterval?, _ end: TimeInterval?) -> TimeInterval? {
    guard let start, let end else { return nil }
    return end - start
  }

  private static func ms(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "-" }
    return "\(Int((seconds * 1_000).rounded()))"
  }

  private static func flag(_ value: Bool?) -> String {
    guard let value else { return "-" }
    return value ? "1" : "0"
  }
}
