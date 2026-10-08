import Foundation
import Testing
@testable import WonderWhisper

struct SimpleSidebarItemTests {
  @Test func sidebarHoldsOnlyWorkSurfacesInGroupedOrder() {
    #expect(SimpleSidebarItem.displayOrder == [
      .history,
      .meetings,
      .dictation,
      .command,
      .hermes,
      .vocabulary,
      .comparison
    ])
    #expect(SimpleSidebarItem.comparison.title == "Compare")
    #expect(SimpleSidebarItem.Group.allCases.map(\.title) == ["Library", "Modes", "Agents", "Tools"])
  }

  @Test func removedSidebarItemsNoLongerDecode() {
    // Persisted selections for pages that moved into the Settings window fall back to the
    // default instead of crashing or showing an empty detail.
    for raw in ["settings", "codex", "beeper", "microphone", "permissions"] {
      #expect(SimpleSidebarItem(rawValue: raw) == nil)
    }
  }
}
