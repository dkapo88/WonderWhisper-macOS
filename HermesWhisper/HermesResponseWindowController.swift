import AppKit
import Combine
import SwiftUI

struct HermesResponseWindowState: Equatable, Identifiable {
  let id: UUID
  var title: String
  var text: String
  var isError: Bool
  var isRecordingReply: Bool

  init(id: UUID = UUID(),
       title: String,
       text: String,
       isError: Bool = false,
       isRecordingReply: Bool = false) {
    self.id = id
    self.title = title
    self.text = text
    self.isError = isError
    self.isRecordingReply = isRecordingReply
  }
}

enum HermesResponseWindowLifecycle {
  static func replyRecordingStarted(
    _ state: HermesResponseWindowState?
  ) -> HermesResponseWindowState? {
    guard var state else { return nil }
    state.isRecordingReply = true
    return state
  }

  static func replyRecordingFinished(
    _ state: HermesResponseWindowState?
  ) -> HermesResponseWindowState? {
    nil
  }

  static func replyRecordingCancelled(
    _ state: HermesResponseWindowState?
  ) -> HermesResponseWindowState? {
    guard var state else { return nil }
    state.isRecordingReply = false
    return state
  }

  static func replyRecordingStarted(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var recordingState = state
      recordingState.isRecordingReply = true
      return recordingState
    }
  }

  static func replyRecordingFinished(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.filter { $0.id != sessionID }
  }

  static func replyRecordingCancelled(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var cancelledState = state
      cancelledState.isRecordingReply = false
      return cancelledState
    }
  }
}

enum HermesResponseWindowLayout {
  static let defaultContentSize = NSSize(width: 660, height: 540)
  static let minimumContentSize = NSSize(width: 520, height: 360)
  static let styleMask: NSWindow.StyleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
    .fullSizeContentView
  ]
}

protocol HermesResponseWindowControlling: AnyObject {
  func orderOut(_ sender: Any?)
  func miniaturize(_ sender: Any?)
}

extension NSWindow: HermesResponseWindowControlling {}

enum HermesResponseWindowControls {
  static func minimize(_ window: HermesResponseWindowControlling?) {
    window?.orderOut(nil)
  }
}

@MainActor
private final class HermesTextReplyDraft: ObservableObject {
  @Published var text: String = ""
}

@MainActor
final class HermesResponseWindowController: NSObject, NSWindowDelegate {
  private weak var viewModel: DictationViewModel?
  private var panels: [UUID: HermesResponsePanel] = [:]
  private var latestStates: [HermesResponseWindowState] = []
  private var focusedSessionID: UUID?
  private var textReplyDrafts: [UUID: HermesTextReplyDraft] = [:]
  private var textReplySessionIDs: Set<UUID> = []
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
    focusPanel(sessionID: sessionID, syncSelection: true)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard notification.object is HermesResponsePanel else { return }
    refreshPanelFocus()
  }

  private func render(_ states: [HermesResponseWindowState]) {
    latestStates = states
    let activeIDs = Set(states.map(\.id))
    for sessionID in Array(panels.keys) where !activeIDs.contains(sessionID) {
      panels[sessionID]?.orderOut(nil)
      panels[sessionID]?.delegate = nil
      panels[sessionID] = nil
      textReplyDrafts[sessionID] = nil
      textReplySessionIDs.remove(sessionID)
    }

    for state in states {
      let isNewPanel = panels[state.id] == nil
      let panel = panels[state.id] ?? makePanel(sessionID: state.id)
      let shouldPresent = isNewPanel || !panel.isVisible
      render(
        state,
        in: panel,
        isForeground: focusedSessionID == state.id || panel.isKeyWindow
      )
      panels[state.id] = panel
      if shouldPresent {
        present(panel, shouldPosition: true)
      }
    }
  }

  private func refreshPanelFocus() {
    for state in latestStates {
      guard let panel = panels[state.id] else { continue }
      render(
        state,
        in: panel,
        isForeground: focusedSessionID == state.id || panel.isKeyWindow
      )
    }
  }

  private func focusPanel(sessionID: UUID, syncSelection: Bool) {
    let didChangeFocus = focusedSessionID != sessionID
    focusedSessionID = sessionID
    if didChangeFocus {
      refreshPanelFocus()
    }
    if syncSelection {
      viewModel?.activateHermesSession(sessionID)
    }
  }

  private func render(_ state: HermesResponseWindowState,
                      in panel: HermesResponsePanel,
                      isForeground: Bool) {
    panel.title = state.title
    panel.contentView = NSHostingView(
      rootView: HermesResponsePanelView(
        state: state,
        isForeground: isForeground,
        textReplyDraft: textReplyDraft(for: state.id),
        isTextReplyVisible: textReplySessionIDs.contains(state.id),
        onCopyRaw: { HermesResponseClipboard.copyRaw(state.text) },
        onCopyFormatted: { HermesResponseClipboard.copyFormatted(state.text) },
        onReply: { [weak self] in self?.viewModel?.startHermesReply(to: state.id) },
        onToggleTextReply: { [weak self] in self?.toggleTextReply(for: state.id) },
        onSendTextReply: { [weak self] text in
          self?.sendTextReply(text, sessionID: state.id)
        },
        onMinimize: { [weak panel] in HermesResponseWindowControls.minimize(panel) },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse(sessionID: state.id) }
      )
    )
  }

  private func textReplyDraft(for sessionID: UUID) -> HermesTextReplyDraft {
    if let draft = textReplyDrafts[sessionID] {
      return draft
    }
    let draft = HermesTextReplyDraft()
    textReplyDrafts[sessionID] = draft
    return draft
  }

  private func toggleTextReply(for sessionID: UUID) {
    if textReplySessionIDs.contains(sessionID) {
      textReplySessionIDs.remove(sessionID)
    } else {
      textReplySessionIDs.insert(sessionID)
    }
    render(latestStates)
  }

  private func sendTextReply(_ text: String, sessionID: UUID) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    textReplyDrafts[sessionID]?.text = ""
    textReplyDrafts[sessionID] = nil
    textReplySessionIDs.remove(sessionID)
    viewModel?.sendHermesTextReply(trimmed, to: sessionID, dismissResponseWindow: true)
  }

  private func makePanel(sessionID: UUID) -> HermesResponsePanel {
    let panel = HermesResponsePanel(
      contentRect: NSRect(origin: .zero, size: HermesResponseWindowLayout.defaultContentSize),
      styleMask: HermesResponseWindowLayout.styleMask,
      backing: .buffered,
      defer: false
    )
    panel.sessionID = sessionID
    panel.onFocusRequested = { [weak self] sessionID in
      Task { @MainActor [weak self] in
        self?.focusPanel(sessionID: sessionID, syncSelection: false)
      }
    }
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
    panel.contentMinSize = HermesResponseWindowLayout.minimumContentSize
    panel.delegate = self
    hideTrafficLights(in: panel)
    return panel
  }

  private func hideTrafficLights(in panel: NSPanel) {
    [
      NSWindow.ButtonType.closeButton,
      .miniaturizeButton,
      .zoomButton
    ].forEach { buttonType in
      let button = panel.standardWindowButton(buttonType)
      button?.isHidden = true
      button?.isEnabled = false
    }
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
    focusedSessionID = panel.sessionID
    refreshPanelFocus()

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
  var onFocusRequested: ((UUID) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      if let sessionID {
        onFocusRequested?(sessionID)
      }
    default:
      break
    }
    super.sendEvent(event)
  }
}

private struct HermesResponsePanelView: View {
  var state: HermesResponseWindowState
  var isForeground: Bool
  @ObservedObject var textReplyDraft: HermesTextReplyDraft
  var isTextReplyVisible: Bool
  var onCopyRaw: () -> Void
  var onCopyFormatted: () -> Void
  var onReply: () -> Void
  var onToggleTextReply: () -> Void
  var onSendTextReply: (String) -> Void
  var onMinimize: () -> Void
  var onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      if state.isRecordingReply {
        recordingIndicator
      }

      ScrollView {
        HermesMarkdownView(text: state.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, 4)
      }
      .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
      .layoutPriority(1)

      if isTextReplyVisible {
        textReplyComposer
      }

      HStack(spacing: 10) {
        Spacer()
        Button(action: onCopyRaw) {
          Label("Copy Raw", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Button(action: onCopyFormatted) {
          Label("Copy Formatted", systemImage: "doc.richtext")
        }

        Button(action: onReply) {
          Label(
            state.isRecordingReply ? "Send" : "Voice Reply",
            systemImage: state.isRecordingReply ? "paperplane.fill" : "mic.fill"
          )
        }
        .disabled(state.isError && !state.isRecordingReply)

        Button(action: onToggleTextReply) {
          Label(
            isTextReplyVisible ? "Hide Text" : "Text Reply",
            systemImage: isTextReplyVisible ? "text.bubble.fill" : "text.bubble"
          )
        }
        .disabled(state.isError || state.isRecordingReply)

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
    .frame(
      minWidth: HermesResponseWindowLayout.minimumContentSize.width,
      idealWidth: HermesResponseWindowLayout.defaultContentSize.width,
      maxWidth: .infinity,
      minHeight: HermesResponseWindowLayout.minimumContentSize.height,
      idealHeight: HermesResponseWindowLayout.defaultContentSize.height,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .background(
      (isForeground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.92))),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      if !isForeground {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.black.opacity(0.08))
          .allowsHitTesting(false)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isForeground ? Color.accentColor.opacity(0.58) : Color.secondary.opacity(0.18), lineWidth: isForeground ? 2 : 1)
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

  private var recordingIndicator: some View {
    Label("Recording reply for this window", systemImage: "mic.fill")
      .font(.caption.weight(.semibold))
      .foregroundColor(.accentColor)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        Capsule(style: .continuous)
          .fill(Color.accentColor.opacity(0.14))
      )
  }

  private var textReplyComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $textReplyDraft.text)
        .font(.body)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 72, idealHeight: 90, maxHeight: 130)
        .padding(6)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.18))
        )

      HStack(spacing: 8) {
        Text("Type a reply to this Hermes session.")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button {
          textReplyDraft.text = ""
          onToggleTextReply()
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }
        .buttonStyle(.borderless)

        Button {
          onSendTextReply(textReplyDraft.text)
        } label: {
          Label("Send Text", systemImage: "paperplane.fill")
        }
        .disabled(textReplyDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }
}
