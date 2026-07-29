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

  @Test func responsePillIsCompactAndMeetsTheMinimumHitTarget() {
    let size = HermesResponseWindowLayout.pillSize

    #expect(size.width > size.height)
    // Wide enough to carry a chat title, still a pill rather than a window.
    #expect(size.width <= 220)
    #expect(size.height >= 44)
    #expect(size.height <= 60)
  }

  @Test func responseSourcesUseExactLabelsAndSupportedDistinctGlyphs() {
    let sources = HermesResponseSource.allCases

    #expect(sources.map(\.label) == ["Beeper", "Hermes", "Codex"])
    #expect(Set(sources.map(\.symbolName)).count == sources.count)
    for source in sources {
      #expect(!source.label.isEmpty)
      #expect(!source.symbolName.isEmpty)
      #expect(NSImage(systemSymbolName: source.symbolName, accessibilityDescription: nil) != nil)
    }
  }

  @Test func responseSourceDoesNotDependOnTheWindowTitle() {
    let states = [
      HermesResponseWindowState(source: .beeper, title: "Codex", text: "One"),
      HermesResponseWindowState(source: .hermes, title: "", text: "Two"),
      HermesResponseWindowState(source: .codex, title: "Beeper - Sam", text: "Three")
    ]

    #expect(states.map { $0.source.label } == ["Beeper", "Hermes", "Codex"])
    #expect(states.map { $0.source.symbolName } == HermesResponseSource.allCases.map(\.symbolName))
  }

  @Test func responsePillStateUsesRealStateWithDeterministicPrecedence() {
    var state = HermesResponseWindowState(source: .hermes, title: "Hermes", text: "Done")
    #expect(state.pillStatus == .normal)

    state.isSendingReply = true
    #expect(state.pillStatus == .sending)

    state.isRecordingReply = true
    #expect(state.pillStatus == .recording)

    state.isError = true
    #expect(state.pillStatus == .error)
  }

  @Test func lifecycleTransformsPreserveExplicitSourceIdentity() {
    let target = HermesResponseWindowState(source: .beeper, title: "Codex", text: "Target")
    let other = HermesResponseWindowState(source: .codex, title: "Hermes", text: "Other")

    let recording = HermesResponseWindowLifecycle.replyRecordingStarted(
      [target, other], sessionID: target.id
    )
    #expect(recording[0].source == .beeper)
    #expect(recording[1].source == .codex)
    #expect(
      HermesResponseWindowLifecycle.replyRecordingCancelled(recording[0])?.source == .beeper
    )
    #expect(
      HermesResponseWindowLifecycle.replyRecordingCancelled(recording, sessionID: target.id)[0]
        .source == .beeper
    )
    #expect(
      HermesResponseWindowLifecycle.replyRecordingFinished(recording, sessionID: target.id)[0]
        .source == .codex
    )

    let sending = HermesResponseWindowLifecycle.replySendStarted(
      [target], sessionID: target.id
    )
    #expect(sending[0].source == .beeper)
    #expect(
      HermesResponseWindowLifecycle.replySendFinished(sending, sessionID: target.id)[0].source
        == .beeper
    )
    let failed = HermesResponseWindowLifecycle.replySendFailed(
      sending,
      sessionID: target.id,
      failure: HermesReplyFailureCopy.beeperSendFailed
    )
    #expect(failed[0].source == .beeper)
    #expect(
      HermesResponseWindowLifecycle.replyFailureCleared(failed, sessionID: target.id)[0].source
        == .beeper
    )
    #expect(
      HermesResponseWindowLifecycle.replyRepresented(
        sending[0],
        failure: HermesReplyFailureCopy.beeperSendFailed,
        preservedText: "Draft"
      ).source == .beeper
    )
    #expect(
      HermesResponseWindowLifecycle.burstCoalesced(
        [target],
        sessionID: target.id,
        title: "Hermes",
        text: "Updated",
        isHTML: false,
        newerCount: 0
      )[0].source == .beeper
    )
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
      source: .hermes,
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
      source: .hermes,
      title: "Hermes",
      text: "Target response"
    )
    let other = HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
      source: .hermes,
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
      source: .hermes,
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
      source: .beeper,
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

  @Test func coalescingABurstMovesTheBodyAndLeavesTheReplyInFlightAlone() {
    let target = replyState("18")
    let other = replyState("19")
    var live = target
    live.isSendingReply = true
    live.isRecordingReply = true
    live.replyFailure = HermesReplyFailureCopy.beeperSendFailed
    live.preservedReplyText = "Yes, 6 works"

    let coalesced = HermesResponseWindowLifecycle.burstCoalesced(
      [live, other],
      sessionID: target.id,
      title: "Ash",
      text: "make it 7",
      isHTML: false,
      newerCount: 0
    )

    #expect(coalesced[0].title == "Ash")
    #expect(coalesced[0].text == "make it 7")
    #expect(!coalesced[0].isHTML)
    #expect(coalesced[0].newerCount == 0)
    // The reason this is not a freshly built state: everything the panel owns about the reply in
    // progress survives the update.
    #expect(coalesced[0].isSendingReply)
    #expect(coalesced[0].isRecordingReply)
    #expect(coalesced[0].replyFailure == HermesReplyFailureCopy.beeperSendFailed)
    #expect(coalesced[0].preservedReplyText == "Yes, 6 works")
    #expect(coalesced[1] == other)
  }

  @Test func holdingTheBodyStillMovesTheNewCount() {
    let target = replyState("20")

    let held = HermesResponseWindowLifecycle.burstCoalesced(
      [target],
      sessionID: target.id,
      newerCount: 3
    )

    // The draft-safety rule: the message Dane is answering stays put while the count climbs.
    #expect(held[0].title == target.title)
    #expect(held[0].text == target.text)
    #expect(held[0].isHTML == target.isHTML)
    #expect(held[0].newerCount == 3)
    // Held is still an arrival, so it still asks for the restore. Otherwise a minimized panel
    // holding a draft would swallow the burst silently — the exact bug, one branch over.
    #expect(held[0].burstArrivals == target.burstArrivals + 1)
    #expect(
      HermesResponseWindowLifecycle.burstRestoreSessionIDs(previous: [target], current: held)
        == [target.id]
    )
  }

  @Test func coalescingIntoAnAbsentPanelChangesNothing() {
    let states = [replyState("21"), replyState("22")]

    #expect(
      HermesResponseWindowLifecycle.burstCoalesced(
        states,
        sessionID: UUID(),
        title: "Ash",
        text: "make it 7",
        isHTML: false,
        newerCount: 9
      ) == states
    )
  }
}
