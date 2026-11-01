import Foundation
import Testing
@testable import WonderWhisper

/// Bark Clean output fixes, on fixture strings (no audio). Most cases inject an identity
/// normalizer so they test this file's rules alone; the NeMo cases run the bundled engine.
struct BarkTranscriptCleanupTests {
  private let identity: BarkTranscriptCleanup.Normalizer = { $0 }

  @Test func stripsUnknownTokensAndTheirSpacing() {
    #expect(BarkTranscriptCleanup.stripUnknownTokens("He said <unk>ship it<unk>.") == "He said ship it.")
    #expect(BarkTranscriptCleanup.stripUnknownTokens("<unk> Hello <UNK> world <unk>") == "Hello world")
    #expect(BarkTranscriptCleanup.stripUnknownTokens("No tokens here.") == "No tokens here.")
  }

  @Test func neverLeavesUnknownInCleanedOutput() {
    let raw = ["<unk>", "a <unk>quote<unk>, then more", "<unk><unk>", "version4 .2 <unk>"]
    for text in raw {
      #expect(!BarkTranscriptCleanup.clean(text).lowercased().contains("<unk>"), "\(text)")
      #expect(!BarkTranscriptCleanup.clean(text, normalizer: identity).contains("unk"), "\(text)")
    }
  }

  @Test func capitalisesTheFirstLetterOnly() {
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("we should not launch.") == "We should not launch.")
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("\"so, yes\"") == "\"So, yes\"")
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("Already fine.") == "Already fine.")
    // A first word with its own capitals is a name or brand.
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("iPhone sales rose.") == "iPhone sales rose.")
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("") == "")
    #expect(BarkTranscriptCleanup.capitalizingFirstLetter("42 is it") == "42 is it")
  }

  @Test func fixesSplitDecimalsAndPercentSpacing() {
    #expect(BarkTranscriptCleanup.fixNumberSpacing("version4 .2 ships") == "version 4.2 ships")
    #expect(BarkTranscriptCleanup.fixNumberSpacing("about 4 .2 seconds") == "about 4.2 seconds")
    #expect(BarkTranscriptCleanup.fixNumberSpacing("up 17 % today") == "up 17% today")
    #expect(BarkTranscriptCleanup.fixNumberSpacing("at 02:30 p.m.. Then") == "at 2:30 p.m. Then")
    // Ordinary sentence ends and model names stay intact.
    #expect(BarkTranscriptCleanup.fixNumberSpacing("We have 4. 2 are left.") == "We have 4. 2 are left.")
    #expect(BarkTranscriptCleanup.fixNumberSpacing("Q3 and MP3 are fine.") == "Q3 and MP3 are fine.")
    #expect(BarkTranscriptCleanup.fixNumberSpacing("at 10:30") == "at 10:30")
  }

  @Test func cleanRunsEveryStepInOrder() {
    let cleaned = BarkTranscriptCleanup.clean("we are not shipping version4 .2, he said <unk>no<unk>.",
                                              normalizer: identity)
    #expect(cleaned == "We are not shipping version 4.2, he said no.")
  }

  @Test func standaloneSmallNumbersAreHiddenFromTheNormalizer() {
    // The fake normalizer writes every number word it sees as a digit.
    let digits: BarkTranscriptCleanup.Normalizer = { text in
      let map = ["one": "1", "two": "2", "three": "3", "nine": "9", "second": "2nd", "seventeen": "17"]
      return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
        map[String(word)] ?? String(word)
      }.joined(separator: " ")
    }
    #expect(BarkTranscriptCleanup.normalizeNumbers("one of the best", normalizer: digits) == "one of the best")
    #expect(BarkTranscriptCleanup.normalizeNumbers("in a second", normalizer: digits) == "in a second")
    #expect(BarkTranscriptCleanup.normalizeNumbers("Nine of them", normalizer: digits) == "Nine of them")
    #expect(BarkTranscriptCleanup.normalizeNumbers("seventeen days", normalizer: digits) == "17 days")
    // Next to another number word or a unit, a small number is part of the expression.
    #expect(BarkTranscriptCleanup.normalizeNumbers("one two three", normalizer: digits) == "1 2 3")
    #expect(BarkTranscriptCleanup.normalizeNumbers("two percent", normalizer: digits) == "2 percent")
  }

  @Test func keepsTheTextWhenTheNormalizerDropsAProtectedWord() {
    let lossy: BarkTranscriptCleanup.Normalizer = { _ in "gone" }
    #expect(BarkTranscriptCleanup.normalizeNumbers("one of us", normalizer: lossy) == "one of us")
  }

  // MARK: - Bundled NeMo ITN (deterministic)

  @Test(arguments: [
    ("No, I said seventeen percent, not seventy percent, and the budget is one point two million.",
     "No, I said 17%, not 70%, and the budget is 1.2 million."),
    ("the meeting moved to Thursday the sixteenth at two thirty p.m.",
     "The meeting moved to Thursday the 16th at 2:30 p.m."),
    ("There were twenty three attendees, nine of whom never received the agenda.",
     "There were 23 attendees, nine of whom never received the agenda."),
    ("The total is five hundred and twenty dollars.", "The total is $520."),
    ("We are not shipping version four point two this week.", "We are not shipping version 4.2 this week."),
    ("I think one of the best options is to wait.", "I think one of the best options is to wait."),
    ("I'll send it in a second, okay?", "I'll send it in a second, okay?"),
    ("Please do not approve the invoice for $3,450 until Priya Raman signs it.",
     "Please do not approve the invoice for $3,450 until Priya Raman signs it.")
  ])
  func writesNumbersConsistentlyWithTheBundledNormalizer(raw: String, expected: String) {
    #expect(BarkTranscriptCleanup.clean(raw) == expected)
  }
}
