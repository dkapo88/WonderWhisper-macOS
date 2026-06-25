import AppKit
import SwiftUI

struct HermesMarkdownView: View {
  var text: String
  /// When true, `text` is an HTML fragment and is rendered via the native
  /// AppKit HTML importer instead of the markdown parser.
  var isHTML: Bool = false

  var body: some View {
    Text(HermesMarkdownContent.attributedString(from: text, isHTML: isHTML))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum HermesMarkdownContent {
  static func attributedString(from markdown: String, isHTML: Bool = false) -> AttributedString {
    if isHTML, let html = htmlAttributedString(from: markdown) {
      return AttributedString(html)
    }
    return AttributedString(nsAttributedString(from: markdown))
  }

  // ponytail: NSAttributedString(html:) parses on the main thread (cheap for the
  // small fragments Beeper sends). If large messages jank, pre-render into the
  // window state off the SwiftUI body instead.
  static func htmlAttributedString(from html: String) -> NSAttributedString? {
    guard let data = html.data(using: .utf8) else { return nil }
    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]
    guard let parsed = try? NSMutableAttributedString(
      data: data, options: options, documentAttributes: nil
    ) else {
      return nil
    }
    normalizeImportedHTML(parsed)
    while parsed.string.hasSuffix("\n") {
      parsed.deleteCharacters(in: NSRange(location: parsed.length - 1, length: 1))
    }
    return parsed
  }

  /// The HTML importer uses Times/Helvetica and hard-coded black text. Remap to
  /// the system font (preserving bold/italic/monospace traits and heading sizes)
  /// and `labelColor` so it matches the app and works in dark mode. Links keep
  /// their own color.
  private static func normalizeImportedHTML(_ attributed: NSMutableAttributedString) {
    let fullRange = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
      guard let font = value as? NSFont else { return }
      let traits = font.fontDescriptor.symbolicTraits
      let size = font.pointSize <= 14 ? NSFont.systemFontSize : font.pointSize
      var replacement: NSFont
      if traits.contains(.monoSpace) {
        replacement = NSFont.monospacedSystemFont(
          ofSize: size, weight: traits.contains(.bold) ? .bold : .regular
        )
      } else {
        replacement = NSFont.systemFont(ofSize: size)
        if traits.contains(.bold) {
          replacement = NSFontManager.shared.convert(replacement, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italic) {
          replacement = NSFontManager.shared.convert(replacement, toHaveTrait: .italicFontMask)
        }
      }
      attributed.addAttribute(.font, value: replacement, range: range)
    }
    attributed.enumerateAttribute(.foregroundColor, in: fullRange) { _, range, _ in
      if attributed.attribute(.link, at: range.location, effectiveRange: nil) == nil {
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
      }
    }
  }

  static func nsAttributedString(from markdown: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let blocks = HermesMarkdownBlock.parse(markdown)

    for (index, block) in blocks.enumerated() {
      if index > 0 {
        result.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
      }
      result.append(attributedBlock(block))
    }

    if result.length == 0 {
      return NSAttributedString(string: markdown, attributes: baseAttributes)
    }
    return result
  }

  static func plainFormattedString(from markdown: String) -> String {
    let blocks = HermesMarkdownBlock.parse(markdown)
    let rendered = blocks.map { block -> String in
      switch block.kind {
      case .heading(_, let text):
        return stripInlineMarkdown(text)
      case .paragraph(let text):
        return stripInlineMarkdown(text)
      case .unorderedList(let items):
        return items
          .map { "• \(stripInlineMarkdown($0.text))" }
          .joined(separator: "\n")
      case .orderedList(let items):
        return items
          .map { "\($0.marker) \(stripInlineMarkdown($0.text))" }
          .joined(separator: "\n")
      case .code(let text):
        return text
      }
    }
    return rendered
      .joined(separator: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func attributedBlock(_ block: HermesMarkdownBlock) -> NSAttributedString {
    switch block.kind {
    case .heading(let level, let text):
      return inlineAttributedString(
        text,
        fallbackAttributes: headingAttributes(level: level)
      )
    case .paragraph(let text):
      return inlineAttributedString(text, fallbackAttributes: baseAttributes)
    case .unorderedList(let items):
      let result = NSMutableAttributedString()
      for (index, item) in items.enumerated() {
        if index > 0 {
          result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        result.append(NSAttributedString(string: "• ", attributes: baseAttributes))
        result.append(inlineAttributedString(item.text, fallbackAttributes: baseAttributes))
      }
      return result
    case .orderedList(let items):
      let result = NSMutableAttributedString()
      for (index, item) in items.enumerated() {
        if index > 0 {
          result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        result.append(NSAttributedString(string: "\(item.marker) ", attributes: baseAttributes))
        result.append(inlineAttributedString(item.text, fallbackAttributes: baseAttributes))
      }
      return result
    case .code(let text):
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle
      ]
      return NSAttributedString(string: text, attributes: attributes)
    }
  }

  private static func inlineAttributedString(
    _ source: String,
    fallbackAttributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    if let parsed = try? AttributedString(
      markdown: source,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
      )
    ) {
      let attributed = NSMutableAttributedString(parsed)
      let fullRange = NSRange(location: 0, length: attributed.length)
      attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
      attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
      return attributed
    }
    return NSAttributedString(
      string: stripInlineMarkdown(source),
      attributes: fallbackAttributes
    )
  }

  private static func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
    let size = level == 1 ? NSFont.systemFontSize + 4 : NSFont.systemFontSize + 2
    return [
      .font: NSFont.boldSystemFont(ofSize: size),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
  }

  private static var baseAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
  }

  private static var paragraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 3
    style.paragraphSpacing = 0
    return style
  }

  private static func stripInlineMarkdown(_ source: String) -> String {
    var stripped = source
    for token in ["**", "__", "`", "*", "_"] {
      stripped = stripped.replacingOccurrences(of: token, with: "")
    }
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct HermesMarkdownBlock {
  enum Kind {
    case heading(level: Int, String)
    case paragraph(String)
    case unorderedList([HermesMarkdownListItem])
    case orderedList([HermesMarkdownOrderedListItem])
    case code(String)
  }

  let kind: Kind

  static func parse(_ text: String) -> [HermesMarkdownBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var blocks: [HermesMarkdownBlock] = []
    var paragraphLines: [String] = []
    var unorderedItems: [HermesMarkdownListItem] = []
    var orderedItems: [HermesMarkdownOrderedListItem] = []
    var codeLines: [String] = []
    var inCodeBlock = false

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      let paragraph = paragraphLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !paragraph.isEmpty {
        blocks.append(HermesMarkdownBlock(kind: .paragraph(paragraph)))
      }
      paragraphLines.removeAll()
    }

    func flushLists() {
      if !unorderedItems.isEmpty {
        blocks.append(HermesMarkdownBlock(kind: .unorderedList(unorderedItems)))
        unorderedItems.removeAll()
      }
      if !orderedItems.isEmpty {
        blocks.append(HermesMarkdownBlock(kind: .orderedList(orderedItems)))
        orderedItems.removeAll()
      }
    }

    func flushCode() {
      blocks.append(HermesMarkdownBlock(kind: .code(codeLines.joined(separator: "\n"))))
      codeLines.removeAll()
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmed.hasPrefix("```") {
        flushParagraph()
        flushLists()
        if inCodeBlock {
          flushCode()
        }
        inCodeBlock.toggle()
        continue
      }

      if inCodeBlock {
        codeLines.append(line)
        continue
      }

      if trimmed.isEmpty {
        flushParagraph()
        flushLists()
        continue
      }

      if let heading = heading(from: trimmed) {
        flushParagraph()
        flushLists()
        blocks.append(HermesMarkdownBlock(kind: .heading(level: heading.level, heading.text)))
        continue
      }

      if let itemText = unorderedListText(from: trimmed) {
        flushParagraph()
        if !orderedItems.isEmpty { flushLists() }
        unorderedItems.append(HermesMarkdownListItem(text: itemText))
        continue
      }

      if let item = orderedListItem(from: trimmed) {
        flushParagraph()
        if !unorderedItems.isEmpty { flushLists() }
        orderedItems.append(HermesMarkdownOrderedListItem(marker: item.marker, text: item.text))
        continue
      }

      flushLists()
      paragraphLines.append(line)
    }

    if inCodeBlock {
      flushCode()
    }
    flushParagraph()
    flushLists()

    if blocks.isEmpty {
      return [HermesMarkdownBlock(kind: .paragraph(text))]
    }
    return blocks
  }

  private static func heading(from line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard (1...3).contains(hashes),
          line.dropFirst(hashes).first == " " else {
      return nil
    }
    let text = String(line.dropFirst(hashes + 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : (hashes, text)
  }

  private static func unorderedListText(from line: String) -> String? {
    for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  private static func orderedListItem(from line: String) -> (marker: String, text: String)? {
    guard let dotIndex = line.firstIndex(of: ".") else { return nil }
    let number = line[..<dotIndex]
    guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
    let textStart = line.index(after: dotIndex)
    guard textStart < line.endIndex, line[textStart].isWhitespace else { return nil }
    let text = line[textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return ("\(number).", text)
  }
}

private struct HermesMarkdownListItem {
  let text: String
}

private struct HermesMarkdownOrderedListItem {
  let marker: String
  let text: String
}
