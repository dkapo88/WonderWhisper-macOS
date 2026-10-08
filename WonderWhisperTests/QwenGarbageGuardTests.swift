import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Garbage guard

struct QwenGarbageGuardTests {
  @Test func flagsTokenZeroBangRuns() {
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "!", count: 448), sampleCount: 16_000 * 3
    ))
    #expect(QwenASRManager.looksLikeDegenerateTranscript("!!!!!!!!!", sampleCount: 16_000))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      "Hello" + String(repeating: "!", count: 12), sampleCount: 16_000
    ))
  }

  @Test func flagsLoopsAndSymbolRuns() {
    let loop = Array(repeating: "the", count: 14).joined(separator: " ")
    #expect(QwenASRManager.looksLikeDegenerateTranscript(loop, sampleCount: 16_000 * 5))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "?", count: 20), sampleCount: 16_000
    ))
    #expect(QwenASRManager.degenerateReason(
      String(repeating: "!", count: 448), sampleCount: 16_000
    ) != nil)
  }

  @Test func keepsLegitShortAndPunctuationOnlyText() {
    let legit = [
      "OK!", "Wow!!!", "Hi.", "...", "?", "—", "…", "Yes, yes, yes.", "No no no no.",
      "Hello, world!", "Wait...... what?", "Okay.", "Go! Go! Go!", "100%", "3.14159",
      "Send it to Dane at 5 p.m.", "The quick brown fox jumps over the lazy dog.",
    ]
    for text in legit {
      #expect(
        !QwenASRManager.looksLikeDegenerateTranscript(text, sampleCount: 16_000),
        "false positive on \(text)"
      )
    }
    // Normal long dictation at a realistic rate.
    let paragraph = String(
      repeating: "Please move the meeting with Sonali to Thursday afternoon. ", count: 6
    )
    #expect(!QwenASRManager.looksLikeDegenerateTranscript(paragraph, sampleCount: 16_000 * 30))
  }
}
