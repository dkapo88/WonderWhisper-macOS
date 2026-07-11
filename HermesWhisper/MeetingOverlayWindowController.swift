import AppKit
import Combine
import SwiftUI

@MainActor
final class MeetingOverlayWindowController: NSObject, NSWindowDelegate {
  private let coordinator: MeetingCoordinator
  private let panel: NSPanel
  private var autoStartPanel: NSPanel?
  private var autoStartTask: Task<Void, Never>?
  private var autoStartSessionID: UUID?
  private var cancellables: Set<AnyCancellable> = []

  init(coordinator: MeetingCoordinator) {
    self.coordinator = coordinator
    self.panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
      styleMask: [.borderless, .resizable, .nonactivatingPanel],
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
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentMinSize = NSSize(width: 300, height: 320)
    panel.animationBehavior = .utilityWindow
    panel.delegate = self
    panel.contentView = NSHostingView(
      rootView: MeetingOverlayView(coordinator: coordinator)
    )

    Publishers.CombineLatest3(
      coordinator.$activeSessionID,
      coordinator.$meetingOverlayEnabled,
      coordinator.$overlayHiddenSessionID
    )
      .removeDuplicates { lhs, rhs in
        lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
      }
      .sink { [weak self] sessionID, enabled, hiddenSessionID in
        guard let self else { return }
        if sessionID == nil || !enabled || sessionID == hiddenSessionID {
          self.panel.orderOut(nil)
        } else {
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
  }

  private func show() {
    if !panel.isVisible {
      positionPanel()
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

private struct MeetingOverlayView: View {
  @ObservedObject var coordinator: MeetingCoordinator
  @State private var selectedTab = 0

  var body: some View {
    VStack(spacing: 0) {
      if let session = coordinator.activeSession {
        HStack(spacing: 10) {
          Image(systemName: "record.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
          Text(session.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .help(session.title)
          Spacer()
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(
              MeetingTranscriptFormatter.timestamp(
                context.date.timeIntervalSince(session.startedAt)
              )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
          }
          Button {
            coordinator.hideMeetingOverlayForCurrentSession()
          } label: {
            Image(systemName: "eye.slash")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Hide meeting companion")
          Button {
            Task { await coordinator.stopMeeting() }
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .controlSize(.small)
          .buttonStyle(.bordered)
          .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))

        Divider()

        Picker("View", selection: $selectedTab) {
          Text("Transcript").tag(0)
          Text("Context").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if selectedTab == 0 {
          transcript(session)
        } else {
          context
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
              Text("\(block.source.displayName) • \(MeetingTranscriptFormatter.timestamp(block.startTime))")
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
        } else if coordinator.obsidianFolderPath == nil {
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
