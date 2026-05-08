import Foundation
import Testing
@testable import WonderWhisper_Mac

struct SimpleSidebarItemTests {
  @Test func hermesIsTheFirstSidebarItemAboveHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(2) == [.hermes, .history])
  }
}
