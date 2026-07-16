import SwiftUI

struct BeeperIntegrationView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var accessTokenInput = ""
  @State private var hasSavedToken = false
  @State private var isTestingConnection = false

  private let keychain = KeychainService()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        connectionSection
        hotkeySection
        sendSection
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear(perform: refreshTokenStatus)
  }

  private var connectionSection: some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable Beeper voice send", isOn: $vm.beeperEnabled)

        TextField(AppConfig.defaultBeeperBaseURLString, text: $vm.beeperBaseURLString)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 440)
          .help("Beeper Desktop API usually runs locally on port 23373.")

        chatListSection

        HStack(spacing: 6) {
          Text(hasSavedToken ? "Access token: Saved" : "Access token: Not saved")
            .font(.callout.weight(.semibold))
            .foregroundColor(hasSavedToken ? .green : .secondary)
          if hasSavedToken {
            Image(systemName: "checkmark.seal.fill")
              .foregroundColor(.green)
          }
        }

        HStack(spacing: 10) {
          SecureField("Beeper access token", text: $accessTokenInput)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)

          Button("Save token") {
            vm.saveBeeperAccessToken(accessTokenInput)
            accessTokenInput = ""
            refreshTokenStatus()
          }
          .disabled(accessTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button(action: testConnection) {
            if isTestingConnection {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Test", systemImage: "bolt.horizontal.circle")
            }
          }
          .disabled(isTestingConnection)
        }

        if let status = vm.beeperConnectionStatus {
          Label(status, systemImage: statusIcon)
            .font(.callout)
            .foregroundColor(statusColor)
            .textSelection(.enabled)
        }

        Text("Create a token in Beeper Desktop under Settings -> Integrations -> Approved connections. This app only sends to the configured chat ID.")
          .font(.caption)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
      .padding(.top, 4)
    }
  }

  private var chatListSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Monitored chats")
          .font(.callout.weight(.semibold))
        Spacer()
        Button {
          vm.beeperChats.append(BeeperChatEntry())
        } label: {
          Label("Add chat", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }

      if vm.beeperChats.isEmpty {
        Text("No chats yet. Add a chat ID and give it a label so you know which is which.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        ForEach($vm.beeperChats) { $entry in
          HStack(spacing: 8) {
            Toggle("", isOn: $entry.isEnabled)
              .toggleStyle(.checkbox)
              .labelsHidden()
              .help(entry.isEnabled ? "Monitored. Uncheck to pause this chat." : "Paused — not monitored.")

            TextField("Label (e.g. Mum, Work group)", text: $entry.alias)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 180)

            TextField("Chat ID", text: $entry.chatID)
              .textFieldStyle(.roundedBorder)
              .font(.body.monospaced())
              .frame(maxWidth: 260)

            if entry.id == defaultChatEntryID {
              Text("Default")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            } else {
              Button("Make default") { makeDefault(entry) }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!entry.isEnabled)
            }

            Button {
              vm.beeperChats.removeAll { $0.id == entry.id }
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this chat")
          }
          .opacity(entry.isEnabled ? 1 : 0.5)
        }
      }

      Text("Checked chats are monitored. The first checked chat is the default for new voice messages.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  /// The entry whose chat ID is actually used as the default target: the first
  /// enabled row with a non-blank chat ID (matches `vm.defaultBeeperChatID`).
  private var defaultChatEntryID: UUID? {
    vm.beeperChats.first {
      $0.isEnabled && !$0.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.id
  }

  private func makeDefault(_ entry: BeeperChatEntry) {
    guard let index = vm.beeperChats.firstIndex(where: { $0.id == entry.id }) else { return }
    vm.beeperChats.insert(vm.beeperChats.remove(at: index), at: 0)
  }

  private var hotkeySection: some View {
    GroupBox("Dedicated Hotkey") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Activation key", selection: beeperSelectionBinding) {
          Text("None").tag(HotkeyManager.Selection?.none)
          ForEach(HotkeyManager.Selection.allCases, id: \.self) { option in
            Text(hotkeyTitle(for: option))
              .tag(Optional(option))
              .disabled(isReserved(option))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 300)

        if let selection = vm.beeperSelection {
          HStack {
            Text("Current: \(selection.displayName)")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Button("Clear") {
              vm.setBeeperSelection(nil)
            }
            .buttonStyle(.borderless)
          }
        } else {
          Text("No Beeper hotkey assigned.")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Text("The Beeper shortcut records, transcribes, and sends the result to the configured chat.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var sendSection: some View {
    GroupBox("Send Behavior") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("LLM post-processing", isOn: $vm.beeperPostProcessingEnabled)
          .toggleStyle(.checkbox)
          .help("Clean the transcript with the Dictation prompt before sending.")

        Toggle("Copied text / clipboard", isOn: $vm.beeperClipboardContextEnabled)
          .toggleStyle(.checkbox)
          .help("Attach recently copied text to the Beeper message as context.")

        Stepper(
          "Clipboard freshness: \(Int(vm.beeperClipboardTimeoutSeconds)) seconds",
          value: $vm.beeperClipboardTimeoutSeconds,
          in: HermesClipboardContextPolicy.minimumRetentionWindow...HermesClipboardContextPolicy.maximumRetentionWindow,
          step: 1
        )
        .frame(maxWidth: 360, alignment: .leading)
        .disabled(!vm.beeperClipboardContextEnabled)

        Toggle("Show response window", isOn: $vm.beeperResponseMonitoringEnabled)
          .toggleStyle(.checkbox)
          .help("Watch Beeper after sending and show the first incoming text reply.")

        Stepper(
          "Response window font size: \(Int(vm.responseWindowFontSize)) pt",
          value: $vm.responseWindowFontSize,
          in: 11...28,
          step: 1
        )
        .frame(maxWidth: 360, alignment: .leading)
        .help("Base text size for response windows. Headings and code scale with it. Applies to newly opened windows.")

        Toggle("Don't show when Telegram or Beeper is focused", isOn: $vm.beeperSuppressWhenChatAppFrontmost)
          .toggleStyle(.checkbox)
          .help("If a chat app is frontmost when a reply arrives, skip the response window — you're likely already reading it there.")

        if vm.beeperResponseMonitoringEnabled {
          VStack(alignment: .leading, spacing: 8) {
            Stepper(
              "Poll every \(Int(vm.beeperResponsePollingIntervalSeconds)) seconds",
              value: $vm.beeperResponsePollingIntervalSeconds,
              in: 2...60,
              step: 1
            )
            .frame(maxWidth: 320, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
              Text("Ignore replies containing")
                .font(.callout.weight(.semibold))
              TextField("running, bash, tool", text: $vm.beeperResponseFilterKeywords)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 440)
              Text("Comma-separated terms. Intermediate tool-call messages matching any term are skipped, so only the final reply opens a window.")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .font(.callout)
        }

        HStack(spacing: 10) {
          Button {
            vm.startBeeperRecording()
          } label: {
            Label(vm.isBeeperRecording ? "Send Recording" : "Voice Message",
                  systemImage: vm.isBeeperRecording ? "paperplane.fill" : "mic.fill")
          }
          .disabled(!vm.beeperEnabled || vm.beeperIsSending)

          if vm.beeperIsSending {
            ProgressView()
              .controlSize(.small)
          }

          if vm.beeperIsAwaitingResponse {
            Label("Waiting for response", systemImage: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        if let pendingID = vm.beeperLastPendingMessageID {
          Label("Last pending message: \(pendingID)", systemImage: "paperplane.circle.fill")
            .font(.caption)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }

        if !vm.beeperLastSentText.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Last sent")
              .font(.caption.weight(.semibold))
              .foregroundColor(.secondary)
            Text(vm.beeperLastSentText)
              .font(.body)
              .textSelection(.enabled)
              .padding(10)
              .frame(maxWidth: 620, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
              )
          }
        }

        if !vm.beeperLastResponseText.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text(vm.beeperLastResponseSender.isEmpty
                 ? "Last response"
                 : "Last response from \(vm.beeperLastResponseSender)")
              .font(.caption.weight(.semibold))
              .foregroundColor(.secondary)
            Text(vm.beeperLastResponseText)
              .font(.body)
              .textSelection(.enabled)
              .padding(10)
              .frame(maxWidth: 620, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
              )
          }
        }
      }
      .padding(.top, 4)
    }
  }

  private var beeperSelectionBinding: Binding<HotkeyManager.Selection?> {
    Binding(
      get: { vm.beeperSelection },
      set: { vm.setBeeperSelection($0) }
    )
  }

  private var statusIcon: String {
    switch vm.beeperConnectionSucceeded {
    case true: return "checkmark.circle.fill"
    case false: return "xmark.octagon.fill"
    case nil: return "info.circle.fill"
    case .some: return "info.circle.fill"
    }
  }

  private var statusColor: Color {
    switch vm.beeperConnectionSucceeded {
    case true: return .green
    case false: return .red
    case nil: return .secondary
    case .some: return .secondary
    }
  }

  private func refreshTokenStatus() {
    hasSavedToken = keychain.getSecret(forKey: AppConfig.beeperAccessTokenAlias) != nil
  }

  private func testConnection() {
    isTestingConnection = true
    Task {
      await vm.testBeeperConnection()
      await MainActor.run {
        isTestingConnection = false
        refreshTokenStatus()
      }
    }
  }

  private func hotkeyTitle(for option: HotkeyManager.Selection) -> String {
    if option == vm.simpleDictation.selection {
      return "\(option.displayName) (Dictation)"
    }
    if option == vm.simpleCommand.selection {
      return "\(option.displayName) (Command)"
    }
    if option == vm.hermesSelection {
      return "\(option.displayName) (Overrides Hermes)"
    }
    return option.displayName
  }

  private func isReserved(_ option: HotkeyManager.Selection) -> Bool {
    option == vm.simpleDictation.selection
      || option == vm.simpleCommand.selection
  }
}
