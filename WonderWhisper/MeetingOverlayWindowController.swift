import AppKit
import Combine
import SwiftUI

private final class MeetingOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

enum MeetingOverlayLayout {
  static let defaultSize = NSSize(width: 360, height: 480)
  static let minimumSize = NSSize(width: 300, height: 320)
  static let bubbleSize = NSSize(width: 64, height: 64)
  static let edgeInset: CGFloat = 16

  static func bubbleOrigin(in visibleFrame: NSRect, near frame: NSRect) -> NSPoint {
    let x = visibleFrame.maxX - bubbleSize.width - edgeInset
    let proposedY = frame.midY - bubbleSize.height / 2
    let y = min(
      max(visibleFrame.minY + edgeInset, proposedY),
      visibleFrame.maxY - bubbleSize.height - edgeInset
    )
    return NSPoint(x: x.rounded(), y: y.rounded())
  }
}

enum MeetingBubbleInteractionPolicy {
  static let dragThreshold: CGFloat = 4

  static func isDrag(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
    hypot(deltaX, deltaY) >= dragThreshold
  }
}

@MainActor
final class MeetingOverlayWindowController: NSObject, NSWindowDelegate {
  private let coordinator: MeetingCoordinator
  private let panel: MeetingOverlayPanel
  private let bubblePanel: MeetingOverlayPanel
  private var autoStartPanel: NSPanel?
  private var autoStartTask: Task<Void, Never>?
  private var autoStartSessionID: UUID?
  private var hasPositionedPanel = false
  private var hasPositionedBubble = false
  private var cancellables: Set<AnyCancellable> = []

  init(coordinator: MeetingCoordinator) {
    self.coordinator = coordinator
    self.panel = MeetingOverlayPanel(
      contentRect: NSRect(origin: .zero, size: MeetingOverlayLayout.defaultSize),
      styleMask: [.borderless, .resizable],
      backing: .buffered,
      defer: false
    )
    self.bubblePanel = MeetingOverlayPanel(
      contentRect: NSRect(origin: .zero, size: MeetingOverlayLayout.bubbleSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    super.init()

    panel.title = "Meeting Companion"
    panel.titleVisibility = .hidden
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentMinSize = MeetingOverlayLayout.minimumSize
    panel.animationBehavior = .utilityWindow
    panel.delegate = self
    panel.contentView = NSHostingView(
      rootView: MeetingOverlayView(coordinator: coordinator)
    )

    bubblePanel.title = "Meeting Recording"
    bubblePanel.titleVisibility = .hidden
    bubblePanel.isOpaque = false
    bubblePanel.backgroundColor = .clear
    bubblePanel.hasShadow = true
    bubblePanel.isMovableByWindowBackground = true
    bubblePanel.isReleasedWhenClosed = false
    bubblePanel.isFloatingPanel = true
    bubblePanel.hidesOnDeactivate = false
    bubblePanel.becomesKeyOnlyIfNeeded = true
    bubblePanel.level = .floating
    bubblePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    bubblePanel.contentMinSize = MeetingOverlayLayout.bubbleSize
    bubblePanel.contentMaxSize = MeetingOverlayLayout.bubbleSize
    bubblePanel.animationBehavior = .utilityWindow
    bubblePanel.contentView = NSHostingView(
      rootView: MeetingOverlayBubbleContainerView(coordinator: coordinator)
    )

    Publishers.CombineLatest3(
      coordinator.$activeSessionID,
      coordinator.$meetingOverlayEnabled,
      coordinator.$overlayMinimizedSessionID
    )
      .removeDuplicates { lhs, rhs in
        lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
      }
      .sink { [weak self] sessionID, enabled, minimizedSessionID in
        guard let self else { return }
        if sessionID == nil || !enabled {
          self.panel.orderOut(nil)
          self.bubblePanel.orderOut(nil)
        } else if sessionID == minimizedSessionID {
          self.showBubble()
        } else {
          self.bubblePanel.orderOut(nil)
          self.show()
        }
      }
      .store(in: &cancellables)

    coordinator.$activeSessionID
      .removeDuplicates()
      .sink { [weak self] sessionID in
        self?.updateAutoStartToast(sessionID: sessionID)
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        guard let self,
              self.coordinator.overlayMinimizedSessionID
                == self.coordinator.activeSessionID else { return }
        if !self.bubbleIsVisibleOnScreen {
          self.positionBubble()
        }
      }
      .store(in: &cancellables)
  }

  private func show() {
    if !hasPositionedPanel {
      positionPanel()
      hasPositionedPanel = true
    }
    panel.orderFrontRegardless()
  }

  private func positionPanel() {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let origin = NSPoint(
      x: max(visible.minX + 18, visible.maxX - panel.frame.width - 18),
      y: max(visible.minY + 18, visible.maxY - panel.frame.height - 72)
    )
    panel.setFrameOrigin(origin)
  }

  private func showBubble() {
    if !hasPositionedBubble || !bubbleIsVisibleOnScreen {
      positionBubble()
    }
    panel.orderOut(nil)
    bubblePanel.orderFrontRegardless()
  }

  private var bubbleIsVisibleOnScreen: Bool {
    NSScreen.screens.contains { screen in
      let intersection = screen.visibleFrame.intersection(bubblePanel.frame)
      return intersection.width >= MeetingOverlayLayout.bubbleSize.width / 2
        && intersection.height >= MeetingOverlayLayout.bubbleSize.height / 2
    }
  }

  private func positionBubble() {
    let pointer = NSEvent.mouseLocation
    let screen = panel.screen
      ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) })
      ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return }
    bubblePanel.setFrameOrigin(
      MeetingOverlayLayout.bubbleOrigin(in: visibleFrame, near: panel.frame)
    )
    hasPositionedBubble = true
  }

  private func updateAutoStartToast(sessionID: UUID?) {
    guard let sessionID,
          let session = coordinator.sessions.first(where: { $0.id == sessionID }),
          session.automaticallyStarted else {
      hideAutoStartToast()
      return
    }
    showAutoStartToast(session: session)
  }

  private func showAutoStartToast(session: MeetingSession) {
    hideAutoStartToast()
    autoStartSessionID = session.id
    let content = MeetingAutoStartToastView(
      appName: session.detectedApp ?? session.title,
      onDiscard: { [weak self] in
        guard let self else { return }
        let sessionID = session.id
        hideAutoStartToast(expectedSessionID: sessionID)
        Task { await self.coordinator.discardAutomaticMeeting(sessionID: sessionID) }
      },
      onKeep: { [weak self] in
        self?.hideAutoStartToast(expectedSessionID: session.id)
      }
    )
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
    let toast = NSPanel(
      contentRect: hosting.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    toast.level = .statusBar
    toast.isOpaque = false
    toast.backgroundColor = .clear
    toast.hasShadow = true
    toast.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle
    ]
    toast.contentView = hosting
    if let visible = NSScreen.main?.visibleFrame {
      toast.setFrameOrigin(NSPoint(
        x: visible.maxX - hosting.frame.width - 16,
        y: visible.maxY - hosting.frame.height - 12
      ))
    }
    toast.orderFrontRegardless()
    autoStartPanel = toast
    autoStartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard !Task.isCancelled else { return }
      self?.hideAutoStartToast(expectedSessionID: session.id)
    }
  }

  private func hideAutoStartToast(expectedSessionID: UUID? = nil) {
    if let expectedSessionID, autoStartSessionID != expectedSessionID { return }
    autoStartTask?.cancel()
    autoStartTask = nil
    autoStartPanel?.orderOut(nil)
    autoStartPanel = nil
    autoStartSessionID = nil
  }
}

private struct MeetingOverlayBubbleContainerView: View {
  @ObservedObject var coordinator: MeetingCoordinator

  var body: some View {
    if let session = coordinator.activeSession {
      MeetingOverlayBubbleView(coordinator: coordinator, session: session)
    } else {
      Color.clear
    }
  }
}

private struct MeetingOverlayBubbleView: View {
  @ObservedObject var coordinator: MeetingCoordinator
  let session: MeetingSession
  private let barMultipliers: [CGFloat] = [0.58, 0.84, 1, 0.76, 0.5]

  private var audioLevel: CGFloat {
    CGFloat(coordinator.liveAudioLevels.values.max() ?? 0)
  }

  var body: some View {
    ZStack {
      ZStack {
        Circle()
          .fill(.regularMaterial)
        Circle()
          .strokeBorder(Color.red.opacity(0.5), lineWidth: 1.5)

        HStack(alignment: .center, spacing: 2.5) {
          ForEach(barMultipliers.indices, id: \.self) { index in
            Capsule()
              .fill(index.isMultiple(of: 2) ? Color.blue : Color.purple)
              .frame(
                width: 3.5,
                height: 5 + 21 * audioLevel * barMultipliers[index]
              )
          }
        }
        .animation(.easeOut(duration: 0.12), value: audioLevel)

        Circle()
          .fill(.red)
          .frame(width: 8, height: 8)
          .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
          .offset(x: 20, y: -20)
      }

      MeetingBubbleInteractionView(
        toolTip: "Restore \(session.title)",
        onRestore: coordinator.restoreMeetingOverlayForCurrentSession
      )
    }
    .frame(
      width: MeetingOverlayLayout.bubbleSize.width,
      height: MeetingOverlayLayout.bubbleSize.height
    )
    .accessibilityLabel("Meeting recording")
    .accessibilityHint("Restore the meeting companion")
  }
}

private struct MeetingBubbleInteractionView: NSViewRepresentable {
  let toolTip: String
  let onRestore: () -> Void

  func makeNSView(context: Context) -> MeetingBubbleInteractionNSView {
    let view = MeetingBubbleInteractionNSView()
    view.onRestore = onRestore
    view.toolTip = toolTip
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.button)
    view.setAccessibilityLabel("Meeting recording")
    view.setAccessibilityHelp("Click to restore. Drag to reposition.")
    return view
  }

  func updateNSView(_ view: MeetingBubbleInteractionNSView, context: Context) {
    view.onRestore = onRestore
    view.toolTip = toolTip
  }
}

private final class MeetingBubbleInteractionNSView: NSView {
  var onRestore: (() -> Void)?
  private var mouseDownLocation: NSPoint?
  private var windowOriginAtMouseDown: NSPoint?
  private var didDrag = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownLocation = NSEvent.mouseLocation
    windowOriginAtMouseDown = window?.frame.origin
    didDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mouseDownLocation, let windowOriginAtMouseDown else { return }
    let currentLocation = NSEvent.mouseLocation
    let deltaX = currentLocation.x - mouseDownLocation.x
    let deltaY = currentLocation.y - mouseDownLocation.y
    if MeetingBubbleInteractionPolicy.isDrag(deltaX: deltaX, deltaY: deltaY) {
      didDrag = true
    }
    guard didDrag else { return }
    window?.setFrameOrigin(NSPoint(
      x: windowOriginAtMouseDown.x + deltaX,
      y: windowOriginAtMouseDown.y + deltaY
    ))
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      mouseDownLocation = nil
      windowOriginAtMouseDown = nil
      didDrag = false
    }
    if !didDrag {
      onRestore?()
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func accessibilityPerformPress() -> Bool {
    onRestore?()
    return true
  }
}

private struct MeetingOverlayView: View {
  private enum Tab: Hashable {
    case transcript
    case context
    case notes
  }

  @ObservedObject var coordinator: MeetingCoordinator
  @State private var selectedTab: Tab = .transcript

  var body: some View {
    VStack(spacing: 0) {
      if let session = coordinator.activeSession {
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
              Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
              Text(
                MeetingTranscriptFormatter.timestamp(
                  context.date.timeIntervalSince(session.startedAt)
                )
              )
              .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
          }
          Button {
            coordinator.minimizeMeetingOverlayForCurrentSession()
          } label: {
            Image(systemName: "minus")
              .font(.system(size: 12, weight: .semibold))
              .frame(width: 30, height: 30)
              .background(Color.primary.opacity(0.065), in: Circle())
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .help("Minimize meeting companion")
          Button {
            Task { await coordinator.stopMeeting() }
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
              Text(coordinator.isStopping ? "Stopping" : "Stop")
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.red.opacity(0.11), in: Capsule(style: .continuous))
            .overlay {
              Capsule(style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
          }
          .buttonStyle(.plain)
          .disabled(coordinator.isStopping)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.025))

        Divider()

        Picker("View", selection: $selectedTab) {
          Text("Transcript").tag(Tab.transcript)
          Text("Context").tag(Tab.context)
          Text("Notes").tag(Tab.notes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if selectedTab == .transcript {
          transcript(session)
        } else if selectedTab == .context {
          context
        } else {
          notes(session)
        }
      } else {
        ContentUnavailableView("No active meeting", systemImage: "person.2.slash")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func transcript(_ session: MeetingSession) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          let blocks = MeetingTranscriptFormatter.blocks(tokens: session.transcriptTokens)
          let previewSources = MeetingAudioSource.allCases.filter {
            !(coordinator.liveTranscriptPreviews[$0] ?? "").isEmpty
          }
          if blocks.isEmpty, previewSources.isEmpty {
            Text("Listening…")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(blocks) { block in
            VStack(alignment: .leading, spacing: 3) {
              Text("\(block.displayName) • \(MeetingTranscriptFormatter.timestamp(block.startTime))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(block.source == .microphone ? .blue : .purple)
              Text(block.text)
                .textSelection(.enabled)
            }
            .id(block.id)
          }
          ForEach(previewSources, id: \.self) { source in
            VStack(alignment: .leading, spacing: 3) {
              Text("\(source.displayName) • Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(source == .microphone ? .blue : .purple)
              Text(coordinator.liveTranscriptPreviews[source] ?? "")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .id("live-\(source.rawValue)")
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
      }
      .onChange(of: session.transcriptTokens.count) { _, _ in
        guard let last = MeetingTranscriptFormatter.blocks(
          tokens: session.transcriptTokens
        ).last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
      }
      .onChange(of: coordinator.liveTranscriptPreviews) { _, previews in
        guard let source = MeetingAudioSource.allCases.last(where: {
          !(previews[$0] ?? "").isEmpty
        }) else { return }
        proxy.scrollTo("live-\(source.rawValue)", anchor: .bottom)
      }
    }
  }

  private var context: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if !coordinator.liveObsidianContextEnabled {
          ContentUnavailableView(
            "Live context is off",
            systemImage: "books.vertical",
            description: Text("Enable it in Meetings to search your Obsidian vault.")
          )
        } else if coordinator.obsidianVaultPath == nil {
          ContentUnavailableView(
            "No Obsidian vault selected",
            systemImage: "folder.badge.questionmark",
            description: Text("Choose your vault in the Meetings sidebar.")
          )
        } else if coordinator.contextCards.isEmpty {
          HStack(spacing: 8) {
            if coordinator.isContextSearching {
              ProgressView()
                .controlSize(.small)
            }
            Text(coordinator.contextStatus)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if coordinator.isContextSearching {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(coordinator.contextStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let error = coordinator.contextError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(coordinator.contextCards) { card in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
              Text(card.term)
                .font(.headline)
              Spacer()
              if let externalURL = card.externalURL {
                Button("Open ticket ↗") {
                  NSWorkspace.shared.open(externalURL)
                }
                .controlSize(.small)
              }
            }
            Text(card.summary)
              .font(.callout)
              .textSelection(.enabled)
            if !card.matches.isEmpty {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 6)],
                alignment: .leading,
                spacing: 6
              ) {
                ForEach(card.matches) { match in
                  Button {
                    MeetingObsidianExporter.open(URL(fileURLWithPath: match.path))
                  } label: {
                    Label(match.title, systemImage: "doc.text")
                      .font(.caption)
                      .lineLimit(1)
                      .padding(.horizontal, 7)
                      .padding(.vertical, 4)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .background(.quaternary.opacity(0.55), in: Capsule())
                  }
                  .buttonStyle(.plain)
                  .help(match.path)
                }
              }
            }
          }
          .padding(10)
          .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 14)
    }
  }

  private func notes(_ session: MeetingSession) -> some View {
    MeetingManualNotesView(coordinator: coordinator, session: session)
  }
}

private struct MeetingManualNotesView: View {
  @ObservedObject var coordinator: MeetingCoordinator
  let session: MeetingSession
  @State private var draft = ""
  @FocusState private var editorIsFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text("Jot down decisions, owners, follow-ups…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 11)
            .allowsHitTesting(false)
        }
        TextEditor(text: $draft)
          .font(.body)
          .focused($editorIsFocused)
          .scrollContentBackground(.hidden)
          .padding(4)
          .disabled(coordinator.isStopping)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 14)
    .onChange(of: session.id, initial: true) { _, _ in
      draft = session.manualNotesMarkdown ?? ""
    }
    .onChange(of: session.manualNotesMarkdown) { _, notes in
      guard !editorIsFocused else { return }
      draft = notes ?? ""
    }
    .onChange(of: draft) { _, notes in
      coordinator.updateManualNotes(notes, for: session.id)
    }
    .onChange(of: editorIsFocused) { wasFocused, isFocused in
      if wasFocused && !isFocused {
        coordinator.commitManualNotes(for: session.id)
      }
    }
    .onDisappear {
      coordinator.commitManualNotes(for: session.id)
    }
  }
}

private struct MeetingAutoStartToastView: View {
  let appName: String
  let onDiscard: () -> Void
  let onKeep: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "record.circle.fill")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.red)
        .font(.title3)
      VStack(alignment: .leading, spacing: 2) {
        Text("Recording meeting")
          .font(.callout.weight(.semibold))
        Text(appName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Discard", role: .destructive, action: onDiscard)
        .controlSize(.small)
      Button("Keep", action: onKeep)
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    }
  }
}
