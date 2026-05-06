import AppKit
import Testing
@testable import WonderWhisper_Mac

@MainActor
struct HermesResponseClipboardTests {
  @Test func copiesResponseTextToPasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(
      "HermesResponseClipboardTests.\(UUID().uuidString)"
    ))
    pasteboard.clearContents()

    let copied = HermesResponseClipboard.copy(
      "Here is the answer.\n- First point\n- Second point",
      to: pasteboard
    )

    #expect(copied)
    #expect(
      pasteboard.string(forType: .string)
        == "Here is the answer.\n- First point\n- Second point"
    )
  }
}
