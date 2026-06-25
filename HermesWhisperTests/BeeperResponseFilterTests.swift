import Foundation
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
