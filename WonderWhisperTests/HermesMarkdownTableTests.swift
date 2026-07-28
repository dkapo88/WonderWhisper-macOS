import AppKit
import Testing
@testable import WonderWhisper

struct HermesMarkdownTableTests {
  private let actionItems = """
    Action items

    | Owner | Action | Due |
    | --- | --- | --- |
    | Speaker 1 | Rope in the person for content suite | Not specified |
    | Manish | Finish Ulta debugging | Aim Monday |

    Risks and blockers
    """

  @Test func pipeTableIsDetectedAndRenderedAsATable() {
    #expect(HermesMarkdownContent.containsTable(actionItems))

    let attributed = HermesMarkdownContent.nsAttributedString(from: actionItems)
    // Cells must carry real text blocks, which is what makes them lay out as columns.
    var foundTableBlock = false
    attributed.enumerateAttribute(
      .paragraphStyle,
      in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
      if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
        foundTableBlock = true
      }
    }
    #expect(foundTableBlock)
    // Surrounding prose survives.
    #expect(attributed.string.contains("Action items"))
    #expect(attributed.string.contains("Risks and blockers"))
    #expect(attributed.string.contains("Manish"))
  }

  @Test func plainTextCopyKeepsPipeTableForm() {
    let formatted = HermesMarkdownContent.plainFormattedString(from: actionItems)
    #expect(formatted.contains("| Owner | Action | Due |"))
    #expect(formatted.contains("| Manish | Finish Ulta debugging | Aim Monday |"))
  }

  @Test func pipeTextWithoutADelimiterRowStaysProse() {
    // Transcripts legitimately contain pipes; only a delimiter row makes a table.
    let prose = "We discussed A | B | C options today."
    #expect(!HermesMarkdownContent.containsTable(prose))
    #expect(HermesMarkdownContent.plainFormattedString(from: prose) == prose)
  }

  @Test func raggedRowsAreNormalizedToTheHeaderWidth() {
    // A short row must not silently drop the rest of the table.
    let ragged = """
      | A | B | C |
      | --- | --- | --- |
      | 1 | 2 |
      | 1 | 2 | 3 | 4 |
      """
    #expect(HermesMarkdownContent.containsTable(ragged))
    let formatted = HermesMarkdownContent.plainFormattedString(from: ragged)
    #expect(formatted.contains("| 1 | 2 |  |"))
    #expect(formatted.contains("| 1 | 2 | 3 |"))
  }

  @Test func escapedPipesStayInsideTheirCell() {
    let escaped = """
      | Key | Value |
      | --- | --- |
      | Regex | a \\| b |
      """
    let formatted = HermesMarkdownContent.plainFormattedString(from: escaped)
    #expect(formatted.contains("| Regex | a | b |"))
  }
}
