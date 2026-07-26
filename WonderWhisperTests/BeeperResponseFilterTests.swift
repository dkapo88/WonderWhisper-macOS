import Foundation
import AppKit
import Testing
@testable import WonderWhisper

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

  @Test func chatEntryDecodesLegacyJSONWithoutIsEnabled() {
    // Chats persisted before isEnabled existed must still load (and default to on).
    let json = #"[{"id":"5E9F1C3A-0000-0000-0000-000000000001","chatID":"826380","alias":"Hermes"}]"#
    let chats = try! JSONDecoder().decode([BeeperChatEntry].self, from: Data(json.utf8))
    #expect(chats.count == 1)
    #expect(chats[0].chatID == "826380")
    #expect(chats[0].alias == "Hermes")
    #expect(chats[0].isEnabled == true)
  }

  @Test func dedupedChatIDsExcludesDisabledChats() {
    let chats = [
      BeeperChatEntry(chatID: "chat1", alias: "On", isEnabled: true),
      BeeperChatEntry(chatID: "chat2", alias: "Paused", isEnabled: false),
      BeeperChatEntry(chatID: "chat3", alias: "On", isEnabled: true),
    ]
    #expect(DictationViewModel.dedupedChatIDs(chats) == ["chat1", "chat3"])  // chat2 paused
  }

  /// Incoming text message from `sender`, timestamped `at` (ISO 8601).
  private func incoming(_ id: String, at timestamp: String, text: String? = nil) -> BeeperMessage {
    BeeperMessage(
      id: id,
      chatID: "chat1",
      senderName: "Sam",
      timestampString: timestamp,
      text: text ?? "message \(id)",
      type: "TEXT",
      isSender: false
    )
  }

  @Test func pollCandidatesKeepWholeBurstNewestLast() {
    // Three messages between polls arrive on one page, deliberately out of order.
    let page = [
      incoming("b", at: "2026-07-26T09:00:05Z"),
      incoming("c", at: "2026-07-26T09:00:09Z"),
      incoming("a", at: "2026-07-26T09:00:01Z"),
    ]
    let candidates = DictationViewModel.beeperPollCandidates(
      page: page,
      seenMessageIDs: [],
      baselineDate: .distantPast,
      hadCursor: true
    )
    #expect(candidates.map(\.id) == ["a", "b", "c"])  // whole burst reaches the caller, ascending
    #expect(candidates.last?.id == "c")  // presented message is the newest, not the stalest
  }

  @Test func newestUnfilteredCandidateSkipsFilteredTailInsteadOfSuppressingTheBurst() {
    let burst = [
      incoming("a", at: "2026-07-26T09:00:01Z", text: "moved to 3pm"),
      incoming("b", at: "2026-07-26T09:00:05Z", text: "see you then"),
      incoming("c", at: "2026-07-26T09:00:09Z", text: "ok"),  // newest, filtered
    ]
    let picked = DictationViewModel.newestUnfilteredBeeperCandidate(burst, keywords: "ok")
    #expect(picked?.id == "b")  // newest survivor, not nothing at all

    // Every candidate filtered still suppresses, as the filter intends.
    #expect(DictationViewModel.newestUnfilteredBeeperCandidate(burst, keywords: "moved, see, ok") == nil)
    // No filter set: unchanged, the newest wins.
    #expect(DictationViewModel.newestUnfilteredBeeperCandidate(burst, keywords: "")?.id == "c")
  }

  @Test func pollCandidatesDropSeenAndPreBaselineMessages() {
    let baseline = ISO8601DateFormatter().date(from: "2026-07-26T09:00:00Z")!
    let page = [
      incoming("old", at: "2026-07-26T08:59:59Z"),  // backfill, before monitoring started
      incoming("seen", at: "2026-07-26T09:00:05Z"),
      incoming("new", at: "2026-07-26T09:00:06Z"),
      BeeperMessage(id: "mine", chatID: "chat1", timestampString: "2026-07-26T09:00:07Z",
                    text: "sent by me", type: "TEXT", isSender: true),
    ]
    let candidates = DictationViewModel.beeperPollCandidates(
      page: page,
      seenMessageIDs: ["seen"],
      baselineDate: baseline,
      hadCursor: false
    )
    #expect(candidates.map(\.id) == ["new"])
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
