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
      .codex,
      .beeper,
      .hermes,
      .vocabulary,
      .microphone,
      .comparison,
      .permissions,
      .settings
    ])
    #expect(SimpleSidebarItem.codex.title == "Codex")
    #expect(SimpleSidebarItem.beeper.title == "Beeper")
    #expect(SimpleSidebarItem.comparison.title == "Compare")
  }
}
