import AppKit

enum HermesResponseClipboard {
  @discardableResult
  @MainActor
  static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    copyRaw(text, to: pasteboard)
  }

  @discardableResult
  @MainActor
  static func copyRaw(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }

  @discardableResult
  @MainActor
  static func copyFormatted(_ markdown: String,
                            isHTML: Bool = false,
                            to pasteboard: NSPasteboard = .general) -> Bool {
    let attributed: NSAttributedString
    let plainFallback: String
    if isHTML, let html = HermesMarkdownContent.htmlAttributedString(from: markdown) {
      attributed = html
      plainFallback = html.string.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      attributed = HermesMarkdownContent.nsAttributedString(from: markdown)
      plainFallback = HermesMarkdownContent.plainFormattedString(from: markdown)
    }
    let fullRange = NSRange(location: 0, length: attributed.length)
    let item = NSPasteboardItem()
    item.setString(plainFallback, forType: .string)

    if let rtf = try? attributed.data(
      from: fullRange,
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) {
      item.setData(rtf, forType: .rtf)
    }
    if let html = try? attributed.data(
      from: fullRange,
      documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
    ) {
      item.setData(html, forType: .html)
    }

    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}
