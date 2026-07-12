import Foundation
import Testing
@testable import WonderWhisper

struct SimpleSidebarItemTests {
  @Test func meetingsFollowBeeperAboveHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(4) == [
      .hermes,
      .beeper,
      .meetings,
      .history
    ])
  }

  @Test func comparisonTabFollowsHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(5) == [
      .hermes,
      .beeper,
      .meetings,
      .history,
      .comparison
    ])
    #expect(SimpleSidebarItem.beeper.title == "Beeper")
    #expect(SimpleSidebarItem.comparison.title == "Compare")
  }
}
