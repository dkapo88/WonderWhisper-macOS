import Foundation
import Testing
@testable import HermesWhisper

struct SimpleSidebarItemTests {
  @Test func hermesIsTheFirstSidebarItemAboveHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(3) == [.hermes, .beeper, .history])
  }

  @Test func comparisonTabFollowsHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(4) == [.hermes, .beeper, .history, .comparison])
    #expect(SimpleSidebarItem.beeper.title == "Beeper")
    #expect(SimpleSidebarItem.comparison.title == "Compare")
  }
}
