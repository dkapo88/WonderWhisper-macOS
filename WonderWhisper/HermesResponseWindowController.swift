import AppKit
import Combine
import SwiftUI

enum HermesResponseSource: CaseIterable, Equatable, Hashable {
  case beeper
  case hermes
  case codex

  var label: String {
    switch self {
    case .beeper: "Beeper"
    case .hermes: "Hermes"
    case .codex: "Codex"
    }
  }

  var symbolName: String {
    switch self {
    case .beeper: "bubble.left.and.bubble.right.fill"
    case .hermes: "waveform"
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }

  var tint: Color {
    switch self {
    case .beeper: .blue
    case .hermes: .purple
    case .codex: .green
    }
  }
}

enum HermesResponsePillStatus: Equatable {
  case normal
  case error
  case recording
  case sending

  var symbolName: String? {
    switch self {
    case .normal: nil
    case .error: "exclamationmark.triangle.fill"
    case .recording: "mic.fill"
    case .sending: "paperplane.fill"
    }
  }
}

struct HermesResponseWindowState: Equatable, Identifiable {
  let id: UUID
  let source: HermesResponseSource
  var title: String
  var text: String
  /// When true, `text` is an HTML fragment (e.g. a Beeper reply) and is rendered
  /// natively rather than as markdown.
  var isHTML: Bool
  /// `isError` means *this panel* failed. A failed outbound reply is a different fact — the panel
  /// and the message on it are fine — so it stays `false` throughout a reply failure. Two facts,
  /// two flags: `isError` gates the red header glyph and disables both reply controls, which
  /// would announce the failure and remove the only control that gets the text back.
  var isError: Bool
  var isRecordingReply: Bool
  var supportsReply: Bool
  var supportsVoiceReply: Bool
  var supportsTextReply: Bool
  var beeperChatID: String?
  /// nil = nothing failed. Fixed copy naming the cause, never an interpolated error description.
  var replyFailure: String?
  /// Sibling of `isRecordingReply`: transient, per window. Only ever true on a Beeper panel,
  /// because Beeper is the one branch of `sendResponseWindowTextReply` that spawns its Task with
  /// the panel still alive.
  var isSendingReply: Bool
  /// Set only on a re-presented state, and seeds a fresh draft once at panel creation.
  var preservedReplyText: String?
  /// Held messages older than the displayed body. Beeper only; 0 everywhere else.
  var earlierCount: Int
  /// Held messages newer than the displayed body. Beeper only; 0 everywhere else.
  var newerCount: Int
  /// Why this panel is on screen. Drives the `Snooze ended · ` prefix, nothing else.
  var reason: HermesResponseReason
  /// Bumped once per burst fold. Only the *change* means anything, never the value — the
  /// controller restores a minimized panel when it moves. Explicit rather than derived from
  /// `text`/`earlierCount`/`newerCount`: a signal every future writer of those has to remember to
  /// send is a signal that eventually goes unsent.
  var burstArrivals: Int

  init(id: UUID = UUID(),
       source: HermesResponseSource,
       title: String,
       text: String,
       isHTML: Bool = false,
       isError: Bool = false,
       isRecordingReply: Bool = false,
       supportsReply: Bool = true,
       supportsVoiceReply: Bool? = nil,
       supportsTextReply: Bool? = nil,
       beeperChatID: String? = nil,
       replyFailure: String? = nil,
       isSendingReply: Bool = false,
       preservedReplyText: String? = nil,
       earlierCount: Int = 0,
       newerCount: Int = 0,
       reason: HermesResponseReason = .live,
       burstArrivals: Int = 0) {
    self.id = id
    self.source = source
    self.title = title
    self.text = text
    self.isHTML = isHTML
    self.isError = isError
    self.isRecordingReply = isRecordingReply
    self.supportsReply = supportsReply
    self.supportsVoiceReply = supportsVoiceReply ?? supportsReply
    self.supportsTextReply = supportsTextReply ?? supportsReply
    self.beeperChatID = beeperChatID
    self.replyFailure = replyFailure
    self.isSendingReply = isSendingReply
    self.preservedReplyText = preservedReplyText
    self.earlierCount = earlierCount
    self.newerCount = newerCount
    self.reason = reason
    self.burstArrivals = burstArrivals
  }

  /// Beeper panels get the message glyph, the status line and the Snooze control; Hermes and
  /// Codex panels get none of them. `beeperChatID` is the discriminator and the snooze payload
  /// in one field — do not infer the source from `title` or `supportsTextReply`, Codex uses
  /// text reply too.
  var beeperChat: String? {
    guard let beeperChatID, !beeperChatID.isEmpty else { return nil }
    return beeperChatID
  }

  var pillStatus: HermesResponsePillStatus {
    if isError { return .error }
    if isRecordingReply { return .recording }
    if isSendingReply { return .sending }
    return .normal
  }
}

enum HermesResponseReason: Equatable {
  case live
  case snoozeExpired
}

/// The one status line under a Beeper panel's header, as a pure function of the two counters
/// and the reason. Empty means render nothing at all — no line, no `Open Beeper`.
///
/// The two counters are separate quantities and only one of them is true about any given held
/// message, so the copy states each one rather than summing them. `Snooze ended` is a
/// reason-for-appearance tag, never a coverage claim: the gate records what it suppressed, not
/// what was sent, so no phrasing here may say "while you were snoozed". Past tense, because at
/// the moment this panel appears the chat is no longer snoozed.
///
/// No cap on the number. "+49" is the signal; capping at "+9" would lie precisely when the
/// information matters most.
enum HermesBeeperStatusLine {
  struct Segment: Equatable {
    var text: String
    /// The live count is the one number that is still moving, so it earns weight. Weight only —
    /// never colour, never a badge, never red. Red reads as "deal with me now", which is the
    /// opposite of "the rest are in Beeper".
    var isEmphasized: Bool = false
    /// What VoiceOver says. `+4 earlier` is typography, not a sentence: read aloud it is "plus
    /// four earlier", and the interpunct separators become "dot". Same segments, spelled out.
    var spoken: String
  }

  static func segments(
    earlierCount: Int,
    newerCount: Int,
    reason: HermesResponseReason
  ) -> [Segment] {
    var segments: [Segment] = []
    if reason == .snoozeExpired {
      segments.append(Segment(text: "Snooze ended", spoken: "Snooze ended"))
    }
    if earlierCount > 0 {
      segments.append(Segment(
        text: "+\(earlierCount) earlier",
        spoken: "\(earlierCount) earlier \(earlierCount == 1 ? "message" : "messages")"
      ))
    }
    if newerCount > 0 {
      segments.append(Segment(
        text: "\(newerCount) new",
        isEmphasized: true,
        spoken: "\(newerCount) new \(newerCount == 1 ? "message" : "messages")"
      ))
    }
    return segments
  }

  /// The whole line as one utterance. VoiceOver reading five sibling nodes turns "+4 earlier · 2
  /// new" into punctuation; one label makes it a sentence.
  static func spokenLine(
    earlierCount: Int,
    newerCount: Int,
    reason: HermesResponseReason
  ) -> String {
    segments(earlierCount: earlierCount, newerCount: newerCount, reason: reason)
      .map(\.spoken)
      .joined(separator: ", ")
  }
}

/// Fixed copy per failure cause. A Settings cause is something Dane can act on and a transport
/// cause is not; telling him which is the difference between a fix and a shrug. Every string
/// stays under ~50 characters — the status row has roughly 264pt left once Cancel and Retry take
/// their share of a minimum-width panel, and `error.localizedDescription` blows that while
/// telling him nothing.
enum HermesReplyFailureCopy {
  static let beeperSendFailed = "Couldn't send to Beeper. Try again."
  static let beeperDisabled = "Beeper is off. Turn it on in Settings to send."
  static let hermesDisabled = "Hermes is off. Turn it on in Settings to send."
  static let hermesSessionNotReady = "This Hermes session isn't ready yet. Try again."
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

  /// A send attempt starts: commit the composer and clear any previous failure in the same write,
  /// so the button reads `Send Text` rather than `Retry` while this attempt is in flight.
  static func replySendStarted(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var sendingState = state
      sendingState.isSendingReply = true
      sendingState.replyFailure = nil
      return sendingState
    }
  }

  /// Releases the composer whatever the outcome, mirroring the `beeperIsSending` defer it sits
  /// beside. Today the success path has already torn the state down and the failure path clears the
  /// flag itself, so this is belt-and-braces — but a leaked `true` is a panel permanently locked out
  /// of retrying with Dane's words still in it, which is too expensive to leave to the next edit.
  static func replySendFinished(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var finishedState = state
      finishedState.isSendingReply = false
      return finishedState
    }
  }

  /// Both writes together, on every failure path. `isSendingReply` must go false here even for the
  /// synchronous guards that never set it: a state carrying it into a re-presentation would hand
  /// Dane a panel locked out of the retry it exists to offer.
  static func replySendFailed(
    _ states: [HermesResponseWindowState],
    sessionID: UUID,
    failure: String
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var failedState = state
      failedState.replyFailure = failure
      failedState.isSendingReply = false
      return failedState
    }
  }

  /// Shapes a snapshot for re-presentation after Dane dismissed the panel mid-flight. The forced
  /// `isSendingReply = false` is the point: the snapshot was taken after the flag was set, and
  /// re-presenting it as-is hands back a panel whose editor, Send and Cancel are disabled forever —
  /// the recovery gesture arriving dead.
  static func replyRepresented(
    _ snapshot: HermesResponseWindowState,
    failure: String,
    preservedText: String
  ) -> HermesResponseWindowState {
    var represented = snapshot
    represented.replyFailure = failure
    represented.isSendingReply = false
    represented.preservedReplyText = preservedText
    return represented
  }

  /// Cancel discards the draft, so the red line describing it has to go too — otherwise it
  /// strands, waiting for Dane to reopen Text Reply onto a failure about text that is gone.
  /// Hide Text deliberately does not call this: it hides the composer and the line with it.
  static func replyFailureCleared(
    _ states: [HermesResponseWindowState],
    sessionID: UUID
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var clearedState = state
      clearedState.replyFailure = nil
      return clearedState
    }
  }

  /// Folds a burst update into a panel that is already on screen, instead of building a fresh
  /// `HermesResponseWindowState` for it. That distinction is the whole point: a fresh state resets
  /// `replyFailure`, `isSendingReply`, `isRecordingReply` and `preservedReplyText`, and because the
  /// id stays in `hermesResponseWindowStates` the controller keeps the same panel, panel model and
  /// `HermesTextReplyDraft` — so the composer's text, caret, selection and scroll survive, and key
  /// window is never stolen mid-typing.
  ///
  /// `title`, `text` and `isHTML` are one coupled group describing the displayed message: pass all
  /// three to move the body, pass none to hold it. Holding the body while `newerCount` climbs is
  /// the draft-safety rule, so it has to be expressible without touching the counters' caller.
  ///
  /// The counts are absolute, not deltas — the pending accumulator is the caller's, and two
  /// sources of truth for one number is how the count starts lying. A no-op when no state carries
  /// `sessionID`; this never creates a panel.
  static func burstCoalesced(
    _ states: [HermesResponseWindowState],
    sessionID: UUID,
    title: String? = nil,
    text: String? = nil,
    isHTML: Bool? = nil,
    earlierCount: Int,
    newerCount: Int
  ) -> [HermesResponseWindowState] {
    states.map { state in
      guard state.id == sessionID else { return state }
      var coalesced = state
      if let title { coalesced.title = title }
      if let text { coalesced.text = text }
      if let isHTML { coalesced.isHTML = isHTML }
      coalesced.earlierCount = earlierCount
      coalesced.newerCount = newerCount
      // Every fold is an arrival, held or not, so the bump lives here rather than at the two call
      // sites: one funnel nobody has to remember. `render` restores on the change.
      coalesced.burstArrivals = state.burstArrivals + 1
      return coalesced
    }
  }

  /// Panels that must come back to the front because a burst arrival landed on them. A minimized
  /// panel still absorbs its chat's bursts — one panel per chat, no duplicate reply target — but
  /// absorbing silently would make minimize a second, invisible snooze with no deadline and no
  /// resume affordance. Minimize is window management; snooze is the only "not now".
  static func burstRestoreSessionIDs(
    previous: [HermesResponseWindowState],
    current: [HermesResponseWindowState]
  ) -> [UUID] {
    current.compactMap { state in
      guard let was = previous.first(where: { $0.id == state.id }),
            was.burstArrivals != state.burstArrivals else { return nil }
      return state.id
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
  static let pillSize = NSSize(width: 126, height: 52)
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

/// The dynamic inputs of one panel's SwiftUI tree. The hosting view is built once per panel
/// and observes this, so a state publish mutates properties instead of replacing the view
/// tree — which is what preserves the composer's caret, selection and scroll position.
///
/// Exactly four properties, and nothing that already lives inside `state` (notably
/// `isRecordingReply`) gets a second copy here. `isMinimized` and `isTextReplyVisible` are
/// derived from `minimizedOrder` / `textReplySessionIDs` on every mutate, never assigned at
/// a mutation site: those two collections stay the source of truth because `layoutBubbles`
/// and `isDismissibleResponsePanel` read them.
@MainActor
private final class HermesResponsePanelModel: ObservableObject {
  @Published var state: HermesResponseWindowState
  @Published var isForeground: Bool = false
  @Published var isTextReplyVisible: Bool = false
  @Published var isMinimized: Bool = false

  init(state: HermesResponseWindowState) {
    self.state = state
  }
}

@MainActor
final class HermesResponseWindowController: NSObject, NSWindowDelegate {
  private weak var viewModel: DictationViewModel?
  private var panels: [UUID: HermesResponsePanel] = [:]
  private var latestStates: [HermesResponseWindowState] = []
  private var focusedSessionID: UUID?
  private var panelFrontToBackOrder: [UUID] = []
  private var textReplyDrafts: [UUID: HermesTextReplyDraft] = [:]
  private var textReplyDraftObservers: [UUID: AnyCancellable] = [:]
  private var panelModels: [UUID: HermesResponsePanelModel] = [:]
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

  /// `windowWillClose` drops this controller's panel bookkeeping *before* it reaches the view
  /// model, so the view-model guard alone cannot hold the invariant: the panel would already be
  /// gone from `panels` and the next render would re-present a fresh one under Dane's voice.
  /// Veto the native route instead, which covers ⌘W and `performClose:` as well as the header
  /// control. `close()` bypasses this by design, and nothing calls it on these panels.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let panel = sender as? HermesResponsePanel,
          let sessionID = panel.sessionID else {
      return true
    }
    return !isRecordingReply(sessionID: sessionID)
  }

  private func isRecordingReply(sessionID: UUID) -> Bool {
    latestStates.first { $0.id == sessionID }?.isRecordingReply ?? false
  }

  func windowWillClose(_ notification: Notification) {
    guard let panel = notification.object as? HermesResponsePanel,
          let sessionID = panel.sessionID else {
      return
    }
    panels[sessionID] = nil
    // This path clears `panels` before `render(_ states:)` runs, so its cleanup loop — which
    // iterates `panels.keys` — never sees this session again. Drop the model here or it leaks.
    panelModels[sessionID] = nil
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
    // A failed reply presents itself: hidden composer → reveal, minimized panel → restore, closed
    // panel → re-presented by the per-state loop below. The three cases are disjoint, so no
    // branching is needed — `restorePanel`'s own guard returns immediately for a panel that is not
    // minimized. This reads the *previous* publish, so it must stay above `latestStates = states`;
    // below it the comparison is always equal, and then Hide Text and Minimize would both stop
    // working because a steady-state reveal re-opens the composer on every publish.
    for state in states where state.replyFailure != nil {
      guard latestStates.first(where: { $0.id == state.id })?.replyFailure == nil else { continue }
      textReplySessionIDs.insert(state.id)
      restorePanel(sessionID: state.id)
    }
    // Same shape, same reason for living above `latestStates = states`: a burst arrival is a fresh
    // interruption, so the panel it folded into comes back to the front instead of mutating behind
    // a bubble. The body below this loop is what gets restored — `restorePanel` renders the
    // previous state, the per-state loop then pushes the new one into the same panel.
    for sessionID in HermesResponseWindowLifecycle.burstRestoreSessionIDs(
      previous: latestStates,
      current: states
    ) {
      restorePanel(sessionID: sessionID)
    }
    latestStates = states
    let activeIDs = Set(states.map(\.id))
    for sessionID in Array(panels.keys) where !activeIDs.contains(sessionID) {
      panels[sessionID]?.orderOut(nil)
      panels[sessionID]?.delegate = nil
      panels[sessionID] = nil
      panelModels[sessionID] = nil
      textReplyDrafts[sessionID] = nil
      textReplyDraftObservers[sessionID] = nil
      textReplySessionIDs.remove(sessionID)
      minimizedOrder.removeAll { $0 == sessionID }
      panelFrontToBackOrder.removeAll { $0 == sessionID }
      preMinimizeFrames[sessionID] = nil
    }

    for state in states {
      let isNewPanel = panels[state.id] == nil
      let panel = panels[state.id] ?? makePanel(sessionID: state.id, state: state)
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

  /// Pushes one panel's dynamic inputs into its model. The hosting view was built once in
  /// `makePanel`, so this mutates — it never reassigns `contentView`. Every path that used to
  /// rebuild a panel calls this instead.
  private func render(_ state: HermesResponseWindowState,
                      in panel: HermesResponsePanel,
                      isForeground: Bool) {
    // AppKit, not SwiftUI: `NSWindow.title` is not observable from the view, so it stays here.
    // `titleVisibility` is `.hidden`, so a stale title is invisible in the panel and shows up
    // only in Mission Control, the window list and VoiceOver.
    panel.title = state.title
    guard let model = panelModels[state.id] else { return }
    model.state = state
    model.isForeground = isForeground
    // Derived, never assigned at the mutation site: `minimizedOrder` and `textReplySessionIDs`
    // remain the source of truth, so a new write site to either cannot desync the view.
    model.isMinimized = minimizedOrder.contains(state.id)
    model.isTextReplyVisible = textReplySessionIDs.contains(state.id)
  }

  private func minimizePanel(sessionID: UUID) {
    guard let panel = panels[sessionID], !minimizedOrder.contains(sessionID) else { return }
    preMinimizeFrames[sessionID] = panel.frame
    minimizedOrder.append(sessionID)
    panel.contentMinSize = HermesResponseWindowLayout.pillSize
    if let state = latestStates.first(where: { $0.id == sessionID }) {
      render(state, in: panel, isForeground: false)
    }
    panel.setContentSize(HermesResponseWindowLayout.pillSize)
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
    let size = HermesResponseWindowLayout.pillSize
    for (index, sessionID) in minimizedOrder.enumerated() {
      guard let panel = panels[sessionID] else { continue }
      let x = screenFrame.maxX - size.width - HermesResponseWindowLayout.bubbleEdgeInset
      let y = screenFrame.maxY - size.height - HermesResponseWindowLayout.bubbleEdgeInset
              - CGFloat(index) * (size.height + HermesResponseWindowLayout.bubbleSpacing)
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
  }

  /// `seed` fires on creation only, and creation is once per panel — the hosting view is handed
  /// this object in `makePanel` and the render path never asks again. So in practice it applies on
  /// exactly one path: a state that was removed and re-appended by a failed send. Do not add a
  /// render-time seed for symmetry; a creation-only read from a stale state is how preserved text
  /// gets silently dropped.
  private func textReplyDraft(for sessionID: UUID, seed: String? = nil) -> HermesTextReplyDraft {
    if let draft = textReplyDrafts[sessionID] {
      return draft
    }
    let draft = HermesTextReplyDraft()
    if let seed {
      draft.text = seed
    }
    textReplyDrafts[sessionID] = draft
    // The draft lives here, but the burst rules that must not overwrite it run in the view model,
    // which holds no reference to this controller. So push the one bit it needs rather than
    // inverting the dependency. `removeDuplicates` is load-bearing: this fires on the empty↔
    // non-empty transition only, never per keystroke, so typing cannot cause a republish storm.
    textReplyDraftObservers[sessionID] = draft.$text
      .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .removeDuplicates()
      .sink { [weak self] hasDraft in
        self?.viewModel?.setResponseWindowHasDraft(sessionID: sessionID, hasDraft: hasDraft)
      }
    return draft
  }

  private func toggleTextReply(for sessionID: UUID) {
    if textReplySessionIDs.contains(sessionID) {
      textReplySessionIDs.remove(sessionID)
    } else {
      textReplySessionIDs.insert(sessionID)
    }
    renderPanel(sessionID: sessionID)
  }

  /// Cancel discards the draft, so the failure line describing that draft goes with it — otherwise
  /// it strands, waiting for Dane to reopen Text Reply onto a red line about text that no longer
  /// exists. Hide Text deliberately does not come through here: it hides the composer and the line
  /// together and both come back. `replyFailure` is VM state and the VM cannot call back into this
  /// controller, so the clear is a call outwards whose publish re-renders this panel again.
  private func cancelTextReply(for sessionID: UUID) {
    textReplyDrafts[sessionID]?.text = ""
    textReplySessionIDs.remove(sessionID)
    renderPanel(sessionID: sessionID)
    viewModel?.clearResponseWindowReplyFailure(sessionID: sessionID)
  }

  /// Only this panel's model changed. `render(latestStates)` used to rebuild every panel's
  /// view tree here, which is what threw the caret out of every *other* open composer.
  private func renderPanel(sessionID: UUID) {
    guard let panel = panels[sessionID],
          let state = latestStates.first(where: { $0.id == sessionID }) else { return }
    render(
      state,
      in: panel,
      isForeground: focusedSessionID == sessionID || panel.isKeyWindow
    )
  }

  /// The composer stays open through the send. Clearing the draft and closing the composer here is
  /// what made a failed reply look identical to a successful one — an open, empty composer, which
  /// is precisely what a clean send leaves behind. Nothing needs to close it on success: every
  /// success path tears the panel down and the cleanup loop in `render(_ states:)` drops the draft.
  ///
  /// ponytail: that invariant is load-bearing and nothing enforces it. It holds by two facts.
  /// (1) `deleteHermesSession` removes the panel *before* dropping the session, so a live Hermes
  /// panel always has its session and the teardown inside `sendHermesTextReply` cannot target a
  /// remapped id. (2) `beeperResponseWindowTargets` is written and cleared only alongside the
  /// panel, so a Beeper panel can never fall through to the Hermes branch. Add a session-removal
  /// path that does not remove the panel first, or clear that dict outside teardown, and sent text
  /// reappears in a reopened composer looking unsent: no crash, no failing test.
  private func sendTextReply(_ text: String, sessionID: UUID) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    viewModel?.sendResponseWindowTextReply(trimmed, sessionID: sessionID)
  }

  private func makePanel(sessionID: UUID, state: HermesResponseWindowState) -> HermesResponsePanel {
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

    // The one place a hosting view is created for this panel. Everything dynamic afterwards
    // goes through `model`; the action closures capture it rather than capturing `state` by
    // value, or they would copy the first body and never see an update.
    let model = HermesResponsePanelModel(state: state)
    panelModels[sessionID] = model
    panel.contentView = NSHostingView(
      rootView: HermesResponsePanelHost(
        model: model,
        textReplyDraft: textReplyDraft(for: sessionID, seed: state.preservedReplyText),
        onCopyRaw: { [model] in HermesResponseClipboard.copyRaw(model.state.text) },
        onCopyFormatted: { [model] in
          HermesResponseClipboard.copyFormatted(model.state.text, isHTML: model.state.isHTML)
        },
        onReply: { [weak self] in
          self?.viewModel?.startResponseWindowVoiceReply(to: sessionID)
        },
        onToggleTextReply: { [weak self] in self?.toggleTextReply(for: sessionID) },
        onCancelTextReply: { [weak self] in self?.cancelTextReply(for: sessionID) },
        onSendTextReply: { [weak self] text in
          self?.sendTextReply(text, sessionID: sessionID)
        },
        onMinimize: { [weak self] in self?.minimizePanel(sessionID: sessionID) },
        onRestore: { [weak self] in self?.restorePanel(sessionID: sessionID) },
        onClose: { [weak self] in self?.viewModel?.dismissHermesResponse(sessionID: sessionID) },
        onSnooze: { [weak self] duration in
          self?.viewModel?.snoozeBeeperResponse(sessionID: sessionID, duration: duration)
        },
        onOpenBeeper: { [weak self] in self?.viewModel?.openBeeperApp() }
      )
    )

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

/// The single stable root of a panel's view tree. Observes the model so a state change is a
/// SwiftUI update rather than a new `NSHostingView`, and picks the minimized or expanded body
/// from `model.isMinimized` — the two hosting views this replaces.
///
/// Window sizing and bubble layout are not here: the controller still drives `contentMinSize`,
/// `setContentSize` and `layoutBubbles()` around this flag.
private struct HermesResponsePanelHost: View {
  @ObservedObject var model: HermesResponsePanelModel
  // Passed through, not observed: `HermesResponsePanelView` observes it. A second subscription
  // here would re-evaluate this whole body on every keystroke for no gain.
  var textReplyDraft: HermesTextReplyDraft
  var onCopyRaw: () -> Void
  var onCopyFormatted: () -> Void
  var onReply: () -> Void
  var onToggleTextReply: () -> Void
  var onCancelTextReply: () -> Void
  var onSendTextReply: (String) -> Void
  var onMinimize: () -> Void
  var onRestore: () -> Void
  var onClose: () -> Void
  var onSnooze: (BeeperSnoozeDuration) -> Void
  var onOpenBeeper: () -> Void

  var body: some View {
    if model.isMinimized {
      HermesResponsePillView(state: model.state, onRestore: onRestore)
    } else {
      HermesResponsePanelView(
        state: model.state,
        isForeground: model.isForeground,
        textReplyDraft: textReplyDraft,
        isTextReplyVisible: model.isTextReplyVisible,
        onCopyRaw: onCopyRaw,
        onCopyFormatted: onCopyFormatted,
        onReply: onReply,
        onToggleTextReply: onToggleTextReply,
        onCancelTextReply: onCancelTextReply,
        onSendTextReply: onSendTextReply,
        onMinimize: onMinimize,
        onClose: onClose,
        onSnooze: onSnooze,
        onOpenBeeper: onOpenBeeper
      )
    }
  }
}

/// Which reply control in the bottom row is the panel's primary action, and therefore the one
/// drawn `.borderedProminent`.
///
/// Prominence follows the live action rather than a fixed control: while a voice reply is
/// recording, the Voice Reply button reads "Send" and is what the next click is for, so it
/// outranks Text Reply. A control that is disabled can never be primary — a prominent button
/// nobody can click is worse hierarchy than a flat row.
///
/// The two `…IsDisabled` predicates are the same values the buttons pass to `.disabled`, not a
/// second copy of them, so prominence cannot drift out of step with enablement.
enum HermesPanelPrimaryAction: Equatable {
  case voice
  case text
  case none

  static func voiceIsDisabled(_ state: HermesResponseWindowState) -> Bool {
    state.isError && !state.isRecordingReply
  }

  static func textIsDisabled(_ state: HermesResponseWindowState) -> Bool {
    state.isError || state.isRecordingReply
  }

  static func resolve(_ state: HermesResponseWindowState) -> HermesPanelPrimaryAction {
    let voiceAvailable = state.supportsVoiceReply && !voiceIsDisabled(state)
    let textAvailable = state.supportsTextReply && !textIsDisabled(state)

    if voiceAvailable && state.isRecordingReply { return .voice }
    if textAvailable { return .text }
    if voiceAvailable { return .voice }
    return .none
  }
}

private extension View {
  /// `.borderedProminent` when this is the panel's primary action, `.bordered` otherwise.
  /// A ternary inside `.buttonStyle` does not type-check — the two styles are different
  /// concrete types — so the branch has to happen at the view level.
  @ViewBuilder
  func replyProminence(isPrimary: Bool) -> some View {
    if isPrimary {
      buttonStyle(.borderedProminent)
    } else {
      buttonStyle(.bordered)
    }
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
  var onCancelTextReply: () -> Void
  var onSendTextReply: (String) -> Void
  var onMinimize: () -> Void
  var onClose: () -> Void
  var onSnooze: (BeeperSnoozeDuration) -> Void
  var onOpenBeeper: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // The status line is context for the body you are about to read, not a footnote, so it
      // groups tight to the header rather than taking the stack's full 14pt.
      VStack(alignment: .leading, spacing: 6) {
        header
        beeperStatusLine
      }

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

      actionRow
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

  /// `waveform.and.sparkles` is a generic AI glyph, and a Beeper panel is a message from a
  /// person. Source only — burst and snooze state stay in the status line, which can spell them
  /// out; an icon cannot.
  private var headerGlyph: String {
    if state.isError { return "exclamationmark.triangle.fill" }
    return state.beeperChat == nil ? "waveform.and.sparkles" : "bubble.left.fill"
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: headerGlyph)
        .font(.title3)
        .foregroundStyle(state.isError ? .red : .blue)
        .frame(width: 26, height: 26)

      Text(state.title)
        .font(.headline)
        .lineLimit(1)

      Spacer()

      // These are now the only Minimize/Close in the panel, so they carry the shortcut and
      // the accessibility label the bottom-row duplicates used to carry. An icon-only
      // Button otherwise reads to VoiceOver as its SF Symbol name ("minus", "xmark").
      Button(action: onMinimize) {
        Image(systemName: "minus")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("m", modifiers: [.command])
      .accessibilityLabel("Minimize")
      .help("Minimize (⌘M)")

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Close")
      // Same invariant as Snooze: a panel Dane is actively speaking to cannot disappear,
      // because teardown drops the reply target and the finished transcription would send
      // with no `replyToMessageID`. Closing stays available during send, where the target
      // is already committed.
      .disabled(state.isRecordingReply)
      // Escape is handled centrally in HermesResponsePanel.keyDown so it targets the
      // topmost window and yields to active recordings.
      .help(
        state.isRecordingReply
          ? "Finish or cancel this voice reply before closing (esc cancels)."
          : "Close (esc)"
      )
    }
  }

  private var primaryReplyAction: HermesPanelPrimaryAction {
    HermesPanelPrimaryAction.resolve(state)
  }

  @ViewBuilder
  private var beeperStatusLine: some View {
    let segments = HermesBeeperStatusLine.segments(
      earlierCount: state.earlierCount,
      newerCount: state.newerCount,
      reason: state.reason
    )
    if state.beeperChat != nil, !segments.isEmpty {
      HStack(spacing: 4) {
        // Secondary applies to the copy only. The link keeps the accent colour it needs to
        // read as clickable at all.
        countRun(segments)
          .foregroundStyle(.secondary)
          // The separators are typography and the counts are one fact, so the run speaks as one
          // sentence rather than as "plus", "dot", "dot".
          .accessibilityLabel(HermesBeeperStatusLine.spokenLine(
            earlierCount: state.earlierCount,
            newerCount: state.newerCount,
            reason: state.reason
          ))

        // Telling Dane the rest are in Beeper without a way to get there manufactures the
        // friction this feature exists to remove.
        // `.link` style rendered as an unnamed AX link that no label modifier could name, so
        // this is a plain button wearing link clothes: accent colour and the link cursor.
        Button(action: onOpenBeeper) {
          Text("Open Beeper")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .pointerStyle(.link)
      }
      .font(.caption)
    }
  }

  /// The count run as one concrete `Text`, built by concatenation rather than an `HStack`.
  /// Per-fragment weight survives `+`, and AppKit gets a single named element — a container
  /// asked to collapse into one AX node here produced no node at all.
  private func countRun(_ segments: [HermesBeeperStatusLine.Segment]) -> Text {
    var line = Text("")
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        line = line + Text(" · ")
      }
      line = line + Text(segment.text).fontWeight(segment.isEmphasized ? .medium : .regular)
    }
    return line + Text(" ·")
  }

  private var actionRow: some View {
    HStack(spacing: 10) {
      if state.beeperChat != nil {
        snoozeControl
      }

      Spacer()

      Menu {
        Button(action: onCopyFormatted) {
          Label("Copy Formatted", systemImage: "doc.richtext")
        }
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      } primaryAction: {
        onCopyRaw()
      }
      .fixedSize()
      .help("Copy raw text (⇧⌘C). Open for formatted.")

      if state.supportsVoiceReply {
        Button(action: onReply) {
          Label(
            state.isRecordingReply ? "Send" : "Voice Reply",
            systemImage: state.isRecordingReply ? "paperplane.fill" : "mic.fill"
          )
        }
        .disabled(HermesPanelPrimaryAction.voiceIsDisabled(state))
        .replyProminence(isPrimary: primaryReplyAction == .voice)
      }

      if state.supportsTextReply {
        Button(action: onToggleTextReply) {
          Label(
            isTextReplyVisible ? "Hide Text" : "Text Reply",
            systemImage: isTextReplyVisible ? "text.bubble.fill" : "text.bubble"
          )
        }
        .disabled(HermesPanelPrimaryAction.textIsDisabled(state))
        .replyProminence(isPrimary: primaryReplyAction == .text)
      }
    }
    .background(copyRawShortcut)
  }

  /// Leading edge of the row, held away from the reply cluster by the row's `Spacer()`.
  /// Physical distance from where the hand is going is what "do not crowd the reply" means.
  ///
  /// Primary click is 1 hour, not 15 minutes: the real triggers are a meeting, a deep-work
  /// block, dinner, and 15 minutes covers none of them. The label states the duration, so the
  /// click holds no surprise and needs no undo at the point of click — regret is handled in the
  /// menu bar. "Until morning" rather than "rest of day", which is ambiguous at 11pm and
  /// meaningless at 2am.
  private var snoozeControl: some View {
    Menu {
      Button("15 minutes") { onSnooze(.fifteenMinutes) }
      Button("1 hour") { onSnooze(.oneHour) }
      Button("Until morning") { onSnooze(.untilMorning) }
    } label: {
      Label("Snooze 1h", systemImage: "moon.zzz")
    } primaryAction: {
      onSnooze(.oneHour)
    }
    .fixedSize()
    // A panel Dane is actively speaking to cannot disappear. Snooze dismisses the window, and
    // teardown drops the reply target with it, so snoozing mid-recording would send the finished
    // transcription with no `replyToMessageID`. `.disabled` on the Menu covers both the primary
    // click and the duration items. Sending is deliberately still snoozeable: delayed send →
    // Snooze → next message is a required interleaving, and by then the target is committed.
    .disabled(state.isRecordingReply)
    .help(
      state.isRecordingReply
        ? "Finish or cancel this voice reply before snoozing."
        : "Snooze this chat for an hour. Open for other durations."
    )
  }

  // ⇧⌘C is carried by an invisible Button, not by the Menu or by an item inside it.
  // Menu content is built lazily, so a shortcut on an item is not registered until the menu
  // has been opened once — and a shortcut on the Menu itself does not register cold either
  // (measured at 8942811: clipboard stayed empty until the menu had been opened). A plain
  // Button registers on first render, the same reason ⌘M works on the header's Minimize.
  // It rides in .background so it claims none of actionRow's 10pt spacing.
  private var copyRawShortcut: some View {
    Button("Copy Raw", action: onCopyRaw)
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
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
        // The disabled composer *is* the in-flight indicator, and it is a data fix rather than
        // latency polish: text typed after Send is dropped when a successful send tears the panel
        // down. `.disabled()` cannot do this — it does not reach inside an NSViewRepresentable —
        // so the flag is a parameter driving both `isEditable` and the Return-to-send hook.
        isEnabled: !state.isSendingReply,
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
        // One status slot, three states. Red is correct here and nowhere else in this panel: the
        // line names the cause, the button below names the gesture. The idle copy replaces
        // "Type a reply to this Hermes session.", which named Hermes on a message from Sam and on
        // a Codex panel, and teaches the shortcut the composer actually implements.
        if let failure = state.replyFailure {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        } else if state.isSendingReply {
          // ponytail: static copy, no spinner. Add one only if real send latency makes it feel dead.
          Text("Sending…")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Return to send · ⇧Return for a new line.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: onCancelTextReply) {
          Label("Cancel", systemImage: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(state.isSendingReply)

        Button {
          onSendTextReply(textReplyDraft.text)
        } label: {
          Label(
            state.replyFailure == nil ? "Send Text" : "Retry",
            systemImage: state.replyFailure == nil ? "paperplane.fill" : "arrow.clockwise"
          )
        }
        .disabled(
          state.isSendingReply
            || textReplyDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }
}

private struct HermesResponsePillView: View {
  var state: HermesResponseWindowState
  var onRestore: () -> Void
  @State private var isHovering = false
  @State private var isPressed = false

  var body: some View {
    ZStack {
      HStack(spacing: 8) {
        Image(systemName: state.source.symbolName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(state.source.tint)
          .frame(width: 28, height: 28)
          .background(state.source.tint.opacity(0.13), in: Circle())

        Text(state.source.label)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize()

        Spacer(minLength: 0)

        if let statusSymbol = state.pillStatus.symbolName {
          Image(systemName: statusSymbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(statusTint)
            .frame(width: 14, height: 14)
        }
      }
      .padding(.horizontal, 11)
      .frame(
        width: HermesResponseWindowLayout.pillSize.width,
        height: HermesResponseWindowLayout.pillSize.height
      )
      .contentShape(Capsule(style: .continuous))
      .background {
        Capsule(style: .continuous)
          .fill(.regularMaterial)
          .overlay {
            Capsule(style: .continuous)
              .fill(accent.opacity(isHovering ? 0.10 : 0.045))
          }
      }
      .overlay {
        Capsule(style: .continuous)
          .strokeBorder(Color.primary.opacity(isHovering ? 0.24 : 0.13), lineWidth: 0.8)
      }
      .shadow(
        color: Color.black.opacity(isHovering ? 0.20 : 0.13),
        radius: isHovering ? 7 : 5,
        y: isHovering ? 3 : 2
      )
      .brightness(isPressed ? -0.05 : 0)
      .scaleEffect(isPressed ? 0.975 : 1)
      .animation(.easeOut(duration: 0.12), value: isPressed)
      .animation(.easeOut(duration: 0.14), value: isHovering)
      .accessibilityHidden(true)

      HermesResponsePillInteractionView(
        source: state.source,
        onRestore: onRestore,
        isHovering: $isHovering,
        isPressed: $isPressed
      )
    }
    .frame(
      width: HermesResponseWindowLayout.pillSize.width,
      height: HermesResponseWindowLayout.pillSize.height
    )
  }

  private var accent: Color {
    state.pillStatus == .error ? .red : state.source.tint
  }

  private var statusTint: Color {
    switch state.pillStatus {
    case .error, .recording: .red
    case .sending: state.source.tint
    case .normal: .secondary
    }
  }
}

private struct HermesResponsePillInteractionView: NSViewRepresentable {
  var source: HermesResponseSource
  var onRestore: () -> Void
  @Binding var isHovering: Bool
  @Binding var isPressed: Bool

  func makeNSView(context: Context) -> HermesResponsePillInteractionNSView {
    let view = HermesResponsePillInteractionNSView()
    update(view)
    return view
  }

  func updateNSView(_ view: HermesResponsePillInteractionNSView, context: Context) {
    update(view)
  }

  private func update(_ view: HermesResponsePillInteractionNSView) {
    let label = "Restore \(source.label) response"
    view.onRestore = onRestore
    view.onHoverChange = { isHovering = $0 }
    view.onPressChange = { isPressed = $0 }
    view.toolTip = label
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.button)
    view.setAccessibilityLabel(label)
    view.setAccessibilityHelp("Opens the full response window.")
  }
}

private final class HermesResponsePillInteractionNSView: NSView, NSAccessibilityButton {
  var onRestore: (() -> Void)?
  var onHoverChange: ((Bool) -> Void)?
  var onPressChange: ((Bool) -> Void)?
  private var hoverTrackingArea: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
      owner: self
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    onHoverChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChange?(false)
    onPressChange?(false)
  }

  override func mouseDown(with event: NSEvent) {
    onPressChange?(true)
  }

  override func mouseDragged(with event: NSEvent) {
    onPressChange?(bounds.contains(convert(event.locationInWindow, from: nil)))
  }

  override func mouseUp(with event: NSEvent) {
    let shouldRestore = bounds.contains(convert(event.locationInWindow, from: nil))
    onPressChange?(false)
    if shouldRestore {
      onRestore?()
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func accessibilityPerformPress() -> Bool {
    onRestore?()
    return true
  }
}

private struct HermesReplyTextView: NSViewRepresentable {
  @Binding var text: String
  var shouldFocus: Bool
  /// Drives two facts from one parameter, because a disabled *button* does not close the
  /// Return-to-send path: `ReplyNSTextView.keyDown` calls `onSubmit` directly. Applied in
  /// `makeNSView` as well as `updateNSView` — failure re-presentation builds a fresh panel.
  var isEnabled: Bool
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
    textView.onSubmit = isEnabled ? onSubmit : nil
    textView.string = text
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isEditable = isEnabled
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
    textView.isEditable = isEnabled
    textView.onSubmit = isEnabled ? onSubmit : nil
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
