import Foundation
import Testing
@testable import WonderWhisper_Mac

struct HermesResponseWindowLifecycleTests {
  @Test func replyRecordingKeepsResponseVisibleUntilRecordingFinishes() {
    let response = HermesResponseWindowState(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
      title: "Hermes",
      text: "Use this response as context while replying."
    )

    #expect(HermesResponseWindowLifecycle.replyRecordingStarted(response) == response)
    #expect(HermesResponseWindowLifecycle.replyRecordingFinished(response) == nil)
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

    #expect(
      HermesResponseWindowLifecycle.replyRecordingStarted(states, sessionID: target.id)
      == states
    )
    #expect(
      HermesResponseWindowLifecycle.replyRecordingFinished(states, sessionID: target.id)
      == [other]
    )
  }
}
