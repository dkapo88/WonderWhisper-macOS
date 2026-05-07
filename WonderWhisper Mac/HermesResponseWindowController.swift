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

enum HermesResponseWindowLifecycle {
  static func replyRecordingStarted(
    _ state: HermesResponseWindowState?
  ) -> HermesResponseWindowState? {
    state
  }

  static func replyRecordingFinished(
    _ state: HermesResponseWindowState?
  ) -> HermesResponseWindowState? {
    nil
  }

  static func replyRecordingStarted(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states
  }

  static func replyRecordingFinished(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.filter { $0.id != sessionID }
  }
}

@MainActor
final class HermesResponseWindowController: NSObject, NSWindowDelegate {
  private weak var viewModel: DictationViewModel?
  private var panels: [UUID: HermesResponsePanel] = [:]
  private var cancellable: AnyCancellable?

  init(viewModel: DictationViewModel) {
    self.viewModel = viewModel
    super.init()
    cancellable = viewModel.$hermesResponseWindowStates.sink { [weak self] states in
      Task { @MainActor in
        self?.render(states)
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let panel = notification.object as? HermesResponsePanel,
          let sessionID = panel.sessionID else {
      return
    }
    panels[sessionID] = nil
    viewModel?.dismissHermesResponse(sessionID: sessionID)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let panel = notification.object as? HermesResponsePanel,
          let sessionID = panel.sessionID else {
      return
    }
    viewModel?.activateHermesSession(sessionID)
  }

  private func render(_ states: [HermesResponseWindowState]) {
    let activeIDs = Set(states.map(\.id))
    for sessionID in Array(panels.keys) where !activeIDs.contains(sessionID) {
      panels[sessionID]?.orderOut(nil)
      panels[sessionID]?.delegate = nil
      panels[sessionID] = nil
    }

    for state in states {
      let isNewPanel = panels[state.id] == nil
      let panel = panels[state.id] ?? makePanel(sessionID: state.id)
      render(state, in: panel)
      present(panel, shouldPosition: isNewPanel || !panel.isVisible)
      panels[state.id] = panel
    }
  }

  private func render(_ state: HermesResponseWindowState, in panel: HermesResponsePanel) {
    panel.contentView = NSHostingView(
      rootView: HermesResponsePanelView(
        state: state,
        onCopy: { HermesResponseClipboard.copy(state.text) },
        onReply: { [weak self] in self?.viewModel?.startHermesReply(to: state.id) },
        onMinimize: { [weak panel] in panel?.miniaturize(nil) },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse(sessionID: state.id) }
      )
    )
  }

  private func makePanel(sessionID: UUID) -> HermesResponsePanel {
    let panel = HermesResponsePanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.sessionID = sessionID
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

  private func present(_ panel: HermesResponsePanel, shouldPosition: Bool) {
    let appWasHidden = NSApp.isHidden
    if appWasHidden {
      NSApp.unhideWithoutActivation()
    }

    if shouldPosition {
      position(panel)
    }
    panel.orderFrontRegardless()
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)

    if appWasHidden {
      hideMainAppWindows()
    }
  }

  private func hideMainAppWindows() {
    for window in NSApp.windows {
      if window is HermesResponsePanel { continue }
      guard window.isVisible, window.canBecomeMain || window.isMainWindow else { continue }
      window.orderOut(nil)
    }
  }

  private func position(_ panel: NSPanel) {
    let screenFrame = targetScreenFrame()
    let frame = panel.frame
    let cascadeOffset = CGFloat(min(panels.count, 5) * 26)
    let origin = NSPoint(
      x: screenFrame.midX - frame.width / 2 + cascadeOffset,
      y: screenFrame.midY - frame.height / 2 - cascadeOffset
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
  var sessionID: UUID?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private struct HermesResponsePanelView: View {
  var state: HermesResponseWindowState
  var onCopy: () -> Void
  var onReply: () -> Void
  var onMinimize: () -> Void
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

        Button(action: onMinimize) {
          Label("Minimize", systemImage: "minus.circle")
        }
        .keyboardShortcut("m", modifiers: [.command])

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

      Button(action: onMinimize) {
        Image(systemName: "minus")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .help("Minimize")

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .help("Close")
    }
  }
}
