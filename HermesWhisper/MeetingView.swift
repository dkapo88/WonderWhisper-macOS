import SwiftUI

struct MeetingView: View {
  @ObservedObject var coordinator: MeetingCoordinator
  @State private var manualTitle = ""
  @State private var sessionPendingDeletion: MeetingSession?
  @State private var showingTriggerApps = false
  @State private var customTriggerBundleID = ""
  @State private var settingsExpanded = false

  var body: some View {
    HSplitView {
      sidebar
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      recordingControls
        .padding(16)

      Divider()

      List(selection: $coordinator.selectedSessionID) {
        ForEach(coordinator.sessions) { session in
          MeetingRow(session: session)
            .tag(session.id)
        }
      }
      .listStyle(.sidebar)

      Divider()

      DisclosureGroup("Meeting settings", isExpanded: $settingsExpanded) {
        ScrollView {
          settings
            .padding(.top, 8)
        }
        .frame(maxHeight: 280)
      }
      .font(.callout)
      .padding(14)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var recordingControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Circle()
          .fill(coordinator.activeSessionID == nil ? Color.secondary : Color.red)
          .frame(width: 8, height: 8)
        Text(coordinator.isLoadingSessions ? "Loading meetings…" : coordinator.statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      if coordinator.activeSessionID == nil {
        TextField("Optional meeting title", text: $manualTitle)
          .textFieldStyle(.roundedBorder)

        Button {
          let title = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          Task {
            await coordinator.startManualMeeting(title: title.isEmpty ? nil : title)
            if coordinator.activeSessionID != nil {
              manualTitle = ""
            }
          }
        } label: {
          Label("Start meeting", systemImage: "record.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          coordinator.isLoadingSessions || coordinator.isStarting || coordinator.isStopping
        )
      } else {
        Button(role: .destructive) {
          Task { await coordinator.stopMeeting() }
        } label: {
          Label("Stop meeting", systemImage: "stop.circle.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(coordinator.isStopping)
      }

      if let error = coordinator.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("Meeting transcription", selection: $coordinator.transcriptionEngine) {
        ForEach(MeetingTranscriptionEngine.allCases) { engine in
          Text(engine.displayName).tag(engine)
        }
      }
      .disabled(coordinator.activeSessionID != nil || coordinator.isStarting)

      Text(coordinator.transcriptionEngine.detail)
        .font(.caption2)
        .foregroundStyle(.secondary)

      if coordinator.transcriptionEngine == .soniox {
        HStack(spacing: 5) {
          Image(systemName: coordinator.hasSonioxAPIKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
          Text(
            coordinator.hasSonioxAPIKey
              ? "Soniox key saved • approximately $0.24 per meeting hour for two streams"
              : "Add a Soniox API key in Settings before recording"
          )
        }
        .font(.caption2)
        .foregroundStyle(coordinator.hasSonioxAPIKey ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Toggle("Detect meetings", isOn: $coordinator.automaticDetectionEnabled)
        Spacer(minLength: 0)
        Button("Apps…") {
          showingTriggerApps = true
        }
        .controlSize(.small)
        .popover(isPresented: $showingTriggerApps) {
          triggerAppsPopover
        }
      }
      Toggle("Generate notes with OpenRouter", isOn: $coordinator.generateMeetingNotes)
      Toggle(
        "Live Obsidian context via OpenRouter",
        isOn: $coordinator.liveObsidianContextEnabled
      )
      Toggle("Show meeting companion", isOn: $coordinator.meetingOverlayEnabled)
      Toggle("Auto-export to Obsidian", isOn: $coordinator.automaticallyExportToObsidian)

      Text(
        "Manual meetings capture your microphone and all Mac audio. Automatic meetings limit "
          + "system audio to the detected call app. Live context extracts useful subjects, "
          + "searches the vault locally, and sends a bounded recent transcript window plus "
          + "bounded matching note excerpts to OpenRouter."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if coordinator.generateMeetingNotes {
        CommittedModelField("Final notes model", value: $coordinator.noteModel)
      }

      if coordinator.liveObsidianContextEnabled {
        CommittedModelField(
          "Fast live-context model",
          value: $coordinator.contextModel
        )
      }

      HStack(spacing: 8) {
        Button("Choose Obsidian folder") {
          coordinator.chooseObsidianFolder()
        }
        .controlSize(.small)

        if coordinator.obsidianFolderPath != nil {
          Button {
            coordinator.clearObsidianFolder()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Clear Obsidian folder")
        }
      }

      Text(coordinator.obsidianFolderPath ?? "No Obsidian folder selected")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
    }
  }

  private var triggerAppsPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Automatic meeting apps")
        .font(.headline)
      Text(
        "Meet browsers still require an active Google Meet window. Slack requires a Huddle. "
          + "Other apps start only when that app uses the microphone."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ForEach(coordinator.triggerRules) { rule in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 1) {
            Text(rule.displayName)
              .font(.callout.weight(.medium))
            Text("\(rule.bundleIDPrefix) • \(triggerModeLabel(rule.detectionMode))")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          Button {
            coordinator.removeTriggerRule(rule)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .help("Remove \(rule.displayName)")
        }
      }

      Divider()

      let availableApplications = coordinator.liveMicrophoneApplications.filter {
        !coordinator.isTriggerApplicationConfigured($0)
      }
      if availableApplications.isEmpty {
        Text("Apps currently using the microphone will appear here for one-click adding.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Using the microphone now")
          .font(.caption.weight(.semibold))
        ForEach(availableApplications) { application in
          HStack(spacing: 8) {
            Text("\(application.name) — \(application.bundleID)")
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button("Add") {
              coordinator.addTriggerApplication(application)
            }
            .controlSize(.small)
          }
        }
      }

      HStack(spacing: 7) {
        TextField("Bundle ID", text: $customTriggerBundleID)
          .textFieldStyle(.roundedBorder)
        Button("Add") {
          coordinator.addTriggerBundleID(customTriggerBundleID)
          customTriggerBundleID = ""
        }
        .controlSize(.small)
        .disabled(
          customTriggerBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }

      HStack {
        Spacer()
        Button("Restore defaults") {
          coordinator.restoreDefaultTriggerRules()
        }
        .controlSize(.small)
      }
    }
    .padding(14)
    .frame(width: 390)
  }

  private func triggerModeLabel(
    _ mode: MeetingTriggerRule.DetectionMode
  ) -> String {
    switch mode {
    case .slackHuddle: return "Huddle detection"
    case .googleMeet: return "Google Meet detection"
    case .microphone: return "Microphone activity"
    }
  }

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
        onExport: { Task { await coordinator.exportToObsidian(session) } },
        onOpenExport: { coordinator.openExportedNote(session) },
        onCopyMarkdown: { coordinator.copyMarkdown(session) },
        onRevealAudio: { Task { await coordinator.revealAudio(session) } },
        onDelete: { sessionPendingDeletion = session }
      )
    } else {
      ContentUnavailableView(
        "No meetings yet",
        systemImage: "person.2.wave.2",
        description: Text("Start a recording or enable automatic meeting detection.")
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
          .font(.callout.weight(.medium))
          .lineLimit(1)
      }
      Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}

private struct CommittedModelField: View {
  let title: String
  @Binding var value: String
  @State private var draft: String
  @FocusState private var isFocused: Bool

  init(_ title: String, value: Binding<String>) {
    self.title = title
    self._value = value
    self._draft = State(initialValue: value.wrappedValue)
  }

  var body: some View {
    TextField(title, text: $draft)
      .textFieldStyle(.roundedBorder)
      .font(.caption)
      .focused($isFocused)
      .onSubmit(commit)
      .onChange(of: isFocused) { wasFocused, focused in
        if wasFocused && !focused {
          commit()
        }
      }
      .onChange(of: value) { _, updatedValue in
        if !isFocused {
          draft = updatedValue
        }
      }
  }

  private func commit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      draft = value
      return
    }
    draft = trimmed
    value = trimmed
  }
}

private struct MeetingDetailView: View {
  let session: MeetingSession
  let isActive: Bool
  let livePreviews: [MeetingAudioSource: String]
  let onTitleChange: (String) -> Void
  let onExport: () -> Void
  let onOpenExport: () -> Void
  let onCopyMarkdown: () -> Void
  let onRevealAudio: () -> Void
  let onDelete: () -> Void
  @State private var titleDraft = ""
  @FocusState private var titleIsFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(22)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            if let notes = session.notesMarkdown, !notes.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Label("Meeting notes", systemImage: "doc.text.fill")
                  .font(.headline)
                HermesMarkdownView(text: notes)
              }
              .padding(16)
              .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }

            Label("Transcript", systemImage: "captions.bubble.fill")
              .font(.headline)

            let blocks = MeetingTranscriptFormatter.blocks(tokens: session.transcriptTokens)
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
          .padding(22)
        }
        .onChange(of: session.transcriptTokens.count) { _, _ in
          guard let last = MeetingTranscriptFormatter.blocks(
            tokens: session.transcriptTokens
          ).last else { return }
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
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        TextField(
          "Meeting title",
          text: $titleDraft
        )
        .textFieldStyle(.plain)
        .font(.title2.weight(.semibold))
        .focused($titleIsFocused)
        .onSubmit(commitTitle)
        .onChange(of: titleIsFocused) { wasFocused, isFocused in
          if wasFocused && !isFocused {
            commitTitle()
          }
        }

        Spacer()

        if !isActive, session.status.isTerminal {
          Button(action: onCopyMarkdown) {
            Image(systemName: "doc.on.doc")
          }
          .help("Copy meeting as Markdown")

          Button(action: onRevealAudio) {
            Image(systemName: "waveform.path.badge.plus")
          }
          .help("Reveal retained meeting audio")

          if let exportedPath = session.exportedMarkdownPath,
             FileManager.default.fileExists(atPath: exportedPath) {
            Button("Open in Obsidian", action: onOpenExport)
          }
          Button(
            session.exportedMarkdownPath == nil ? "Export" : "Re-export",
            action: onExport
          )

          Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
          }
          .help("Delete meeting")
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
      .font(.caption)
      .foregroundStyle(.secondary)

      if let error = session.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
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
        Text(block.source.displayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(block.source == .microphone ? .blue : .purple)
        Text(MeetingTranscriptFormatter.timestamp(block.startTime))
          .font(.caption2.monospacedDigit())
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
        .font(.caption.weight(.semibold))
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
