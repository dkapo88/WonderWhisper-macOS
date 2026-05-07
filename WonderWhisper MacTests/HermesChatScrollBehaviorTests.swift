import Testing
@testable import WonderWhisper_Mac

struct HermesChatScrollBehaviorTests {
  @Test func persistedHistoryScrollsToLatestMessageWhenChatAppears() {
    #expect(HermesChatScrollBehavior.shouldScrollToLatestOnAppear(messageCount: 3))
  }

  @Test func emptyHistoryDoesNotRequestInitialScroll() {
    #expect(!HermesChatScrollBehavior.shouldScrollToLatestOnAppear(messageCount: 0))
  }
}
