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

  @Test func customRetentionWindowControlsClipboardEligibility() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(90)

    let included = HermesClipboardContextPolicy.contextText(
      "Still relevant",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt,
      retentionWindow: 120
    )
    let excluded = HermesClipboardContextPolicy.contextText(
      "Too old",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt,
      retentionWindow: 30
    )

    #expect(included == "Still relevant")
    #expect(excluded == nil)
  }

  @Test func retentionWindowClampsToSupportedRange() {
    #expect(HermesClipboardContextPolicy.clampedRetentionWindow(0) == 1)
    #expect(HermesClipboardContextPolicy.clampedRetentionWindow(60) == 60)
    #expect(HermesClipboardContextPolicy.clampedRetentionWindow(1_000) == 600)
  }
}
