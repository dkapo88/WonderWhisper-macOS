import Foundation
import AppKit
import Testing
@testable import HermesWhisper

@MainActor
struct BeeperResponseFilterTests {
  @Test func emptyKeywordsNeverFilter() {
    #expect(!DictationViewModel.beeperResponseIsFiltered("running bash", keywords: ""))
    #expect(!DictationViewModel.beeperResponseIsFiltered("anything", keywords: "  ,  \n "))
  }

  @Test func matchesContainedTermCaseInsensitively() {
    let keywords = "running, bash"
    #expect(DictationViewModel.beeperResponseIsFiltered("Running tool…", keywords: keywords))
    #expect(DictationViewModel.beeperResponseIsFiltered("about to BASH something", keywords: keywords))
    #expect(!DictationViewModel.beeperResponseIsFiltered("Here is your final answer.", keywords: keywords))
  }

  @Test func splitsOnCommasAndNewlines() {
    let terms = DictationViewModel.beeperResponseFilterTerms("running,\n bash , , Tool ")
    #expect(terms == ["running", "bash", "tool"])
  }

  @Test func parsesChatIDsOrderedTrimmedDeduped() {
    let ids = DictationViewModel.parseBeeperChatIDs(" chat1,\n chat2 , , chat1\nchat3 ")
    #expect(ids == ["chat1", "chat2", "chat3"])  // order kept, blanks dropped, chat1 deduped
    #expect(DictationViewModel.parseBeeperChatIDs("  \n , ").isEmpty)
  }

  @Test func htmlDetectionMatchesTagsNotGenericsOrComparisons() {
    #expect(BeeperMessageTextFormatter.containsHTMLTags("<p>hi</p>"))
    #expect(BeeperMessageTextFormatter.containsHTMLTags("a <strong>b</strong>"))
    #expect(BeeperMessageTextFormatter.containsHTMLTags("see <code>x</code>"))
    // Must NOT trip on code generics or math in an otherwise plain-text reply.
    #expect(!BeeperMessageTextFormatter.containsHTMLTags("Use Array<Int> when x < y and y > z"))
    #expect(!BeeperMessageTextFormatter.containsHTMLTags("no markup here"))
  }

  @Test func htmlImportStripsTagsAndKeepsBoldAndMonospace() {
    let html = "<p><strong>Vision:</strong> uses <code>vision_analyze</code> now</p>"
    guard let attributed = HermesMarkdownContent.htmlAttributedString(from: html) else {
      Issue.record("HTML import returned nil")
      return
    }
    let rendered = attributed.string
    #expect(!rendered.contains("<") && !rendered.contains(">"))  // tags gone
    #expect(rendered.contains("Vision:"))
    #expect(rendered.contains("vision_analyze"))

    var hasBold = false
    var hasMono = false
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      guard let font = value as? NSFont else { return }
      let traits = font.fontDescriptor.symbolicTraits
      if traits.contains(.bold) { hasBold = true }
      if traits.contains(.monoSpace) { hasMono = true }
    }
    #expect(hasBold)  // <strong> survived normalization
    #expect(hasMono)  // <code> survived normalization
  }

  @Test func dedupedChatIDsTrimsDropsBlanksAndDuplicates() {
    let chats = [
      BeeperChatEntry(chatID: " chat1 ", alias: "Mum"),
      BeeperChatEntry(chatID: "", alias: "blank row"),
      BeeperChatEntry(chatID: "chat2", alias: "Work"),
      BeeperChatEntry(chatID: "chat1", alias: "dup"),
    ]
    // Gates monitor spawning: order kept, blanks dropped, chat1 deduped.
    #expect(DictationViewModel.dedupedChatIDs(chats) == ["chat1", "chat2"])
  }
}
