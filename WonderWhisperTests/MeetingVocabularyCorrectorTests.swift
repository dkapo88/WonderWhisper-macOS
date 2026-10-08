import Foundation
import Testing
@testable import WonderWhisper

struct MeetingVocabularyCorrectorTests {
  private func token(_ text: String, _ start: Double, source: MeetingAudioSource = .microphone)
    -> MeetingTranscriptToken {
    MeetingTranscriptToken(source: source, startTime: start, endTime: start + 0.08, text: text)
  }

  @Test func replacedSubwordRunCollapsesIntoOneTimedToken() throws {
    let raw = [token(" Send", 0), token(" it", 0.3), token(" to", 0.5),
               token(" Ni", 0.7), token("ve", 0.8), token(" today", 1.1)]
    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: raw,
      rescoredText: "Send it to Niamh today"
    )
    let correction = try #require(corrections.first)
    #expect(corrections.count == 1)
    #expect(correction.replacedTokenIDs == [raw[3].id, raw[4].id])
    #expect(correction.replacement.text == " Niamh")
    #expect(correction.replacement.startTime == 0.7)
    #expect(correction.replacement.endTime == raw[4].endTime)
    #expect(correction.replacement.source == .microphone)

    let applied = MeetingVocabularyCorrector.apply(corrections, to: raw)
    #expect(applied.map(\.text).joined() == " Send it to Niamh today")
    #expect(applied.count == 5)
  }

  @Test func multiWordMisrecognitionBecomesOneTerm() {
    let raw = [token(" We", 0), token(" use", 0.2), token(" hap", 0.4), token(" anna", 0.6),
               token(" for", 0.9), token(" bookings", 1.0), token(" daily", 1.4)]
    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: raw,
      rescoredText: "We use Hapana for bookings daily"
    )
    #expect(corrections.count == 1)
    #expect(corrections.first?.replacedTokenIDs == [raw[2].id, raw[3].id])
    #expect(corrections.first?.replacement.text == " Hapana")
  }

  @Test func unchangedOrUntrustedTextProducesNoCorrections() {
    let raw = [token(" Hello", 0), token(" there", 0.3), token(" friend", 0.6), token(" again", 0.9)]
    #expect(MeetingVocabularyCorrector.corrections(rawTokens: raw, rescoredText: "Hello there friend again").isEmpty)
    #expect(MeetingVocabularyCorrector.corrections(rawTokens: raw, rescoredText: "").isEmpty)
    #expect(MeetingVocabularyCorrector.corrections(rawTokens: [], rescoredText: "Hello").isEmpty)
    // Every word changed: alignment not trusted, keep the raw transcript.
    #expect(MeetingVocabularyCorrector.corrections(rawTokens: raw, rescoredText: "Hi Biso pal Jarron").isEmpty)
  }

  @Test func pureDeletionsKeepTheRawWords() {
    let raw = (0..<8).map { token(" w\($0)", Double($0)) }
    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: raw,
      rescoredText: "w0 w1 w2 w4 w5 w6 w7"
    )
    #expect(corrections.isEmpty)
  }

  @Test func applySkipsStaleCorrections() {
    let tokens = [token(" a", 0), token(" b", 1)]
    let stale = MeetingTokenCorrection(replacedTokenIDs: [UUID()], replacement: token(" z", 0))
    #expect(MeetingVocabularyCorrector.apply([stale], to: tokens) == tokens)
  }

  /// Regression (review P3): adjacent one-to-one substitutions used to collapse
  /// into one token at the first word's time, pulling "Hapana" from 5 s to 1 s
  /// ahead of the other speaker's reply.
  @Test func adjacentSubstitutionsKeepTheirOwnTimingAcrossAnotherSpeaker() throws {
    let mic = [token(" Send", 0), token(" Nive", 1), token(" Hapanna", 5), token(" tomorrow", 5.4)]
    let system = token(" Okay", 3, source: .systemAudio)
    let session = MeetingTranscriptFormatter.chronologicalTokens(mic + [system])
    #expect(
      MeetingTranscriptFormatter.plainText(tokens: session)
        == "Microphone: Send Nive\nSystem audio: Okay\nMicrophone: Hapanna tomorrow"
    )

    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: mic,
      rescoredText: "Send Niamh Hapana tomorrow"
    )
    #expect(corrections.count == 2)
    let hapana = try #require(corrections.first { $0.replacement.text == " Hapana" })
    #expect(hapana.replacement.startTime == 5)
    #expect(hapana.replacedTokenIDs == [mic[2].id])

    let applied = MeetingVocabularyCorrector.apply(corrections, to: session)
    #expect(
      MeetingTranscriptFormatter.plainText(tokens: applied)
        == "Microphone: Send Niamh\nSystem audio: Okay\nMicrophone: Hapana tomorrow"
    )
  }

  /// Regression (review P3): a many-to-one correction whose span contains
  /// another source's speech is skipped rather than moving words across it.
  @Test func multiWordCorrectionCrossingAnotherSourceIsSkipped() {
    let mic = [token(" We", 0), token(" use", 0.2), token(" hap", 0.4), token(" anna", 2.0),
               token(" for", 2.3), token(" bookings", 2.5), token(" daily", 2.9)]
    let system = token(" Right", 1.0, source: .systemAudio)
    let session = MeetingTranscriptFormatter.chronologicalTokens(mic + [system])
    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: mic,
      rescoredText: "We use Hapana for bookings daily"
    )
    #expect(corrections.count == 1)
    #expect(MeetingVocabularyCorrector.apply(corrections, to: session) == session)
    // Without the interruption the same correction applies.
    #expect(MeetingVocabularyCorrector.apply(corrections, to: mic).map(\.text).joined()
      == " We use Hapana for bookings daily")
  }
}
