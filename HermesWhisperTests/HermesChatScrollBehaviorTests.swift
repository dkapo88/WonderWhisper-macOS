import Testing
@testable import HermesWhisper

struct HermesChatScrollBehaviorTests {
  @Test func persistedHistoryScrollsToLatestMessageWhenChatAppears() {
    #expect(HermesChatScrollBehavior.shouldScrollToLatestOnAppear(messageCount: 3))
  }

  @Test func emptyHistoryDoesNotRequestInitialScroll() {
    #expect(!HermesChatScrollBehavior.shouldScrollToLatestOnAppear(messageCount: 0))
  }
}
