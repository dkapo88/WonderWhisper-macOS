import SwiftUI

struct HermesMarkdownView: View {
  var text: String

  private var renderedBlocks: [HermesMarkdownBlock] {
    HermesMarkdownBlock.parse(text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(renderedBlocks) { block in
        blockView(block)
      }
    }
  }

  @ViewBuilder
  private func blockView(_ block: HermesMarkdownBlock) -> some View {
    switch block.kind {
    case .heading(let level, let text):
      Text(text)
        .font(level == 1 ? .title3.weight(.semibold) : .headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, level == 1 ? 2 : 0)
    case .paragraph(let text):
      Text(text)
        .font(.body)
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(items) { item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
              .font(.body)
              .frame(width: 14, alignment: .trailing)
            Text(item.text)
              .font(.body)
              .lineSpacing(3)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(items) { item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.marker)
              .font(.body)
              .monospacedDigit()
              .frame(width: 28, alignment: .trailing)
            Text(item.text)
              .font(.body)
              .lineSpacing(3)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    case .code(let text):
      Text(text)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
        )
    }
  }
}

private struct HermesMarkdownBlock: Identifiable {
  enum Kind {
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case unorderedList([HermesMarkdownListItem])
    case orderedList([HermesMarkdownOrderedListItem])
    case code(String)
  }

  let id = UUID()
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
        blocks.append(HermesMarkdownBlock(kind: .paragraph(inlineMarkdown(paragraph))))
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
        blocks.append(HermesMarkdownBlock(
          kind: .heading(level: heading.level, inlineMarkdown(heading.text))
        ))
        continue
      }

      if let itemText = unorderedListText(from: trimmed) {
        flushParagraph()
        if !orderedItems.isEmpty { flushLists() }
        unorderedItems.append(HermesMarkdownListItem(text: inlineMarkdown(itemText)))
        continue
      }

      if let item = orderedListItem(from: trimmed) {
        flushParagraph()
        if !unorderedItems.isEmpty { flushLists() }
        orderedItems.append(HermesMarkdownOrderedListItem(
          marker: item.marker,
          text: inlineMarkdown(item.text)
        ))
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
      return [HermesMarkdownBlock(kind: .paragraph(inlineMarkdown(text)))]
    }
    return blocks
  }

  private static func inlineMarkdown(_ source: String) -> AttributedString {
    (try? AttributedString(markdown: source)) ?? AttributedString(source)
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

private struct HermesMarkdownListItem: Identifiable {
  let id = UUID()
  let text: AttributedString
}

private struct HermesMarkdownOrderedListItem: Identifiable {
  let id = UUID()
  let marker: String
  let text: AttributedString
}
