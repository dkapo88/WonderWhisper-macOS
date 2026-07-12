import AppKit
import Combine
import SwiftUI

struct HermesResponseWindowState: Equatable, Identifiable {
  let id: UUID
  var title: String
  var text: String
  /// When true, `text` is an HTML fragment (e.g. a Beeper reply) and is rendered
  /// natively rather than as markdown.
  var isHTML: Bool
  var isError: Bool
  var isRecordingReply: Bool
  var supportsReply: Bool
  var supportsVoiceReply: Bool
  var supportsTextReply: Bool

  init(id: UUID = UUID(),
       title: String,
       text: String,
       isHTML: Bool = false,
       isError: Bool = false,
       isRecordingReply: Bool = false,
       supportsReply: Bool = true,
       supportsVoiceReply: Bool? = nil,
       supportsTextReply: Bool? = nil) {
    self.id = id
    self.title = title
    self.text = text
    self.isHTML = isHTML
    self.isError = isError
    self.isRecordingReply = isRecordingReply
    self.supportsReply = supportsReply
    self.supportsVoiceReply = supportsVoiceReply ?? supportsReply
    self.supportsTextReply = supportsTextReply ?? supportsReply
  }
}

enum HermesResponseWindowLifecycle {
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

enum HermesEscapeAction: Equatable {
  case cancelRecording
  case dismissResponseWindow(UUID)
  case ignore
}

enum HermesEscapeResolver {
  static let escapeKeyCode: UInt16 = 53

  /// Decide what an Escape press should do. Recording always wins (and never
  /// dismisses a window); otherwise dismiss the frontmost (topmost z-order)
  /// response window; otherwise do nothing.
  static func resolve(
    isRecording: Bool,
    responseWindowsFrontToBack: [UUID]
  ) -> HermesEscapeAction {
    if isRecording { return .cancelRecording }
    guard let front = responseWindowsFrontToBack.first else { return .ignore }
    return .dismissResponseWindow(front)
  }

  static func shouldConsumeKeyDown(
    keyCode: UInt16,
    isRecording: Bool,
    responseWindowsFrontToBack: [UUID]
  ) -> Bool {
    guard keyCode == escapeKeyCode else { return false }
    return resolve(
      isRecording: isRecording,
      responseWindowsFrontToBack: responseWindowsFrontToBack
    ) != .ignore
  }
}

enum HermesResponseWindowLayout {
  static let defaultContentSize = NSSize(width: 660, height: 540)
  static let minimumContentSize = NSSize(width: 520, height: 360)
  static let bubbleSize = NSSize(width: 60, height: 60)
  static let bubbleSpacing: CGFloat = 12
  static let bubbleEdgeInset: CGFloat = 16
  static let styleMask: NSWindow.StyleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
    .fullSizeContentView
  ]
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
  private var panelFrontToBackOrder: [UUID] = []
  private var textReplyDrafts: [UUID: HermesTextReplyDraft] = [:]
  private var textReplySessionIDs: Set<UUID> = []
  private var minimizedOrder: [UUID] = []
  private var preMinimizeFrames: [UUID: NSRect] = [:]
  private var cancellable: AnyCancellable?
  private var localEscapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var escapeEventTap: HermesEscapeEventTap?

  init(viewModel: DictationViewModel) {
    self.viewModel = viewModel
    super.init()
    cancellable = viewModel.$hermesResponseWindowStates.sink { [weak self] states in
      Task { @MainActor in
        self?.render(states)
      }
    }
    // Local monitor covers events delivered to WonderWhisper. The global
    // monitor covers floating response windows while another app has focus.
    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.keyCode == HermesEscapeResolver.escapeKeyCode else { return event }
      return self.handleEscape() ? nil : event
    }
    let eventTap = HermesEscapeEventTap()
    eventTap.onEscape = { [weak self] in
      self?.handleEscape() ?? false
    }
    if eventTap.start() {
      escapeEventTap = eventTap
      AppLog.hotkeys.log("Hermes response Escape event tap installed")
    } else {
      AppLog.hotkeys.warning(
        "Hermes response Escape event tap unavailable; falling back to global monitor axTrusted=\(AXIsProcessTrusted(), privacy: .public)"
      )
      globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.keyCode == HermesEscapeResolver.escapeKeyCode else { return }
        _ = self.handleEscape()
      }
    }
  }

  deinit {
    if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
    if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
    escapeEventTap?.stop()
  }

  /// Front-to-back z-ordered IDs of visible, non-minimized response panels.
  private func responseWindowsFrontToBack() -> [UUID] {
    var seen = Set<UUID>()
    var orderedIDs: [UUID] = []

    let appKitOrderedIDs = NSApp.orderedWindows.compactMap { window -> UUID? in
      guard let panel = window as? HermesResponsePanel,
            let sessionID = panel.sessionID,
            isDismissibleResponsePanel(panel, sessionID: sessionID) else { return nil }
      return sessionID
    }
    for sessionID in appKitOrderedIDs {
      guard seen.insert(sessionID).inserted else { continue }
      orderedIDs.append(sessionID)
    }

    for sessionID in panelFrontToBackOrder {
      guard seen.insert(sessionID).inserted else { continue }
      guard let panel = panels[sessionID],
            isDismissibleResponsePanel(panel, sessionID: sessionID) else { continue }
      orderedIDs.append(sessionID)
    }

    for state in latestStates.reversed() {
      let sessionID = state.id
      guard seen.insert(sessionID).inserted else { continue }
      guard let panel = panels[sessionID],
            isDismissibleResponsePanel(panel, sessionID: sessionID) else { continue }
      orderedIDs.append(sessionID)
    }

    return orderedIDs
  }

  private func isDismissibleResponsePanel(_ panel: HermesResponsePanel, sessionID: UUID) -> Bool {
    panel.isVisible && !minimizedOrder.contains(sessionID)
  }

  /// Escape priority: cancel an active recording first, else dismiss the
  /// topmost response window, else no-op. Returns true if the press was consumed.
  @discardableResult
  func handleEscape() -> Bool {
    switch HermesEscapeResolver.resolve(
      isRecording: viewModel?.isRecording ?? false,
      responseWindowsFrontToBack: responseWindowsFrontToBack()
    ) {
    case .cancelRecording:
      AppLog.hotkeys.log("Escape cancelling active recording")
      viewModel?.cancel()
      return true
    case .dismissResponseWindow(let sessionID):
      AppLog.hotkeys.log(
        "Escape dismissing response window id=\(sessionID.uuidString, privacy: .public)"
      )
      viewModel?.dismissHermesResponse(sessionID: sessionID)
      return true
    case .ignore:
      AppLog.hotkeys.log(
        "Escape ignored recording=\(self.viewModel?.isRecording ?? false, privacy: .public) visibleResponses=\(self.responseWindowsFrontToBack().count, privacy: .public) panels=\(self.panels.count, privacy: .public) orderedPanels=\(self.panelFrontToBackOrder.count, privacy: .public)"
      )
      return false
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let panel = notification.object as? HermesResponsePanel,
          let sessionID = panel.sessionID else {
      return
    }
    panels[sessionID] = nil
    panelFrontToBackOrder.removeAll { $0 == sessionID }
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

  private var isAligningPanelFrame = false

  /// These borderless, transparent panels render blurry text when their layer
  /// lands on a fractional (non-device-pixel) origin while being dragged. Snap
  /// every move back to a backing-aligned frame so the text stays crisp wherever
  /// it's dropped. The guard prevents the resulting setFrame from recursing.
  func windowDidMove(_ notification: Notification) {
    guard !isAligningPanelFrame,
          let window = notification.object as? HermesResponsePanel else { return }
    let aligned = window.backingAlignedRect(window.frame, options: .alignAllEdgesNearest)
    guard aligned.origin != window.frame.origin else { return }
    isAligningPanelFrame = true
    window.setFrameOrigin(aligned.origin)
    isAligningPanelFrame = false
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
      minimizedOrder.removeAll { $0 == sessionID }
      panelFrontToBackOrder.removeAll { $0 == sessionID }
      preMinimizeFrames[sessionID] = nil
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
    markPanelFront(sessionID)
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
    guard !minimizedOrder.contains(state.id) else {
      panel.contentView = NSHostingView(
        rootView: HermesResponseBubbleView(
          state: state,
          onRestore: { [weak self] in self?.restorePanel(sessionID: state.id) }
        )
      )
      return
    }
    panel.contentView = NSHostingView(
      rootView: HermesResponsePanelView(
        state: state,
        isForeground: isForeground,
        textReplyDraft: textReplyDraft(for: state.id),
        isTextReplyVisible: textReplySessionIDs.contains(state.id),
        onCopyRaw: { HermesResponseClipboard.copyRaw(state.text) },
        onCopyFormatted: { HermesResponseClipboard.copyFormatted(state.text, isHTML: state.isHTML) },
        onReply: { [weak self] in self?.viewModel?.startHermesReply(to: state.id) },
        onToggleTextReply: { [weak self] in self?.toggleTextReply(for: state.id) },
        onSendTextReply: { [weak self] text in
          self?.sendTextReply(text, sessionID: state.id)
        },
        onMinimize: { [weak self] in self?.minimizePanel(sessionID: state.id) },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse(sessionID: state.id) }
      )
    )
  }

  private func minimizePanel(sessionID: UUID) {
    guard let panel = panels[sessionID], !minimizedOrder.contains(sessionID) else { return }
    preMinimizeFrames[sessionID] = panel.frame
    minimizedOrder.append(sessionID)
    panel.contentMinSize = HermesResponseWindowLayout.bubbleSize
    if let state = latestStates.first(where: { $0.id == sessionID }) {
      render(state, in: panel, isForeground: false)
    }
    panel.setContentSize(HermesResponseWindowLayout.bubbleSize)
    layoutBubbles()
    panel.orderFront(nil)
  }

  private func restorePanel(sessionID: UUID) {
    guard let panel = panels[sessionID], minimizedOrder.contains(sessionID) else { return }
    minimizedOrder.removeAll { $0 == sessionID }
    panel.contentMinSize = HermesResponseWindowLayout.minimumContentSize
    if let state = latestStates.first(where: { $0.id == sessionID }) {
      render(state, in: panel, isForeground: true)
    }
    if let frame = preMinimizeFrames[sessionID] {
      preMinimizeFrames[sessionID] = nil
      panel.setFrame(frame, display: true)
    } else {
      panel.setContentSize(HermesResponseWindowLayout.defaultContentSize)
      position(panel)
    }
    layoutBubbles()
    present(panel, shouldPosition: false)
  }

  private func markPanelFront(_ sessionID: UUID?) {
    guard let sessionID else { return }
    panelFrontToBackOrder.removeAll { $0 == sessionID }
    panelFrontToBackOrder.insert(sessionID, at: 0)
  }

  // Stack minimized bubbles down the top-right edge of the active screen.
  private func layoutBubbles() {
    let screenFrame = targetScreenFrame()
    let size = HermesResponseWindowLayout.bubbleSize
    for (index, sessionID) in minimizedOrder.enumerated() {
      guard let panel = panels[sessionID] else { continue }
      let x = screenFrame.maxX - size.width - HermesResponseWindowLayout.bubbleEdgeInset
      let y = screenFrame.maxY - size.height - HermesResponseWindowLayout.bubbleEdgeInset
              - CGFloat(index) * (size.height + HermesResponseWindowLayout.bubbleSpacing)
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
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
    viewModel?.sendResponseWindowTextReply(trimmed, sessionID: sessionID)
  }

  private func makePanel(sessionID: UUID) -> HermesResponsePanel {
    let panel = HermesResponsePanel(
      contentRect: NSRect(origin: .zero, size: HermesResponseWindowLayout.defaultContentSize),
      styleMask: HermesResponseWindowLayout.styleMask,
      backing: .buffered,
      defer: false
    )
    panel.sessionID = sessionID
    panel.onEscape = { [weak self] in
      self?.handleEscape() ?? false
    }
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
    markPanelFront(panel.sessionID)
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
    // Align to device pixels so text is crisp from first paint (midX can be fractional).
    let aligned = panel.backingAlignedRect(
      NSRect(origin: origin, size: frame.size), options: .alignAllEdgesNearest
    )
    panel.setFrameOrigin(aligned.origin)
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
  var onEscape: (() -> Bool)?
  var onFocusRequested: ((UUID) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == HermesEscapeResolver.escapeKeyCode, onEscape?() == true {
      return
    }
    super.keyDown(with: event)
  }

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

private final class HermesEscapeEventTap {
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  var onEscape: (() -> Bool)?

  deinit {
    stop()
  }

  func start() -> Bool {
    guard AXIsProcessTrusted() else { return false }

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let interceptor = Unmanaged<HermesEscapeEventTap>
        .fromOpaque(refcon)
        .takeUnretainedValue()

      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = interceptor.eventTap {
          CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
      }

      guard type == .keyDown else { return Unmanaged.passUnretained(event) }
      let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      guard keyCode == HermesEscapeResolver.escapeKeyCode else {
        return Unmanaged.passUnretained(event)
      }

      return interceptor.onEscape?() == true ? nil : Unmanaged.passUnretained(event)
    }

    let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: callback,
      userInfo: refcon
    ) else {
      return false
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return false
    }

    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func stop() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    eventTap = nil
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
    }
    runLoopSource = nil
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
        HermesMarkdownView(text: state.text, isHTML: state.isHTML)
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

        if state.supportsVoiceReply {
          Button(action: onReply) {
            Label(
              state.isRecordingReply ? "Send" : "Voice Reply",
              systemImage: state.isRecordingReply ? "paperplane.fill" : "mic.fill"
            )
          }
          .disabled(state.isError && !state.isRecordingReply)
        }

        if state.supportsTextReply {
          Button(action: onToggleTextReply) {
            Label(
              isTextReplyVisible ? "Hide Text" : "Text Reply",
              systemImage: isTextReplyVisible ? "text.bubble.fill" : "text.bubble"
            )
          }
          .disabled(state.isError || state.isRecordingReply)
        }

        Button(action: onMinimize) {
          Label("Minimize", systemImage: "minus.circle")
        }
        .keyboardShortcut("m", modifiers: [.command])

        Button(action: onClose) {
          Label("Close", systemImage: "xmark.circle.fill")
        }
        // Escape is handled centrally in HermesResponsePanel.keyDown so it
        // targets the topmost window and yields to active recordings.
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
      HermesReplyTextView(
        text: $textReplyDraft.text,
        shouldFocus: true,
        onSubmit: {
          onSendTextReply(textReplyDraft.text)
        }
      )
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
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }
}

private struct HermesResponseBubbleView: View {
  var state: HermesResponseWindowState
  var onRestore: () -> Void

  var body: some View {
    Button(action: onRestore) {
      ZStack {
        Circle().fill(.regularMaterial)
        Circle().stroke((state.isError ? Color.red : Color.accentColor).opacity(0.55), lineWidth: 2)
        Image(systemName: state.isError ? "exclamationmark.triangle.fill" : "waveform.and.sparkles")
          .font(.title3)
          .foregroundStyle(state.isError ? .red : .blue)
      }
    }
    .buttonStyle(.plain)
    .frame(
      width: HermesResponseWindowLayout.bubbleSize.width,
      height: HermesResponseWindowLayout.bubbleSize.height
    )
    .help(state.title)
  }
}

private struct HermesReplyTextView: NSViewRepresentable {
  @Binding var text: String
  var shouldFocus: Bool
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textView = ReplyNSTextView()
    textView.delegate = context.coordinator
    textView.onSubmit = onSubmit
    textView.string = text
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 2, height: 4)
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ReplyNSTextView else { return }
    context.coordinator.text = $text
    textView.onSubmit = onSubmit
    if textView.string != text {
      textView.string = text
    }
    guard shouldFocus else { return }
    DispatchQueue.main.async {
      guard let window = textView.window else { return }
      window.makeFirstResponder(textView)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    weak var textView: NSTextView?

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }

  final class ReplyNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
      if event.isReturnKey {
        if event.textReplyModifierFlags.contains(.shift) {
          super.keyDown(with: event)
          return
        }
        if event.textReplyModifierFlags.isEmpty {
          onSubmit?()
          return
        }
      }
      super.keyDown(with: event)
    }
  }
}

private extension NSEvent {
  var textReplyModifierFlags: NSEvent.ModifierFlags {
    modifierFlags.intersection([.shift, .control, .option, .command])
  }

  var isReturnKey: Bool {
    keyCode == 36 || keyCode == 76 || charactersIgnoringModifiers == "\r"
  }
}
