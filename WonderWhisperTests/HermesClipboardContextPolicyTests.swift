import Foundation
import Testing
@testable import WonderWhisper

struct HermesClipboardContextPolicyTests {
  @Test func textCopiedWithinDefaultWindowAttachesWhenRecordingStarts() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(15)

    let text = HermesClipboardContextPolicy.contextText(
      "https://example.com",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt
    )

    #expect(text == "https://example.com")
  }

  @Test func textCopiedWithinDefaultWindowStillAttachesWhenSendHappensAfterExpiry() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(15)
    let requestSentAt = recordingStartedAt.addingTimeInterval(20)

    let text = HermesClipboardContextPolicy.contextText(
      "Copied context",
      copiedAt: copiedAt,
      recordingStartedAt: recordingStartedAt,
      requestSentAt: requestSentAt
    )

    #expect(text == "Copied context")
  }

  @Test func textCopiedBeforeDefaultWindowDoesNotAttach() {
    let copiedAt = Date(timeIntervalSince1970: 1_000)
    let recordingStartedAt = copiedAt.addingTimeInterval(21)

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
    #expect(HermesClipboardContextPolicy.defaultRetentionWindow == 20)
    #expect(HermesClipboardContextPolicy.clampedRetentionWindow(60) == 60)
    #expect(HermesClipboardContextPolicy.clampedRetentionWindow(1_000) == 600)
  }
}
