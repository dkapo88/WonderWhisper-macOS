import Foundation
import Testing
@testable import WonderWhisper

struct SimpleSidebarItemTests {
  @Test func sidebarMatchesProductOrder() {
    #expect(SimpleSidebarItem.displayOrder == [
      .history,
      .dictation,
      .command,
      .meetings,
      .beeper,
      .hermes,
      .vocabulary,
      .microphone,
      .comparison,
      .permissions,
      .settings
    ])
    #expect(SimpleSidebarItem.beeper.title == "Beeper")
    #expect(SimpleSidebarItem.comparison.title == "Compare")
  }
}
