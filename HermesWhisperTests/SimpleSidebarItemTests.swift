import Foundation
import Testing
@testable import HermesWhisper

struct SimpleSidebarItemTests {
  @Test func hermesIsTheFirstSidebarItemAboveHistory() {
    #expect(SimpleSidebarItem.displayOrder.prefix(2) == [.hermes, .history])
  }
}
