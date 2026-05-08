import Foundation
import Testing
@testable import WonderWhisper_Mac

struct HermesClipboardContextPolicyTests {
  @Test func textCopiedWithinOneMinuteAttachesWhenRecordingStarts() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(55)

    let text = HermesClipboardContextPolicy.contextText(
      "https://example.com",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt
    )

    #expect(text == "https://example.com")
  }

  @Test func textCopiedWithinOneMinuteStillAttachesWhenSendHappensAfterExpiry() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(55)
    let requestSentAt = recordingStartedAt.addingTimeInterval(20)

    let text = HermesClipboardContextPolicy.contextText(
      "Copied context",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt,
      requestSentAt: requestSentAt
    )

    #expect(text == "Copied context")
  }

  @Test func textCopiedMoreThanOneMinuteBeforeRecordingDoesNotAttach() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(61)

    let text = HermesClipboardContextPolicy.contextText(
      "Old context",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt
    )

    #expect(text == nil)
  }
}
