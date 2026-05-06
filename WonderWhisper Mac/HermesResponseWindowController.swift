import AppKit
import Combine
import SwiftUI

struct HermesResponseWindowState: Equatable, Identifiable {
  let id: UUID
  var title: String
  var text: String
  var isError: Bool

  init(id: UUID = UUID(), title: String, text: String, isError: Bool = false) {
    self.id = id
    self.title = title
    self.text = text
    self.isError = isError
  }
}

@MainActor
final class HermesResponseWindowController: NSObject, NSWindowDelegate {
  private weak var viewModel: DictationViewModel?
  private var panel: NSPanel?
  private var cancellable: AnyCancellable?

  init(viewModel: DictationViewModel) {
    self.viewModel = viewModel
    super.init()
    cancellable = viewModel.$hermesResponseWindowState.sink { [weak self] state in
      Task { @MainActor in
        self?.render(state)
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    viewModel?.dismissHermesResponse()
  }

  private func render(_ state: HermesResponseWindowState?) {
    guard let state else {
      hide()
      return
    }

    let panel = panel ?? makePanel()
    panel.contentView = NSHostingView(
      rootView: HermesResponsePanelView(
        state: state,
        onReply: { [weak self] in self?.viewModel?.startHermesReply() },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse() }
      )
    )
    position(panel)
    panel.orderFrontRegardless()
    self.panel = panel
  }

  private func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Hermes"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.delegate = self
    return panel
  }

  private func position(_ panel: NSPanel) {
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = panel.frame
    let origin = NSPoint(
      x: screenFrame.midX - frame.width / 2,
      y: screenFrame.midY - frame.height / 2
    )
    panel.setFrameOrigin(origin)
  }
}

private struct HermesResponsePanelView: View {
  var state: HermesResponseWindowState
  var onReply: () -> Void
  var onClose: () -> Void

  private var renderedBlocks: [HermesResponseBlock] {
    HermesResponseBlock.parse(state.text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(renderedBlocks) { block in
            blockView(block)
          }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
      }
      .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 260)

      HStack(spacing: 10) {
        Spacer()
        Button(action: onReply) {
          Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
        }
        .disabled(state.isError)
        .keyboardShortcut(.return, modifiers: [.command])

        Button(action: onClose) {
          Label("Close", systemImage: "xmark.circle.fill")
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(18)
    .frame(width: 560, height: 390)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: state.isError ? "exclamationmark.triangle.fill" : "waveform.and.sparkles")
        .font(.title3)
        .foregroundStyle(state.isError ? .red : .blue)
        .frame(width: 26, height: 26)

      Text(state.title)
        .font(.headline)
        .lineLimit(1)

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
    }
  }

  @ViewBuilder
  private func blockView(_ block: HermesResponseBlock) -> some View {
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

private struct HermesResponseBlock: Identifiable {
  enum Kind {
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case unorderedList([HermesListItem])
    case orderedList([HermesOrderedListItem])
    case code(String)
  }

  let id = UUID()
  let kind: Kind

  static func parse(_ text: String) -> [HermesResponseBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var blocks: [HermesResponseBlock] = []
    var paragraphLines: [String] = []
    var unorderedItems: [HermesListItem] = []
    var orderedItems: [HermesOrderedListItem] = []
    var codeLines: [String] = []
    var inCodeBlock = false

    func flushParagraph() {
      guard !paragraphLines.isEmpty else { return }
      let paragraph = paragraphLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !paragraph.isEmpty {
        blocks.append(HermesResponseBlock(kind: .paragraph(inlineMarkdown(paragraph))))
      }
      paragraphLines.removeAll()
    }

    func flushLists() {
      if !unorderedItems.isEmpty {
        blocks.append(HermesResponseBlock(kind: .unorderedList(unorderedItems)))
        unorderedItems.removeAll()
      }
      if !orderedItems.isEmpty {
        blocks.append(HermesResponseBlock(kind: .orderedList(orderedItems)))
        orderedItems.removeAll()
      }
    }

    func flushCode() {
      blocks.append(HermesResponseBlock(kind: .code(codeLines.joined(separator: "\n"))))
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
        blocks.append(HermesResponseBlock(
          kind: .heading(level: heading.level, inlineMarkdown(heading.text))
        ))
        continue
      }

      if let itemText = unorderedListText(from: trimmed) {
        flushParagraph()
        if !orderedItems.isEmpty { flushLists() }
        unorderedItems.append(HermesListItem(text: inlineMarkdown(itemText)))
        continue
      }

      if let item = orderedListItem(from: trimmed) {
        flushParagraph()
        if !unorderedItems.isEmpty { flushLists() }
        orderedItems.append(HermesOrderedListItem(
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
      return [HermesResponseBlock(kind: .paragraph(inlineMarkdown(text)))]
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

private struct HermesListItem: Identifiable {
  let id = UUID()
  let text: AttributedString
}

private struct HermesOrderedListItem: Identifiable {
  let id = UUID()
  let marker: String
  let text: AttributedString
}
