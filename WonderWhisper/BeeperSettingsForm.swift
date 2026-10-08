import SwiftUI

/// Settings → Integrations → Beeper.
struct BeeperSettingsForm: View {
  @ObservedObject var vm: DictationViewModel
  @State private var isTestingConnection = false

  var body: some View {
    SettingsPage {
      connectionSection
      chatsSection
      sendingSection
      repliesSection
      activitySection
    }
  }

  // MARK: - Connection

  private var connectionSection: some View {
    Section {
      Toggle("Enable Beeper voice send", isOn: $vm.beeperEnabled)

      LabeledContent {
        TextField(
          "API URL",
          text: $vm.beeperBaseURLString,
          prompt: Text(AppConfig.defaultBeeperBaseURLString)
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 260)
      } label: {
        Text("API URL")
        Text("Beeper Desktop API usually runs locally on port 23373.")
      }

      APIKeyRow(
        title: "Access token",
        alias: AppConfig.beeperAccessTokenAlias,
        onSave: vm.saveBeeperAccessToken
      )

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.small) {
          if let status = vm.beeperConnectionStatus {
            StatusBadge.connection(vm.beeperConnectionSucceeded, status)
              .textSelection(.enabled)
          }
          Button(action: testConnection) {
            if isTestingConnection {
              ProgressView().controlSize(.small)
            } else {
              Text("Test")
            }
          }
          .disabled(isTestingConnection)
          .accessibilityLabel("Test Beeper connection")
        }
      } label: {
        Text("Connection")
      }
    } header: {
      Text("Beeper")
    } footer: {
      Text("Create a token in Beeper Desktop under Settings → Integrations → Approved "
        + "connections. WonderWhisper only sends to the chats listed below.")
        .settingsFootnote()
    }
  }

  // MARK: - Chats

  private var chatsSection: some View {
    Section {
      if vm.beeperChats.isEmpty {
        Text("No chats yet. Add a chat ID and give it a label.")
          .foregroundStyle(.secondary)
      } else {
        ForEach($vm.beeperChats) { $entry in
          chatRow($entry)
        }
      }
    } header: {
      HStack {
        Text("Chats")
        Spacer()
        Button {
          vm.beeperChats.append(BeeperChatEntry())
        } label: {
          Label("Add Chat", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
    } footer: {
      Text("Checked chats are monitored for replies. The default chat receives new voice "
        + "messages.")
        .settingsFootnote()
    }
  }

  private func chatRow(_ entry: Binding<BeeperChatEntry>) -> some View {
    let chat = entry.wrappedValue
    let isDefault = chat.id == defaultChatEntryID
    let name = chat.alias.isEmpty ? "chat" : chat.alias
    return HStack(spacing: DesignTokens.Spacing.xSmall) {
      Toggle("Monitor \(name)", isOn: entry.isEnabled)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help(chat.isEnabled ? "Monitored. Uncheck to pause." : "Paused.")
        .accessibilityLabel("Monitor \(name)")

      TextField("Label", text: entry.alias, prompt: Text("Label (e.g. Work group)"))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 170)

      TextField("Chat ID", text: entry.chatID, prompt: Text("Chat ID"))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())

      Button {
        makeDefault(chat)
      } label: {
        Image(systemName: isDefault ? "star.fill" : "star")
          .foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.borderless)
      .disabled(!chat.isEnabled || isDefault)
      .help(isDefault ? "Default chat" : "Make default")
      .accessibilityLabel(isDefault ? "\(name) is the default chat" : "Make \(name) default")

      Button {
        vm.beeperChats.removeAll { $0.id == chat.id }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove chat")
      .accessibilityLabel("Remove \(name)")
    }
    .opacity(chat.isEnabled ? 1 : 0.6)
  }

  /// The first enabled row with a non-blank chat ID (matches `vm.defaultBeeperChatID`).
  private var defaultChatEntryID: UUID? {
    vm.beeperChats.first {
      $0.isEnabled && !$0.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.id
  }

  private func makeDefault(_ entry: BeeperChatEntry) {
    guard let index = vm.beeperChats.firstIndex(where: { $0.id == entry.id }) else { return }
    vm.beeperChats.insert(vm.beeperChats.remove(at: index), at: 0)
  }

  // MARK: - Sending

  private var sendingSection: some View {
    Section {
      Toggle(isOn: $vm.beeperPostProcessingEnabled) {
        Text("LLM post-processing")
        Text("Clean the transcript with the Dictation prompt before sending.")
      }
      Toggle(isOn: $vm.beeperClipboardContextEnabled) {
        Text("Include copied text")
        Text("Attach recently copied text to the message as context.")
      }
      NumberStepperRow(
        title: "Copied text freshness",
        value: $vm.beeperClipboardTimeoutSeconds,
        range: HermesClipboardContextPolicy.minimumRetentionWindow
          ... HermesClipboardContextPolicy.maximumRetentionWindow,
        unit: "s"
      )
      .disabled(!vm.beeperClipboardContextEnabled)
    } header: {
      Text("Sending")
    }
  }

  private var repliesSection: some View {
    Section {
      Toggle(isOn: $vm.beeperResponseMonitoringEnabled) {
        Text("Show response window")
        Text("Watch Beeper after sending and show the first incoming reply.")
      }
      if vm.beeperResponseMonitoringEnabled {
        NumberStepperRow(
          title: "Check for replies every",
          value: $vm.beeperResponsePollingIntervalSeconds,
          range: 2...60,
          unit: "s"
        )
        LabeledContent {
          TextField(
            "Ignore replies containing",
            text: $vm.beeperResponseFilterKeywords,
            prompt: Text("running, bash, tool")
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
        } label: {
          Text("Ignore replies containing")
          Text("Comma-separated. Skips intermediate tool-call messages.")
        }
      }
      Toggle(isOn: $vm.beeperSuppressWhenChatAppFrontmost) {
        Text("Don't show when Telegram or Beeper is focused")
        Text("You're likely already reading the reply there.")
      }
      NumberStepperRow(
        title: "Response window text size",
        subtitle: "Applies to newly opened response windows.",
        value: $vm.responseWindowFontSize,
        range: 11...28,
        unit: "pt"
      )
    } header: {
      Text("Replies")
    }
  }

  // MARK: - Activity

  private var activitySection: some View {
    Section {
      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.small) {
          if vm.beeperIsSending {
            ProgressView().controlSize(.small)
          }
          if vm.beeperIsAwaitingResponse {
            StatusBadge(.neutral, "Waiting for response")
          }
          Button {
            vm.startBeeperRecording()
          } label: {
            Label(
              vm.isBeeperRecording ? "Send Recording" : "Voice Message",
              systemImage: vm.isBeeperRecording ? "paperplane" : "mic"
            )
          }
          .disabled(!vm.beeperEnabled || vm.beeperIsSending)
        }
      } label: {
        Text("Try it")
        Text("Set the Beeper shortcut in Settings → Shortcuts.")
      }

      if !vm.beeperLastSentText.isEmpty {
        LabeledContent("Last sent") {
          Text(vm.beeperLastSentText)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .lineLimit(4)
        }
      }

      if !vm.beeperLastResponseText.isEmpty {
        LabeledContent(
          vm.beeperLastResponseSender.isEmpty
            ? "Last response"
            : "Last response from \(vm.beeperLastResponseSender)"
        ) {
          Text(vm.beeperLastResponseText)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .lineLimit(4)
        }
      }
    } header: {
      Text("Activity")
    }
  }

  private func testConnection() {
    isTestingConnection = true
    Task {
      await vm.testBeeperConnection()
      await MainActor.run { isTestingConnection = false }
    }
  }
}
