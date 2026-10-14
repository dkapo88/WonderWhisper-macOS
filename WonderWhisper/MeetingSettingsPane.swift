import SwiftUI

/// Settings → Meetings: transcription, detection, trigger apps, AI notes, live context,
/// companion, Obsidian export, and webhooks. Replaces the collapsible footer under the meeting
/// list.
struct MeetingSettingsPane: View {
  @ObservedObject var coordinator: MeetingCoordinator
  let favoriteModels: [FavoriteOpenRouterModel]
  @State private var customTriggerBundleID = ""
  @State private var showingSummaryPromptEditor = false
  @State private var summaryPromptDraft = ""
  @State private var webhookEditorTarget: WebhookEditorTarget?

  var body: some View {
    SettingsPage {
      transcriptionSection
      detectionSection
      triggerAppsSection
      notesSection
      liveContextSection
      obsidianSection
      webhooksSection
      if !coordinator.webhooks.deliveries.isEmpty {
        recentDeliveriesSection
      }
    }
    .onAppear { coordinator.refreshLiveMicrophoneApplications() }
    .sheet(isPresented: $showingSummaryPromptEditor) {
      MeetingSummaryPromptEditor(
        prompt: $summaryPromptDraft,
        onCancel: { showingSummaryPromptEditor = false },
        onSave: {
          coordinator.notePrompt = MeetingNoteGenerator.resolvedPrompt(summaryPromptDraft)
          showingSummaryPromptEditor = false
        }
      )
    }
    .sheet(item: $webhookEditorTarget) { target in
      MeetingWebhookEditorSheet(
        webhooks: coordinator.webhooks,
        endpoint: target.endpoint,
        onClose: { webhookEditorTarget = nil }
      )
    }
  }

  // MARK: - Transcription

  private var transcriptionSection: some View {
    Section {
      Picker(selection: $coordinator.transcriptionEngine) {
        ForEach(MeetingTranscriptionEngine.allCases) { engine in
          Text(engine.displayName).tag(engine)
        }
      } label: {
        Text("Engine")
        Text(coordinator.transcriptionEngine.detail)
      }
      .disabled(coordinator.activeSessionID != nil || coordinator.isStarting)

      if coordinator.transcriptionEngine.usesSoniox {
        LabeledContent("Soniox") {
          if coordinator.hasSonioxAPIKey {
            StatusBadge(.ok, sonioxCostText)
          } else {
            StatusBadge(.warning, "Add a Soniox key in Settings → Transcription")
          }
        }
      }
    } header: {
      Text("Transcription")
    } footer: {
      if coordinator.activeSessionID != nil {
        Text("The engine can't change while a meeting is recording.")
          .settingsFootnote()
      }
    }
  }

  private var sonioxCostText: String {
    coordinator.transcriptionEngine == .soniox
      ? "Key saved, about $0.12 per meeting hour"
      : "Key saved, about $0.24 per meeting hour"
  }

  // MARK: - Detection

  private var detectionSection: some View {
    Section {
      Toggle(isOn: $coordinator.automaticDetectionEnabled) {
        Text("Start automatically when a call begins")
        Text("Watches the trigger apps below for an active call.")
      }
      Toggle(isOn: $coordinator.meetingOverlayEnabled) {
        Text("Show meeting companion")
        Text("Floating transcript, context, and notes window while recording.")
      }
    } header: {
      Text("Detection")
    } footer: {
      Text("Manual meetings capture your microphone and all Mac audio. Automatic meetings only "
        + "capture system audio from the detected call app.")
        .settingsFootnote()
    }
  }

  private var triggerAppsSection: some View {
    Section {
      ForEach(coordinator.triggerRules) { rule in
        LabeledContent {
          Button {
            coordinator.removeTriggerRule(rule)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove \(rule.displayName)")
          .accessibilityLabel("Remove \(rule.displayName)")
        } label: {
          Text(rule.displayName)
          Text("\(triggerModeLabel(rule.detectionMode)) · \(rule.bundleIDPrefix)")
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      ForEach(availableMicrophoneApplications) { application in
        LabeledContent {
          Button("Add") { coordinator.addTriggerApplication(application) }
            .accessibilityLabel("Add \(application.name)")
        } label: {
          Text(application.name)
          Text("Using the microphone now · \(application.bundleID)")
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          TextField("Bundle ID", text: $customTriggerBundleID, prompt: Text("com.example.app"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .onSubmit(addCustomBundleID)
          Button("Add", action: addCustomBundleID)
            .disabled(trimmedCustomBundleID.isEmpty)
            .accessibilityLabel("Add bundle ID")
        }
      } label: {
        Text("Add by bundle ID")
      }

      HStack {
        Spacer()
        Button("Restore Defaults") { coordinator.restoreDefaultTriggerRules() }
      }
    } header: {
      HStack {
        Text("Trigger apps")
        Spacer()
        Button {
          coordinator.refreshLiveMicrophoneApplications()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Look for apps using the microphone now")
        .accessibilityLabel("Refresh apps using the microphone")
      }
    } footer: {
      Text("Google Meet browsers still need an active Meet window, and Slack needs a Huddle. "
        + "Other apps start a meeting when they use the microphone.")
        .settingsFootnote()
    }
  }

  private var availableMicrophoneApplications: [MeetingMicrophoneApplication] {
    coordinator.liveMicrophoneApplications.filter {
      !coordinator.isTriggerApplicationConfigured($0)
    }
  }

  private var trimmedCustomBundleID: String {
    customTriggerBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func addCustomBundleID() {
    guard !trimmedCustomBundleID.isEmpty else { return }
    coordinator.addTriggerBundleID(trimmedCustomBundleID)
    customTriggerBundleID = ""
  }

  private func triggerModeLabel(_ mode: MeetingTriggerRule.DetectionMode) -> String {
    switch mode {
    case .slackHuddle: return "Huddle detection"
    case .googleMeet: return "Google Meet detection"
    case .microphone: return "Microphone activity"
    }
  }

  // MARK: - AI

  private var notesSection: some View {
    Section {
      Toggle(isOn: $coordinator.generateMeetingNotes) {
        Text("Generate notes after each meeting")
        Text("Writes a summary with OpenRouter when the meeting ends.")
      }
      if coordinator.generateMeetingNotes {
        ModelPickerRow(
          title: "Summary model",
          selection: $coordinator.noteModel,
          favoriteModels: favoriteModels
        )
        LabeledContent {
          Button("Edit…") {
            summaryPromptDraft = coordinator.notePrompt
            showingSummaryPromptEditor = true
          }
          .accessibilityLabel("Edit meeting summary prompt")
        } label: {
          Text("Summary prompt")
          Text("Structure and emphasis of generated notes.")
        }
      }
    } header: {
      Text("AI notes")
    } footer: {
      Text("When on, the finished transcript and your manual notes are sent to OpenRouter.")
        .settingsFootnote()
    }
  }

  private var liveContextSection: some View {
    Section {
      Toggle(isOn: $coordinator.liveObsidianContextEnabled) {
        Text("Search Obsidian during meetings")
        Text("Surfaces related notes from your vault in the companion.")
      }
      if coordinator.liveObsidianContextEnabled {
        ModelPickerRow(
          title: "Context model",
          selection: $coordinator.contextModel,
          favoriteModels: favoriteModels
        )
      }
    } header: {
      Text("Live context")
    } footer: {
      Text("The vault is searched locally. A short recent transcript window and matching note "
        + "excerpts are sent to OpenRouter.")
        .settingsFootnote()
    }
  }

  // MARK: - Obsidian

  private var obsidianSection: some View {
    Section {
      FolderPickerRow(
        title: "Vault",
        path: coordinator.obsidianVaultPath,
        placeholder: "No vault selected",
        showsClear: coordinator.obsidianVaultPath != nil,
        clearTitle: "Clear Vault and Export Folder",
        onChoose: coordinator.chooseObsidianVault,
        onClear: coordinator.clearObsidianVault
      )
      FolderPickerRow(
        title: "Export folder",
        path: coordinator.effectiveObsidianExportFolderPath,
        placeholder: coordinator.obsidianVaultPath == nil
          ? "Choose a vault first"
          : "Vault root",
        canChoose: coordinator.obsidianVaultPath != nil,
        showsClear: coordinator.obsidianExportFolderPath != nil,
        clearTitle: "Use Vault Root",
        onChoose: coordinator.chooseObsidianExportFolder,
        onClear: coordinator.clearObsidianExportFolder
      )
      Toggle(isOn: $coordinator.automaticallyExportToObsidian) {
        Text("Export automatically")
        Text("Saves each finished meeting as a Markdown note.")
      }
    } header: {
      Text("Obsidian")
    }
  }

  // MARK: - Webhooks

  private var webhooksSection: some View {
    Section {
      ForEach(coordinator.webhooks.endpoints) { endpoint in
        webhookRow(endpoint)
      }
      HStack {
        Spacer()
        Button("Add Webhook…") {
          webhookEditorTarget = WebhookEditorTarget(endpoint: nil)
        }
      }
    } header: {
      Text("Webhooks")
    } footer: {
      Text("When a meeting note finishes, WonderWhisper POSTs it as JSON (the same Markdown as "
        + "the Obsidian export) to every enabled webhook, retrying up to 5 times. Endpoints and "
        + "their Keychain secrets stay on this Mac.")
        .settingsFootnote()
    }
  }

  private func webhookRow(_ endpoint: MeetingWebhookEndpoint) -> some View {
    LabeledContent {
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        Button("Send Test") { coordinator.webhooks.sendTest(to: endpoint.id) }
          .accessibilityLabel("Send a test to \(endpoint.displayName)")
        Button("Edit…") {
          webhookEditorTarget = WebhookEditorTarget(endpoint: endpoint)
        }
        .accessibilityLabel("Edit \(endpoint.displayName)")
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { endpoint.isEnabled },
            set: { coordinator.webhooks.setEnabled($0, for: endpoint.id) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Enable \(endpoint.displayName)")
      }
    } label: {
      Text(endpoint.displayName)
      Text(endpoint.url)
        .lineLimit(1)
        .truncationMode(.middle)
      if let record = coordinator.webhooks.latestRecord(forEndpoint: endpoint.id) {
        webhookResult(record)
      }
    }
  }

  @ViewBuilder
  private func webhookResult(_ record: MeetingWebhookDeliveryRecord) -> some View {
    let prefix = record.event == .test ? "Test: " : ""
    let text = prefix + MeetingWebhookStatusFormatter.text(for: record)
    switch record.state {
    case .delivered:
      StatusBadge(.ok, text)
    case .failed:
      StatusBadge(.error, text)
    case .sending, .retrying:
      StatusBadge(.neutral, text)
    }
  }

  private var recentDeliveriesSection: some View {
    Section {
      DisclosureGroup("Recent deliveries") {
        ForEach(coordinator.webhooks.deliveries.prefix(25)) { record in
          LabeledContent {
            if record.state == .failed {
              Button("Retry") { coordinator.retryWebhookDelivery(record) }
                .accessibilityLabel("Retry \(record.noteTitle)")
            }
          } label: {
            Text(record.event == .test ? "Test delivery" : record.noteTitle)
              .lineLimit(1)
            webhookResult(record)
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
          }
        }
      }
    } footer: {
      Text("Only delivery results are kept, never the note content, secrets or header values.")
        .settingsFootnote()
    }
  }
}

/// Which endpoint the webhook editor sheet is showing; nil endpoint means a new one.
private struct WebhookEditorTarget: Identifiable {
  let id = UUID()
  let endpoint: MeetingWebhookEndpoint?
}
