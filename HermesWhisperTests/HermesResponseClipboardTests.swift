import AppKit
import Testing
@testable import HermesWhisper

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

  @Test func copiesFormattedResponseTextAsRichTextAndPlainFallback() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(
      "HermesResponseClipboardTests.\(UUID().uuidString)"
    ))
    pasteboard.clearContents()

    let copied = HermesResponseClipboard.copyFormatted(
      "Here is the answer.\n\n- **First point**\n- Second point",
      to: pasteboard
    )

    #expect(copied)
    #expect(
      pasteboard.string(forType: .string)
        == "Here is the answer.\n\n• First point\n• Second point"
    )
    #expect(pasteboard.data(forType: .rtf) != nil)
    #expect(pasteboard.data(forType: .html) != nil)
  }

  @Test func formattedPlainFallbackPreservesMarkdownBlockStructure() {
    let formatted = HermesMarkdownContent.plainFormattedString(
      from: """
      Got it. I've updated the meeting source priority.

      **What changed:**

      1. **Skill: `hapana-meeting-notes-task-sync`** — Source priority rewritten:
      - Fireflies is now primary
      - Google Drive Gemini notes is fallback

      ```text
      TASKS.md Overnight Hydrator
      ```
      """
    )

    #expect(formatted.contains("What changed:"))
    #expect(formatted.contains("1. Skill: hapana-meeting-notes-task-sync"))
    #expect(formatted.contains("• Fireflies is now primary"))
    #expect(formatted.contains("TASKS.md Overnight Hydrator"))
    #expect(!formatted.contains("changed:Skill"))
  }
}
