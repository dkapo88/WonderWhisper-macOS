import Foundation
import Testing
@testable import WonderWhisper

struct DictationStageTimingsTests {
  @Test func eventTimestampInNanosecondsConvertsToUptimeSeconds() {
    let now: TimeInterval = 1_000
    let raw = UInt64((now - 0.25) * 1_000_000_000)
    let uptime = DictationClock.uptime(fromEventTimestamp: raw, now: now, ticksToNanoseconds: 125.0 / 3.0)
    #expect(abs(uptime - (now - 0.25)) < 0.000_001)
  }

  @Test func eventTimestampInMachTicksConvertsToUptimeSeconds() {
    let now: TimeInterval = 1_000
    let ticksToNanoseconds = 125.0 / 3.0
    let raw = UInt64((now - 0.25) * 1_000_000_000 / ticksToNanoseconds)
    let uptime = DictationClock.uptime(
      fromEventTimestamp: raw,
      now: now,
      ticksToNanoseconds: ticksToNanoseconds
    )
    #expect(abs(uptime - (now - 0.25)) < 0.000_01)
  }

  @Test func implausibleEventTimestampFallsBackToNow() {
    #expect(DictationClock.uptime(fromEventTimestamp: 0, now: 50) == 50)
    #expect(DictationClock.uptime(fromEventTimestamp: 3, now: 50, ticksToNanoseconds: 1) == 50)
  }

  @Test func timingLineReportsStageDurationsInMilliseconds() {
    var timings = DictationStageTimings(session: 7, engine: "parakeet-local")
    timings.physicalKeyDown = 10.000
    timings.hotkeyCallback = 10.160
    timings.recorderStarted = 10.400
    timings.keyUp = 13.000
    timings.captureStopped = 13.250
    timings.audioPrep = 0.004
    timings.asr = 0.180
    timings.vocabulary = 0.001
    timings.pasteIssue = 0.030
    timings.pasteIssued = 13.500
    timings.audioSeconds = 3.2
    timings.modelWarmAtStart = true
    timings.modelWarmAtASR = true
    timings.outcome = "pasteIssued"

    let line = timings.logLine()
    #expect(line.hasPrefix("[Timing] session=7 engine=parakeet-local outcome=pasteIssued"))
    #expect(line.contains("audioMs=3200"))
    #expect(line.contains("warmAtStart=1 warmAtAsr=1"))
    #expect(line.contains("keyDownToCallbackMs=160"))
    #expect(line.contains("callbackToRecorderMs=240"))
    #expect(line.contains("keyDownToRecorderMs=400"))
    #expect(line.contains("keyUpToCaptureStoppedMs=250"))
    #expect(line.contains("asrMs=180"))
    #expect(line.contains("llmMs=-"))
    #expect(line.contains("keyUpToPasteIssuedMs=500"))
  }

  @Test func timingLineWithoutKeyEventMeasuresFromCallback() {
    var timings = DictationStageTimings(session: 1, engine: "soniox-streaming")
    timings.hotkeyCallback = 5
    timings.recorderStarted = 5.1
    let line = timings.logLine()
    #expect(line.contains("keyDownToCallbackMs=-"))
    #expect(line.contains("keyDownToRecorderMs=100"))
    #expect(line.contains("warmAtStart=-"))
  }
}
