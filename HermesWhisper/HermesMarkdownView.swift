import AppKit
import SwiftUI

struct HermesMarkdownView: View {
  var text: String
  /// When true, `text` is an HTML fragment and is rendered through AppKit's text
  /// engine (NSTextView) so block-level structure — tables, headings, lists —
  /// survives. SwiftUI `Text` only honors inline attributes and flattens those.
  var isHTML: Bool = false

  var body: some View {
    if isHTML, let html = HermesMarkdownContent.htmlAttributedString(from: text) {
      HermesAttributedTextView(attributed: html)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(HermesMarkdownContent.attributedString(from: text))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Read-only, selectable NSTextView host that sizes its height to the content at
/// the proposed width. Used for HTML replies whose tables/lists/headings need the
/// full text engine (SwiftUI `Text` can't lay those out).
struct HermesAttributedTextView: NSViewRepresentable {
  let attributed: NSAttributedString

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    textView.textStorage?.setAttributedString(attributed)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
    let width = proposal.width ?? 480
    guard let container = textView.textContainer, let manager = textView.layoutManager else {
      return nil
    }
    if textView.textStorage?.length != attributed.length {
      textView.textStorage?.setAttributedString(attributed)
    }
    textView.frame.size.width = width
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return CGSize(width: width, height: ceil(used.height))
  }
}

enum HermesMarkdownContent {
  /// Base body point size for response-window content. Configurable in settings;
  /// headings, code, and imported HTML all scale relative to this. Seeded from
  /// UserDefaults and kept in sync by DictationViewModel.responseWindowFontSize.
  static var baseFontSize: CGFloat = {
    let stored = UserDefaults.standard.object(forKey: AppConfig.responseWindowFontSizeKey) as? Double
    return stored.map { CGFloat($0) } ?? NSFont.systemFontSize
  }()

  static func attributedString(from markdown: String) -> AttributedString {
    AttributedString(nsAttributedString(from: markdown))
  }

  /// System font at `size` carrying the given bold/italic/monospace traits.
  static func styledSystemFont(ofSize size: CGFloat,
                               traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
    if traits.contains(.monoSpace) {
      return .monospacedSystemFont(ofSize: size, weight: traits.contains(.bold) ? .bold : .regular)
    }
    var font = NSFont.systemFont(ofSize: size)
    if traits.contains(.bold) {
      font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    if traits.contains(.italic) {
      font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    return font
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

  /// The HTML importer uses Times/Helvetica and hard-coded black text. Remap each
  /// run to the system font (preserving bold/italic/monospace traits) and set
  /// `labelColor` so it matches the app and works in dark mode. Links keep their
  /// own color. Sizes are scaled so the dominant (body) size becomes the app's
  /// system size, which keeps headings proportionally larger.
  // ponytail: assumes the most common run size is body text; true for chat HTML.
  private static func normalizeImportedHTML(_ attributed: NSMutableAttributedString) {
    let fullRange = NSRange(location: 0, length: attributed.length)

    // Find the body size = the point size covering the most characters.
    var lengthBySize: [CGFloat: Int] = [:]
    attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
      guard let font = value as? NSFont else { return }
      lengthBySize[font.pointSize, default: 0] += range.length
    }
    let bodySize = lengthBySize.max { $0.value < $1.value }?.key ?? 12
    let scale = min(max(baseFontSize / bodySize, 0.8), 3.0)

    attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
      guard let font = value as? NSFont else { return }
      let size = (font.pointSize * scale).rounded()
      attributed.addAttribute(
        .font,
        value: styledSystemFont(ofSize: size, traits: font.fontDescriptor.symbolicTraits),
        range: range
      )
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
        .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular),
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
      // Resize inline runs to the configured base size, keeping bold/italic/code traits.
      attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
        let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        attributed.addAttribute(
          .font, value: styledSystemFont(ofSize: baseFontSize, traits: traits), range: range
        )
      }
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
    let size = level == 1 ? baseFontSize + 4 : baseFontSize + 2
    return [
      .font: NSFont.boldSystemFont(ofSize: size),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]
  }

  private static var baseAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: baseFontSize),
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
