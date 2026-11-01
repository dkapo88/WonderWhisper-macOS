import Foundation
import Testing
@testable import WonderWhisper

struct DictationSessionMachineTests {
  private let prompt = UUID()
  private let release = DictationTriggerTimes(keyEvent: 12.5, callback: 12.6)

  @Test func releaseDuringStartupIsRememberedAndStopsOnceRecording() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    let result1 = machine.requestStop(release)
    #expect(result1 == .deferred)
    #expect(machine.phase == .starting)
    let result2 = machine.startFinished(session: session, started: true)
    #expect(result2 == .stop(release))
    #expect(machine.phase == .stopping)
  }

  @Test func onlyTheFirstStopDuringStartupIsKept() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    _ = machine.requestStop(release)
    _ = machine.requestStop(DictationTriggerTimes(keyEvent: 13, callback: 13))
    let result3 = machine.startFinished(session: session, started: true)
    #expect(result3 == .stop(release))
  }

  @Test func repeatedStopsFinaliseOnce() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    let result4 = machine.startFinished(session: session, started: true)
    #expect(result4 == .recording)
    let result5 = machine.requestStop(release)
    #expect(result5 == .stop)
    let result6 = machine.requestStop(release)
    #expect(result6 == .ignored)
    let result7 = machine.requestStop(release)
    #expect(result7 == .ignored)
    machine.finished(session: session)
    let result8 = machine.requestStop(release)
    #expect(result8 == .ignored)
    #expect(!machine.isActive)
  }

  @Test func aSecondStartWhileActiveIsRefused() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    let result9 = machine.begin(promptID: UUID())
    #expect(result9 == nil)
    _ = machine.startFinished(session: session, started: true)
    let result10 = machine.begin(promptID: UUID())
    #expect(result10 == nil)
    _ = machine.requestStop(release)
    let result11 = machine.begin(promptID: UUID())
    #expect(result11 == nil)
    machine.finished(session: session)
    let result12 = machine.begin(promptID: UUID())
    #expect(result12 == session + 1)
  }

  @Test func cancelDuringStartupCancelsOnceRecording() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    let result13 = machine.requestCancel()
    #expect(result13 == false)
    _ = machine.requestStop(release)
    let result14 = machine.startFinished(session: session, started: true)
    #expect(result14 == .cancel)
  }

  @Test func cancelWhileRecordingOrInTheTailCancelsNow() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    _ = machine.startFinished(session: session, started: true)
    let result15 = machine.requestCancel()
    #expect(result15)
    let result16 = machine.requestStop(release)
    #expect(result16 == .ignored)

    var tail = DictationSessionMachine()
    let secondBegun = tail.begin(promptID: prompt)
    let second = try #require(secondBegun)
    _ = tail.startFinished(session: second, started: true)
    _ = tail.requestStop(release)
    let result17 = tail.requestCancel()
    #expect(result17)
  }

  @Test func failedStartEndsTheSession() throws {
    var machine = DictationSessionMachine()
    let sessionBegun = machine.begin(promptID: prompt)
    let session = try #require(sessionBegun)
    _ = machine.requestStop(release)
    let result18 = machine.startFinished(session: session, started: false)
    #expect(result18 == .failed)
    #expect(!machine.isActive)
  }

  @Test func staleSessionCallbacksAreIgnored() throws {
    var machine = DictationSessionMachine()
    let firstBegun = machine.begin(promptID: prompt)
    let first = try #require(firstBegun)
    machine.finished(session: first)
    let secondBegun = machine.begin(promptID: prompt)
    let second = try #require(secondBegun)
    machine.finished(session: first)
    #expect(machine.phase == .starting)
    let result19 = machine.startFinished(session: first, started: true)
    #expect(result19 == .failed)
    let result20 = machine.startFinished(session: second, started: true)
    #expect(result20 == .recording)
  }
}
