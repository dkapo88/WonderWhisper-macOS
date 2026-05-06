import SwiftUI

private enum HermesAgentSection: String, CaseIterable, Identifiable {
  case chat = "Chat"
  case settings = "Settings"

  var id: String { rawValue }
}

struct HermesAgentView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var selectedSection: HermesAgentSection = .chat
  @State private var hermesKeyInput: String = ""
  @State private var isTestingHermes: Bool = false
  @State private var hasSavedKey: Bool = false

  private let keychain = KeychainService()
  private let chatBottomID = "hermes-chat-bottom"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        sectionPicker

        switch selectedSection {
        case .chat:
          chatSection
        case .settings:
          settingsSection
        }

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      selectedSection = .chat
      refreshKeyStatus()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Hermes Agent")
        .font(.title2.weight(.semibold))
      Text("Voice turns sent directly to your Hermes API server.")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  private var sectionPicker: some View {
    Picker("Hermes section", selection: $selectedSection) {
      ForEach(HermesAgentSection.allCases) { section in
        Text(section.rawValue).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 260)
  }

  private var chatSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        chatToolbar

        if vm.hermesChatMessages.isEmpty {
          emptyChatView
        } else {
          chatMessagesView
        }
      }
      .padding(.top, 4)
    }
  }

  private var chatToolbar: some View {
    HStack(spacing: 10) {
      Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
        .font(.headline)

      if vm.hermesIsSending {
        ProgressView()
          .controlSize(.small)
      }

      Spacer()

      if !vm.hermesChatMessages.isEmpty {
        Button(action: vm.clearHermesChat) {
          Label("Clear", systemImage: "trash")
        }
        .disabled(vm.hermesIsSending)
        .help("Clear chat")
      }

      Button(action: vm.startHermesReply) {
        Label("Reply", systemImage: "mic.fill")
      }
      .disabled(!vm.hermesAgentEnabled || vm.hermesIsSending)
    }
  }

  private var emptyChatView: some View {
    VStack(spacing: 10) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 34, weight: .regular))
        .foregroundColor(.secondary)

      Text("No Hermes messages in this session.")
        .font(.callout.weight(.medium))
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  private var chatMessagesView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(vm.hermesChatMessages) { message in
            chatMessageRow(message)
              .id(message.id)
          }

          if vm.hermesIsSending {
            waitingRow
          }

          Color.clear
            .frame(height: 1)
            .id(chatBottomID)
        }
        .padding(.vertical, 4)
      }
      .frame(minHeight: 280, maxHeight: 560)
      .onChange(of: vm.hermesChatMessages.count) { _, _ in
        scrollChatToBottom(proxy)
      }
      .onChange(of: vm.hermesIsSending) { _, _ in
        scrollChatToBottom(proxy)
      }
    }
  }

  private func chatMessageRow(_ message: HermesChatMessage) -> some View {
    let isUser = message.role == .user

    return HStack(alignment: .top, spacing: 10) {
      if isUser {
        Spacer(minLength: 64)
      } else {
        chatAvatar(for: message.role)
      }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(roleTitle(for: message.role))
            .font(.caption.weight(.semibold))
          Text(Self.timeFormatter.string(from: message.createdAt))
            .font(.caption)
            .foregroundColor(.secondary)
        }

        chatBubble(message)

        if !message.contextLabels.isEmpty {
          contextLabelsView(message.contextLabels)
        }
      }
      .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

      if isUser {
        chatAvatar(for: message.role)
      } else {
        Spacer(minLength: 64)
      }
    }
  }

  private func chatAvatar(for role: HermesChatMessage.Role) -> some View {
    let systemName: String
    let color: Color
    switch role {
    case .user:
      systemName = "person.fill"
      color = .accentColor
    case .assistant:
      systemName = "sparkles"
      color = .blue
    case .error:
      systemName = "exclamationmark.triangle.fill"
      color = .red
    }

    return Image(systemName: systemName)
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(color)
      .frame(width: 30, height: 30)
      .background(
        Circle()
          .fill(color.opacity(0.12))
      )
  }

  private func chatBubble(_ message: HermesChatMessage) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      switch message.role {
      case .assistant:
        HermesMarkdownView(text: message.text)
      case .user, .error:
        Text(message.text)
          .font(.body)
          .lineSpacing(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .textSelection(.enabled)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(chatBubbleColor(for: message.role))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(chatBubbleStroke(for: message.role), lineWidth: 1)
    )
  }

  private func contextLabelsView(_ labels: [String]) -> some View {
    HStack(spacing: 6) {
      ForEach(labels, id: \.self) { label in
        Text(label)
          .font(.caption2.weight(.semibold))
          .foregroundColor(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(Color.secondary.opacity(0.10))
          )
      }
    }
  }

  private var waitingRow: some View {
    HStack(alignment: .top, spacing: 10) {
      chatAvatar(for: .assistant)
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Waiting for Hermes...")
          .font(.callout)
          .foregroundColor(.secondary)
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      Spacer(minLength: 64)
    }
  }

  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: 18) {
      connectionSection
      contextSection
      hotkeySection
    }
  }

  private var connectionSection: some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable Hermes agent", isOn: $vm.hermesAgentEnabled)

        TextField(AppConfig.defaultHermesBaseURLString, text: $vm.hermesBaseURLString)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 440)

        HStack(spacing: 12) {
          TextField(AppConfig.defaultHermesConversationName, text: $vm.hermesConversationName)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 240)

          TextField(AppConfig.defaultHermesModel, text: $vm.hermesModel)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 170)
        }

        Stepper(value: $vm.hermesTimeoutSeconds, in: 15...600, step: 15) {
          Text("Timeout: \(Int(vm.hermesTimeoutSeconds))s")
            .font(.callout)
        }
        .frame(maxWidth: 240, alignment: .leading)

        HStack(spacing: 6) {
          Text(hasSavedKey ? "Bearer key: Saved" : "Bearer key: Not saved")
            .font(.callout.weight(.semibold))
            .foregroundColor(hasSavedKey ? .green : .secondary)
          if hasSavedKey {
            Image(systemName: "checkmark.seal.fill")
              .foregroundColor(.green)
          }
        }

        HStack(spacing: 10) {
          SecureField("Hermes API server key", text: $hermesKeyInput)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)

          Button("Save key") {
            vm.saveHermesApiKey(hermesKeyInput)
            hermesKeyInput = ""
            refreshKeyStatus()
          }
          .disabled(hermesKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button(action: testHermesConnection) {
            if isTestingHermes {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Test", systemImage: "bolt.horizontal.circle")
            }
          }
          .disabled(isTestingHermes)
        }

        if let status = vm.hermesConnectionStatus {
          Label(status, systemImage: statusIcon)
            .font(.callout)
            .foregroundColor(statusColor)
            .textSelection(.enabled)
        }

        Text("Use `http://127.0.0.1:8642` for a local gateway or your remote Hermes server URL. URLs ending in `/v1` also work.")
          .font(.caption)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
      .padding(.top, 4)
    }
  }

  private var hotkeySection: some View {
    GroupBox("Dedicated Hotkey") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Activation key", selection: hermesSelectionBinding) {
          Text("None").tag(HotkeyManager.Selection?.none)
          ForEach(HotkeyManager.Selection.allCases, id: \.self) { option in
            Text(hotkeyTitle(for: option))
              .tag(Optional(option))
              .disabled(isReserved(option))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 300)

        if let selection = vm.hermesSelection {
          HStack {
            Text("Current: \(selection.displayName)")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Button("Clear") {
              vm.setHermesSelection(nil)
            }
            .buttonStyle(.borderless)
          }
        } else {
          Text("No Hermes hotkey assigned.")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Text("Hermes uses its own hotkey and no longer takes over the Command shortcut.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var contextSection: some View {
    GroupBox("Context") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Screen text context", isOn: $vm.hermesScreenContextEnabled)
          .toggleStyle(.checkbox)
        Toggle("Screenshot image", isOn: $vm.hermesScreenshotEnabled)
          .toggleStyle(.checkbox)
        Toggle("Copied text / clipboard", isOn: $vm.hermesClipboardContextEnabled)
          .toggleStyle(.checkbox)

        Text("Controls what Hermes receives with each voice turn.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var hermesSelectionBinding: Binding<HotkeyManager.Selection?> {
    Binding(
      get: { vm.hermesSelection },
      set: { vm.setHermesSelection($0) }
    )
  }

  private var statusIcon: String {
    switch vm.hermesConnectionSucceeded {
    case true: return "checkmark.circle.fill"
    case false: return "xmark.octagon.fill"
    case nil: return "info.circle.fill"
    case .some: return "info.circle.fill"
    }
  }

  private var statusColor: Color {
    switch vm.hermesConnectionSucceeded {
    case true: return .green
    case false: return .red
    case nil: return .secondary
    case .some: return .secondary
    }
  }

  private func roleTitle(for role: HermesChatMessage.Role) -> String {
    switch role {
    case .user: return "You"
    case .assistant: return "Hermes"
    case .error: return "Error"
    }
  }

  private func chatBubbleColor(for role: HermesChatMessage.Role) -> Color {
    switch role {
    case .user:
      return Color.accentColor.opacity(0.14)
    case .assistant:
      return Color(nsColor: .controlBackgroundColor)
    case .error:
      return Color.red.opacity(0.10)
    }
  }

  private func chatBubbleStroke(for role: HermesChatMessage.Role) -> Color {
    switch role {
    case .user:
      return Color.accentColor.opacity(0.18)
    case .assistant:
      return Color.secondary.opacity(0.14)
    case .error:
      return Color.red.opacity(0.20)
    }
  }

  private func hotkeyTitle(for option: HotkeyManager.Selection) -> String {
    if option == vm.simpleDictation.selection {
      return "\(option.displayName) (Dictation)"
    }
    if option == vm.simpleCommand.selection {
      return "\(option.displayName) (Command)"
    }
    return option.displayName
  }

  private func isReserved(_ option: HotkeyManager.Selection) -> Bool {
    option == vm.simpleDictation.selection || option == vm.simpleCommand.selection
  }

  private func scrollChatToBottom(_ proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(chatBottomID, anchor: .bottom)
      }
    }
  }

  private func refreshKeyStatus() {
    hasSavedKey = keychain.getSecret(forKey: AppConfig.hermesAPIKeyAlias) != nil
  }

  private func testHermesConnection() {
    refreshKeyStatus()
    isTestingHermes = true
    Task {
      await vm.testHermesConnection()
      await MainActor.run {
        refreshKeyStatus()
        isTestingHermes = false
      }
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
}

#Preview {
  HermesAgentView(vm: DictationViewModel())
}
