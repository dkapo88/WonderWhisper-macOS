import Foundation
import AppKit
import Testing
@testable import WonderWhisper

struct HermesResponseWindowLifecycleTests {
  @Test func responseWindowUsesLargerResizableLayout() {
    let defaultSize = HermesResponseWindowLayout.defaultContentSize
    let minimumSize = HermesResponseWindowLayout.minimumContentSize

    #expect(defaultSize.width >= 640)
    #expect(defaultSize.height >= 520)
    #expect(defaultSize.height - 390 > defaultSize.width - 560)
    #expect(minimumSize.width < defaultSize.width)
    #expect(minimumSize.height < defaultSize.height)
    #expect(HermesResponseWindowLayout.styleMask.contains(.resizable))
  }

  @Test func escapeDismissesSingleResponseWindow() {
    let window = UUID()
    #expect(
      HermesEscapeResolver.resolve(isRecording: false, responseWindowsFrontToBack: [window])
      == .dismissResponseWindow(window)
    )
  }

  @Test func escapeDismissesStackedResponseWindowsTopmostFirst() {
    let front = UUID()
    let middle = UUID()
    let back = UUID()
    var stack = [front, middle, back]

    // Each Escape removes only the current topmost, in reverse z-order.
    for expected in [front, middle, back] {
      #expect(
        HermesEscapeResolver.resolve(isRecording: false, responseWindowsFrontToBack: stack)
        == .dismissResponseWindow(expected)
      )
      stack.removeFirst()
    }
    #expect(
      HermesEscapeResolver.resolve(isRecording: false, responseWindowsFrontToBack: stack) == .ignore
    )
  }

  @Test func escapeCancelsRecordingBeforeDismissingWindows() {
    #expect(
      HermesEscapeResolver.resolve(isRecording: true, responseWindowsFrontToBack: [UUID(), UUID()])
      == .cancelRecording
    )
  }

  @Test func escapeIsNoOpWithoutRecordingOrResponseWindows() {
    #expect(
      HermesEscapeResolver.resolve(isRecording: false, responseWindowsFrontToBack: []) == .ignore
    )
  }

  @Test func escapeKeyIsConsumedForRecordingOrVisibleResponseWindowsOnly() {
    let window = UUID()

    #expect(
      HermesEscapeResolver.shouldConsumeKeyDown(
        keyCode: HermesEscapeResolver.escapeKeyCode,
        isRecording: true,
        responseWindowsFrontToBack: []
      )
    )
    #expect(
      HermesEscapeResolver.shouldConsumeKeyDown(
        keyCode: HermesEscapeResolver.escapeKeyCode,
        isRecording: false,
        responseWindowsFrontToBack: [window]
      )
    )
    #expect(
      !HermesEscapeResolver.shouldConsumeKeyDown(
        keyCode: HermesEscapeResolver.escapeKeyCode,
        isRecording: false,
        responseWindowsFrontToBack: []
      )
    )
    #expect(
      !HermesEscapeResolver.shouldConsumeKeyDown(
        keyCode: 0,
        isRecording: false,
        responseWindowsFrontToBack: [window]
      )
    )
  }

  @Test func replyRecordingCancelKeepsResponseVisibleAndClearsRecordingState() {
    let response = HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000124")!,
      title: "Hermes",
      text: "Use this response as context while replying.",
      isRecordingReply: true
    )
    var idleResponse = response
    idleResponse.isRecordingReply = false

    #expect(HermesResponseWindowLifecycle.replyRecordingCancelled(response) == idleResponse)
  }

  @Test func replyRecordingOnlyDismissesTheTargetResponseWindowWhenFinished() {
    let target = HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
      title: "Hermes",
      text: "Target response"
    )
    let other = HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
      title: "Hermes",
      text: "Other response"
    )
    let states = [target, other]
    var recordingTarget = target
    recordingTarget.isRecordingReply = true

    #expect(
      HermesResponseWindowLifecycle.replyRecordingStarted(states, sessionID: target.id)
      == [recordingTarget, other]
    )
    #expect(
      HermesResponseWindowLifecycle.replyRecordingFinished(states, sessionID: target.id)
      == [other]
    )
    #expect(
      HermesResponseWindowLifecycle.replyRecordingCancelled(
        [recordingTarget, other],
        sessionID: target.id
      )
      == [target, other]
    )
  }

  // MARK: - Bottom-row prominence

  private func panel(
    voice: Bool,
    text: Bool,
    isError: Bool = false,
    isRecordingReply: Bool = false
  ) -> HermesResponseWindowState {
    HermesResponseWindowState(
      title: "Sam",
      text: "hi",
      isError: isError,
      isRecordingReply: isRecordingReply,
      supportsReply: voice || text,
      supportsVoiceReply: voice,
      supportsTextReply: text
    )
  }

  @Test func textReplyIsPrimaryOnAnOrdinaryPanel() {
    // Beeper: text only. Hermes: both, and text still outranks an idle mic.
    #expect(HermesPanelPrimaryAction.resolve(panel(voice: false, text: true)) == .text)
    #expect(HermesPanelPrimaryAction.resolve(panel(voice: true, text: true)) == .text)
  }

  @Test func recordingHandsProminenceToSend() {
    // The voice button reads "Send" mid-recording and is what the next click is for.
    let recording = panel(voice: true, text: true, isRecordingReply: true)
    #expect(HermesPanelPrimaryAction.resolve(recording) == .voice)
    #expect(HermesPanelPrimaryAction.textIsDisabled(recording))
  }

  @Test func voiceIsPrimaryWhenThereIsNoTextReply() {
    #expect(HermesPanelPrimaryAction.resolve(panel(voice: true, text: false)) == .voice)
  }

  @Test func aDisabledControlIsNeverProminent() {
    // The regression this guards: an error panel disables both reply controls, so drawing
    // either one prominent points the eye at something that cannot be clicked.
    for voice in [true, false] {
      for text in [true, false] {
        let errored = panel(voice: voice, text: text, isError: true)
        #expect(HermesPanelPrimaryAction.resolve(errored) == .none)
      }
    }
  }

  @Test func aPanelWithNoReplyControlsHasNoPrimary() {
    #expect(HermesPanelPrimaryAction.resolve(panel(voice: false, text: false)) == .none)
  }

  // MARK: - Text reply send lifecycle (§4A)

  private func replyState(_ suffix: String) -> HermesResponseWindowState {
    HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000007\(suffix)")!,
      title: "Sam",
      text: "<p>Are we still on for 6?</p>",
      isHTML: true
    )
  }

  @Test func startingASendCommitsTheComposerAndClearsThePreviousFailure() {
    let target = replyState("10")
    let other = replyState("11")
    var failed = target
    failed.replyFailure = HermesReplyFailureCopy.beeperSendFailed

    let started = HermesResponseWindowLifecycle.replySendStarted(
      [failed, other],
      sessionID: target.id
    )

    // Both in one write: the button must read "Send Text" while this attempt is in flight, not
    // "Retry" left over from the last one.
    #expect(started[0].isSendingReply)
    #expect(started[0].replyFailure == nil)
    #expect(started[1] == other)
  }

  @Test func aFailedSendReportsTheCauseAndAlwaysReleasesTheComposer() {
    let target = replyState("12")
    let other = replyState("13")
    var sending = target
    sending.isSendingReply = true

    let failed = HermesResponseWindowLifecycle.replySendFailed(
      [sending, other],
      sessionID: target.id,
      failure: HermesReplyFailureCopy.beeperSendFailed
    )

    #expect(failed[0].replyFailure == HermesReplyFailureCopy.beeperSendFailed)
    // The panel that just failed is the one Dane has to retry from, so the lock must not survive.
    #expect(!failed[0].isSendingReply)
    #expect(!failed[0].isError)
    #expect(failed[1] == other)
  }

  @Test func finishingASendReleasesTheComposerWhateverTheOutcome() {
    let target = replyState("14")
    var sending = target
    sending.isSendingReply = true

    #expect(
      HermesResponseWindowLifecycle.replySendFinished([sending], sessionID: target.id) == [target]
    )
  }

  @Test func aRepresentedSnapshotCarriesTheTextAndIsNeverStillSending() {
    let target = replyState("15")
    var sending = target
    sending.isSendingReply = true

    let represented = HermesResponseWindowLifecycle.replyRepresented(
      sending,
      failure: HermesReplyFailureCopy.beeperSendFailed,
      preservedText: "Yes, 6 works"
    )

    // The snapshot was taken after the flag was set. Re-presenting it as-is is a panel locked out
    // of the retry it exists to offer.
    #expect(!represented.isSendingReply)
    #expect(represented.preservedReplyText == "Yes, 6 works")
    #expect(represented.replyFailure == HermesReplyFailureCopy.beeperSendFailed)
    // The inbound message is what Dane is replying to; the failure must not overwrite it.
    #expect(represented.text == target.text)
    #expect(represented.isHTML)
    #expect(!represented.isError)
  }

  @Test func cancelClearsOnlyTheFailureLine() {
    let target = replyState("16")
    let other = replyState("17")
    var failed = target
    failed.replyFailure = HermesReplyFailureCopy.hermesDisabled

    let cleared = HermesResponseWindowLifecycle.replyFailureCleared(
      [failed, other],
      sessionID: target.id
    )

    #expect(cleared == [target, other])
  }
}
