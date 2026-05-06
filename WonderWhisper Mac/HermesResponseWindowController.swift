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
  private var panel: HermesResponsePanel?
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
        onCopy: { HermesResponseClipboard.copy(state.text) },
        onReply: { [weak self] in self?.viewModel?.startHermesReply() },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse() }
      )
    )
    present(panel)
    self.panel = panel
  }

  private func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> HermesResponsePanel {
    let panel = HermesResponsePanel(
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
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle
    ]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.delegate = self
    return panel
  }

  private func present(_ panel: HermesResponsePanel) {
    let appWasHidden = NSApp.isHidden
    if appWasHidden {
      NSApp.unhideWithoutActivation()
    }

    position(panel)
    panel.orderFrontRegardless()
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)

    if appWasHidden {
      hideMainAppWindows(except: panel)
    }
  }

  private func hideMainAppWindows(except responsePanel: HermesResponsePanel) {
    for window in NSApp.windows where window !== responsePanel {
      guard window.isVisible, window.canBecomeMain || window.isMainWindow else { continue }
      window.orderOut(nil)
    }
  }

  private func position(_ panel: NSPanel) {
    let screenFrame = targetScreenFrame()
    let frame = panel.frame
    let origin = NSPoint(
      x: screenFrame.midX - frame.width / 2,
      y: screenFrame.midY - frame.height / 2
    )
    panel.setFrameOrigin(origin)
  }

  private func targetScreenFrame() -> NSRect {
    let pointer = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
      return screen.visibleFrame
    }
    return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }
}

private final class HermesResponsePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private struct HermesResponsePanelView: View {
  var state: HermesResponseWindowState
  var onCopy: () -> Void
  var onReply: () -> Void
  var onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      ScrollView {
        HermesMarkdownView(text: state.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
      }
      .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 260)

      HStack(spacing: 10) {
        Spacer()
        Button(action: onCopy) {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

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
}
