import Foundation
import Testing
@testable import WonderWhisper

struct BeeperMessageTextFormatterTests {
  @Test func formatsBeeperHTMLFragmentForResponseWindow() {
    let formatted = BeeperMessageTextFormatter.displayText(from: """
    Good. Send me that container name when you find it.<br><br>That’s actually useful, because it removes the awkward “blank means default” ambiguity. If Supermemory has a real canonical default container identifier, we can:<br><br>- set Hermes to use that explicitly<br>- patch/verify Codex hooks against the same value<br>- avoid accidental side buckets like <code>default</code>, <code>default</code>, or <code>hermes</code><br>- make audits cleaner because “default space” is no longer inferred from missing tags<br><br>When you send it, I’ll verify against the API before we trust it.
    """)

    #expect(formatted.contains("Good. Send me that container name when you find it.\n\n"))
    #expect(formatted.contains("- set Hermes to use that explicitly"))
    #expect(formatted.contains("- avoid accidental side buckets like `default`, `default`, or `hermes`"))
    #expect(!formatted.contains("<br>"))
    #expect(!formatted.contains("<code>"))
  }

  @Test func decodesCommonHTMLEntities() {
    let formatted = BeeperMessageTextFormatter.displayText(
      from: "Use <code>&lt;default&gt;</code> &amp; keep going."
    )

    #expect(formatted == "Use `<default>` & keep going.")
  }
}
