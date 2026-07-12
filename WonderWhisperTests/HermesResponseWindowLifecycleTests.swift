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
}
