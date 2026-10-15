import SwiftUI

/// Meetings: a list of recorded meetings and the selected meeting's transcript. Recording
/// controls live in the window toolbar; all configuration is in Settings → Meetings.
struct MeetingView: View {
  @ObservedObject var coordinator: MeetingCoordinator
  @State private var sessionPendingDeletion: MeetingSession?

  var body: some View {
    HSplitView {
      sidebar
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar { toolbarContent }
    .alert(
      "Delete meeting?",
      isPresented: Binding(
        get: { sessionPendingDeletion != nil },
        set: { if !$0 { sessionPendingDeletion = nil } }
      ),
      presenting: sessionPendingDeletion
    ) { session in
      Button("Delete", role: .destructive) {
        Task { await coordinator.delete(session) }
        sessionPendingDeletion = nil
      }
      Button("Cancel", role: .cancel) {
        sessionPendingDeletion = nil
      }
    } message: { session in
      Text("This removes \(session.title), its transcript, and its locally stored audio.")
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: $coordinator.automaticDetectionEnabled) {
        Label(
          "Auto-detect",
          systemImage: coordinator.automaticDetectionEnabled
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
        )
        .labelStyle(.titleAndIcon)
      }
      .toggleStyle(.button)
      .help(
        coordinator.automaticDetectionEnabled
          ? "Automatic meeting detection is on"
          : "Automatic meeting detection is off"
      )
      .accessibilityLabel("Automatic meeting detection")

      Button {
        SettingsRouter.shared.show(.meetings)
      } label: {
        Label("Meeting Settings", systemImage: "gearshape")
      }
      .help("Meeting settings")

      recordButton
    }
  }

  @ViewBuilder private var recordButton: some View {
    if coordinator.activeSessionID == nil {
      Button {
        Task { await coordinator.startManualMeeting() }
      } label: {
        Label("Start Meeting", systemImage: "record.circle")
          .labelStyle(.titleAndIcon)
      }
      .disabled(coordinator.isLoadingSessions || coordinator.isStarting || coordinator.isStopping)
      .help("Record your microphone and all Mac audio")
    } else {
      Button(role: .destructive) {
        Task { await coordinator.stopMeeting() }
      } label: {
        Label("Stop Meeting", systemImage: "stop.circle.fill")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.red)
      }
      .disabled(coordinator.isStopping)
      .help("Stop recording this meeting")
    }
  }

  // MARK: - List

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      statusRow
        .padding(.horizontal, DesignTokens.Spacing.small)
        .padding(.vertical, DesignTokens.Spacing.xSmall)

      Divider()

      if coordinator.sessions.isEmpty && !coordinator.isLoadingSessions {
        ContentUnavailableView(
          "No meetings yet",
          systemImage: "person.2",
          description: Text("Start a meeting from the toolbar or turn on auto-detect.")
        )
        .frame(maxHeight: .infinity)
      } else {
        List(selection: $coordinator.selectedSessionID) {
          ForEach(coordinator.sessions) { session in
            MeetingRow(session: session)
              .tag(session.id)
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var statusRow: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
      HStack(spacing: 6) {
        Circle()
          .fill(coordinator.activeSessionID == nil ? Color.secondary : Color.red)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
        Text(coordinator.isLoadingSessions ? "Loading meetings…" : coordinator.statusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)

      if let error = coordinator.lastError {
        StatusBadge(.warning, error)
          .font(.footnote)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let session = coordinator.selectedSession {
      MeetingDetailView(
        session: session,
        isActive: session.id == coordinator.activeSessionID,
        livePreviews: session.id == coordinator.activeSessionID
          ? coordinator.liveTranscriptPreviews
          : [:],
        onTitleChange: { coordinator.updateTitle($0, for: session.id) },
        onAttendeesChange: { coordinator.updateAttendees($0, for: session.id) },
        canResume: coordinator.canResumeMeeting(session),
        onResume: { Task { await coordinator.resumeMeeting(session) } },
        isGeneratingNotes: coordinator.noteGenerationSessionIDs.contains(session.id),
        onRegenerateNotes: { Task { await coordinator.regenerateNotes(for: session) } },
        onExport: { Task { await coordinator.exportToObsidian(session) } },
        onOpenExport: { coordinator.openExportedNote(session) },
        onCopyMarkdown: { coordinator.copyMarkdown(session) },
        onRevealAudio: { Task { await coordinator.revealAudio(session) } },
        onDelete: { sessionPendingDeletion = session },
        webhookEndpoints: coordinator.webhooks.enabledEndpoints,
        canSendToWebhooks: coordinator.canSendToWebhooks(session),
        onSendToWebhook: { coordinator.sendToWebhooks(session, endpointID: $0) },
        webhookRecords: coordinator.webhooks.latestRecords(forNote: session.id),
        onRetryWebhook: { coordinator.retryWebhookDelivery($0) },
        canResendWebhookParts: { coordinator.canResendWebhookParts(session, endpointID: $0) },
        webhookPartTotal: {
          coordinator.webhooks.resumableSend(noteID: session.id, endpointID: $0)?.total
        },
        onResendMissingParts: {
          coordinator.resendWebhookParts(session, endpointID: $0, selection: .missing)
        },
        onResendParts: { coordinator.resendWebhookParts(session, endpointID: $0, partsText: $1) }
      )
    } else {
      ContentUnavailableView(
        "No meeting selected",
        systemImage: "person.2",
        description: Text("Select a meeting to see its transcript and notes.")
      )
    }
  }
}

private struct MeetingRow: View {
  let session: MeetingSession

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if session.status == .recording || session.status == .processing {
          Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
        }
        Text(session.title)
          .lineLimit(1)
      }
      Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, DesignTokens.Spacing.xxSmall)
    .accessibilityElement(children: .combine)
  }
}

private struct MeetingDetailView: View {
  private static let topAnchorID = "meeting-detail-top"

  let session: MeetingSession
  let isActive: Bool
  let livePreviews: [MeetingAudioSource: String]
  let onTitleChange: (String) -> Void
  let onAttendeesChange: (String) -> Void
  let canResume: Bool
  let onResume: () -> Void
  let isGeneratingNotes: Bool
  let onRegenerateNotes: () -> Void
  let onExport: () -> Void
  let onOpenExport: () -> Void
  let onCopyMarkdown: () -> Void
  let onRevealAudio: () -> Void
  let onDelete: () -> Void
  let webhookEndpoints: [MeetingWebhookEndpoint]
  let canSendToWebhooks: Bool
  let onSendToWebhook: (UUID?) -> Void
  let webhookRecords: [MeetingWebhookDeliveryRecord]
  let onRetryWebhook: (MeetingWebhookDeliveryRecord) -> Void
  let canResendWebhookParts: (UUID) -> Bool
  let webhookPartTotal: (UUID) -> Int?
  let onResendMissingParts: (UUID) -> Void
  let onResendParts: (UUID, String) -> Void
  @State private var titleDraft = ""
  @FocusState private var titleIsFocused: Bool
  @State private var attendeesDraft = ""
  @FocusState private var attendeesAreFocused: Bool
  @State private var partsPromptEndpoint: MeetingWebhookEndpoint?
  @State private var partsDraft = ""

  var body: some View {
    let blocks = MeetingTranscriptFormatter.blocks(tokens: session.transcriptTokens)
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(DesignTokens.Spacing.large)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Color.clear
              .frame(height: 0)
              .id(Self.topAnchorID)

            if let manualNotes = session.manualNotesMarkdown,
               !manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Label("Manual notes", systemImage: "square.and.pencil")
                  .font(.headline)
                HermesMarkdownView(text: manualNotes)
              }
              .padding(DesignTokens.Spacing.medium)
              .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            }

            if let notes = session.notesMarkdown, !notes.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Label("Generated summary", systemImage: "doc.text.fill")
                  .font(.headline)
                HermesMarkdownView(text: notes)
              }
              .padding(DesignTokens.Spacing.medium)
              .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            }

            Label("Transcript", systemImage: "captions.bubble.fill")
              .font(.headline)

            let previewSources = MeetingAudioSource.allCases.filter {
              !(livePreviews[$0] ?? "").isEmpty
            }
            if blocks.isEmpty, previewSources.isEmpty {
              Text(isActive ? "Listening…" : "No transcript was captured.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(blocks) { block in
                transcriptBlock(block)
                  .id(block.id)
              }
            }
            ForEach(previewSources, id: \.self) { source in
              transcriptPreview(source: source, text: livePreviews[source] ?? "")
                .id("live-\(source.rawValue)")
            }
          }
          .padding(DesignTokens.Spacing.large)
        }
        .onChange(of: session.transcriptTokens.count) { _, _ in
          guard isActive else { return }
          guard let last = blocks.last else { return }
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
        .onChange(of: livePreviews) { _, previews in
          guard let source = MeetingAudioSource.allCases.last(where: {
            !(previews[$0] ?? "").isEmpty
          }) else { return }
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("live-\(source.rawValue)", anchor: .bottom)
          }
        }
        .onChange(of: session.id, initial: true) { _, _ in
          Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
          }
        }
      }
    }
    .onChange(of: session.id, initial: true) { _, _ in
      titleDraft = session.title
    }
    .onChange(of: session.title) { _, title in
      if !titleIsFocused {
        titleDraft = title
      }
    }
    .onChange(of: session.id, initial: true) { _, _ in
      attendeesDraft = MeetingAttendees.text(session.attendees)
    }
    .onChange(of: session.attendees) { _, attendees in
      if !attendeesAreFocused {
        attendeesDraft = MeetingAttendees.text(attendees)
      }
    }
    .alert(
      "Resend parts to \(partsPromptEndpoint?.displayName ?? "webhook")",
      isPresented: Binding(
        get: { partsPromptEndpoint != nil },
        set: { if !$0 { partsPromptEndpoint = nil } }
      )
    ) {
      TextField("Parts", text: $partsDraft, prompt: Text("2,3"))
      Button("Resend") {
        if let endpoint = partsPromptEndpoint {
          onResendParts(endpoint.id, partsDraft)
        }
        partsPromptEndpoint = nil
      }
      Button("Cancel", role: .cancel) { partsPromptEndpoint = nil }
    } message: {
      Text(partsPromptMessage)
    }
  }

  private var partsPromptMessage: String {
    let total = partsPromptEndpoint.flatMap { webhookPartTotal($0.id) }
    let range = total.map { " The last split send had \($0) parts." } ?? ""
    return "Part numbers to send again with the same send ID, for example 3 or 2,3.\(range)"
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          titleField
            .frame(minWidth: 180)

          Spacer()

          if showsTerminalActions {
            terminalActions
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          titleField
          if showsTerminalActions {
            HStack {
              Spacer()
              terminalActions
            }
          }
        }
      }

      HStack(spacing: 12) {
        Label(
          session.startedAt.formatted(date: .abbreviated, time: .shortened),
          systemImage: "calendar"
        )
        Label(durationText, systemImage: "clock")
        if let app = session.detectedApp {
          Label(app, systemImage: "video.fill")
        }
        if session.automaticallyStarted {
          Label("Automatic", systemImage: "bolt.fill")
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)

      attendeesField

      if let error = session.errorMessage {
        StatusBadge(.warning, error)
          .font(.footnote)
      }

      MeetingWebhookStatusList(records: webhookRecords, onRetry: onRetryWebhook)
    }
  }

  private var titleField: some View {
    TextField("Meeting title", text: $titleDraft)
      .textFieldStyle(.plain)
      .font(.title2.weight(.semibold))
      .focused($titleIsFocused)
      .onSubmit(commitTitle)
      .onChange(of: titleIsFocused) { wasFocused, isFocused in
        if wasFocused && !isFocused {
          commitTitle()
        }
      }
  }

  private var attendeesField: some View {
    HStack(spacing: DesignTokens.Spacing.xSmall) {
      Image(systemName: "person.2")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(
        "Attendees",
        text: $attendeesDraft,
        prompt: Text("Attendees, comma separated")
      )
      .textFieldStyle(.plain)
      .focused($attendeesAreFocused)
      .onSubmit(commitAttendees)
      .onChange(of: attendeesAreFocused) { wasFocused, isFocused in
        if wasFocused && !isFocused {
          commitAttendees()
        }
      }
      .accessibilityLabel("Attendees")
    }
    .font(.callout)
  }

  private func commitAttendees() {
    let parsed = MeetingAttendees.parse(attendeesDraft)
    attendeesDraft = MeetingAttendees.text(parsed)
    guard parsed != session.attendees else { return }
    onAttendeesChange(attendeesDraft)
  }

  private var showsTerminalActions: Bool {
    !isActive && session.status.isTerminal
  }

  @ViewBuilder private var terminalActions: some View {
    HStack(spacing: DesignTokens.Spacing.xSmall) {
      Button(action: onResume) {
        Label("Resume Recording", systemImage: "record.circle")
      }
      .disabled(!canResume)
      .help("Continue recording into this meeting and regenerate its summary when done")

      Button(
        session.exportedMarkdownPath == nil ? "Export to Obsidian" : "Re-export",
        action: onExport
      )
      .disabled(isGeneratingNotes)

      Menu {
        Button(
          session.notesMarkdown == nil ? "Retry Summary" : "Regenerate Summary",
          systemImage: "arrow.clockwise",
          action: onRegenerateNotes
        )
        .disabled(isGeneratingNotes)

        Button("Copy as Markdown", systemImage: "doc.on.doc", action: onCopyMarkdown)
          .disabled(isGeneratingNotes)

        if !webhookEndpoints.isEmpty {
          sendToWebhookMenu
        }

        if let exportedPath = session.exportedMarkdownPath,
           FileManager.default.fileExists(atPath: exportedPath) {
          Button("Open in Obsidian", systemImage: "arrow.up.forward.app", action: onOpenExport)
        }

        Button("Show Audio in Finder", systemImage: "waveform", action: onRevealAudio)

        Divider()

        Button("Delete Meeting…", systemImage: "trash", role: .destructive, action: onDelete)
          .disabled(isGeneratingNotes)
      } label: {
        if isGeneratingNotes {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "ellipsis.circle")
        }
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More actions")
      .accessibilityLabel("More meeting actions")
    }
  }

  @ViewBuilder private var sendToWebhookMenu: some View {
    if webhookEndpoints.count == 1, let only = webhookEndpoints.first {
      Button(
        "Send to \(only.displayName)",
        systemImage: "paperplane",
        action: { onSendToWebhook(only.id) }
      )
      .disabled(!canSendToWebhooks)
      if only.splitIntoParts {
        resendPartsButtons(for: only, suffix: " to \(only.displayName)")
      }
    } else {
      Menu {
        Button("All Enabled Webhooks") { onSendToWebhook(nil) }
        Divider()
        ForEach(webhookEndpoints) { endpoint in
          Button(endpoint.displayName) { onSendToWebhook(endpoint.id) }
        }
        ForEach(webhookEndpoints.filter(\.splitIntoParts)) { endpoint in
          Section(endpoint.displayName) {
            resendPartsButtons(for: endpoint, suffix: "")
          }
        }
      } label: {
        Label("Send to Webhook", systemImage: "paperplane")
      }
      .disabled(!canSendToWebhooks)
    }
  }

  /// "Resend Missing Parts" and "Resend Parts..." for a split endpoint: they act on the
  /// note's newest split send to it.
  @ViewBuilder
  private func resendPartsButtons(
    for endpoint: MeetingWebhookEndpoint,
    suffix: String
  ) -> some View {
    let enabled = canResendWebhookParts(endpoint.id)
    Button(
      "Resend Missing Parts\(suffix)",
      systemImage: "arrow.clockwise",
      action: { onResendMissingParts(endpoint.id) }
    )
    .disabled(!enabled)
    Button("Resend Parts\(suffix)…", systemImage: "number") {
      partsDraft = ""
      partsPromptEndpoint = endpoint
    }
    .disabled(!enabled)
  }

  private func commitTitle() {
    let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let committed = trimmed.isEmpty ? "Meeting" : trimmed
    titleDraft = committed
    guard committed != session.title else { return }
    onTitleChange(committed)
  }

  private func transcriptBlock(_ block: MeetingTranscriptBlock) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(block.displayName)
          .font(.callout.weight(.semibold))
          .foregroundStyle(block.source == .microphone ? .blue : .purple)
        Text(MeetingTranscriptFormatter.timestamp(block.startTime))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Text(block.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func transcriptPreview(
    source: MeetingAudioSource,
    text: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("\(source.displayName) • Live")
        .font(.callout.weight(.semibold))
        .foregroundStyle(source == .microphone ? .blue : .purple)
      Text(text)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var durationText: String {
    let minutes = max(0, Int(session.duration / 60))
    if minutes >= 60 {
      return "\(minutes / 60)h \(minutes % 60)m"
    }
    return "\(minutes)m"
  }
}
