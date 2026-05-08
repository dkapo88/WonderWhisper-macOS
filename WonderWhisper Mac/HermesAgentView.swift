import SwiftUI

private enum HermesAgentSection: String, CaseIterable, Identifiable {
  case chat = "Chat"
  case settings = "Settings"

  var id: String { rawValue }
}

private enum HermesSessionListScope: String, CaseIterable, Identifiable {
  case active = "Active"
  case archive = "Archive"

  var id: String { rawValue }
}

enum HermesChatScrollBehavior {
  static let bottomAnchorID = "hermes-chat-bottom"

  static func shouldScrollToLatestOnAppear(messageCount: Int) -> Bool {
    messageCount > 0
  }
}

struct HermesAgentView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var selectedSection: HermesAgentSection = .chat
  @State private var sessionListScope: HermesSessionListScope = .active
  @State private var hermesKeyInput: String = ""
  @State private var isTestingHermes: Bool = false
  @State private var hasSavedKey: Bool = false
  @State private var showClearActiveConfirmation: Bool = false
  @State private var pendingDeleteSession: HermesChatSession?

  private let keychain = KeychainService()
  private let chatBottomID = HermesChatScrollBehavior.bottomAnchorID
  private let sessionListWidth: CGFloat = 280
  private let messageSideInset: CGFloat = 64

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      sectionPicker

      switch selectedSection {
      case .chat:
        chatSection
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .layoutPriority(1)
      case .settings:
        ScrollView {
          settingsSection
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      selectedSection = .chat
      refreshKeyStatus()
    }
    .onChange(of: sessionListScope) { _, _ in
      selectFirstDisplayedSession()
    }
    .confirmationDialog(
      "Archive all active Hermes sessions?",
      isPresented: $showClearActiveConfirmation,
      titleVisibility: .visible
    ) {
      Button("Archive Active Sessions", role: .destructive) {
        vm.archiveActiveHermesSessions()
        sessionListScope = .archive
        selectFirstDisplayedSession()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes active sessions from the main list and keeps them available in Archive.")
    }
    .alert(
      "Delete Hermes session?",
      isPresented: Binding(
        get: { pendingDeleteSession != nil },
        set: { if !$0 { pendingDeleteSession = nil } }
      )
    ) {
      Button("Delete Locally", role: .destructive) {
        if let sessionID = pendingDeleteSession?.id {
          vm.deleteHermesSession(sessionID)
          selectFirstDisplayedSession()
        }
        pendingDeleteSession = nil
      }
      Button("Cancel", role: .cancel) {
        pendingDeleteSession = nil
      }
    } message: {
      Text("This permanently removes the local WonderWhisper record for this session. It does not delete remote Hermes VPS context.")
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

        if vm.hermesSessions.isEmpty {
          emptyChatView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          HStack(alignment: .top, spacing: 14) {
            sessionListView
              .frame(width: sessionListWidth)
              .frame(maxHeight: .infinity)

            Divider()
              .frame(maxHeight: .infinity)

            selectedSessionView
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .layoutPriority(1)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }
      .padding(.top, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

      Button(action: {
        sessionListScope = .active
        vm.startNewHermesSessionRecording()
      }) {
        Label("New", systemImage: "plus.circle.fill")
      }
      .disabled(!vm.hermesAgentEnabled)

      if !vm.activeHermesSessions.isEmpty {
        Button(action: { showClearActiveConfirmation = true }) {
          Label("Clear Active", systemImage: "archivebox")
        }
        .help("Archive all active Hermes sessions")
      }
    }
  }

  private var emptyChatView: some View {
    VStack(spacing: 10) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 34, weight: .regular))
        .foregroundColor(.secondary)

      Text("No Hermes messages yet.")
        .font(.callout.weight(.medium))
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  private var sessionListView: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Sessions", selection: $sessionListScope) {
        ForEach(HermesSessionListScope.allCases) { scope in
          Text(scope.rawValue).tag(scope)
        }
      }
      .pickerStyle(.segmented)

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          if displayedSessions.isEmpty {
            emptySessionListView
          } else {
            ForEach(displayedSessions) { session in
              Button {
                vm.selectHermesSession(session.id)
              } label: {
                sessionRow(session)
              }
              .buttonStyle(.plain)
            }
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .layoutPriority(1)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var displayedSessions: [HermesChatSession] {
    switch sessionListScope {
    case .active:
      return vm.activeHermesSessions
    case .archive:
      return vm.archivedHermesSessions
    }
  }

  private var emptySessionListView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(sessionListScope == .active ? "No active sessions." : "No archived sessions.")
        .font(.callout.weight(.medium))
      Text(sessionListScope == .active
           ? "Archived sessions are available in Archive."
           : "Archived sessions will appear here.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var selectedSessionView: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let session = vm.selectedHermesSession {
        selectedSessionHeader(session)

        if session.messages.isEmpty {
          Text("No messages in this session yet.")
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          chatMessagesView(
            messages: session.messages,
            isWaiting: vm.isHermesSessionActivelyWaiting(session)
          )
          .layoutPriority(1)
        }
      } else {
        Text("Select a Hermes session.")
          .font(.callout)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func sessionRow(_ session: HermesChatSession) -> some View {
    let isSelected = vm.selectedHermesSessionID == session.id

    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: statusIcon(for: session.status))
          .font(.caption)
          .foregroundColor(statusColor(for: session.status))
          .frame(width: 16)

        Text(session.title)
          .font(.callout.weight(.semibold))
          .lineLimit(1)

        Spacer(minLength: 4)
      }

      if !session.lastMessagePreview.isEmpty {
        Text(session.lastMessagePreview)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Text(Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
        .font(.caption2)
        .foregroundColor(.secondary)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12))
    )
  }

  private func selectedSessionHeader(_ session: HermesChatSession) -> some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(session.title)
          .font(.headline)
          .lineLimit(1)

        Label(statusTitle(for: session.status), systemImage: statusIcon(for: session.status))
          .font(.caption)
          .foregroundColor(statusColor(for: session.status))
      }

      Spacer()

      if vm.isHermesSessionActivelyWaiting(session) {
        ProgressView()
          .controlSize(.small)
      }

      Button(action: { vm.showHermesResponseWindow(for: session.id) }) {
        Label("Window", systemImage: "macwindow")
      }
      .disabled(session.latestAssistantMessage == nil)

      if session.isArchived {
        Button(action: { vm.restoreHermesSession(session.id); sessionListScope = .active }) {
          Label("Restore", systemImage: "arrow.uturn.backward.circle")
        }
      } else {
        if vm.canInterruptHermesSession(session) {
          Button(action: { vm.interruptHermesSession(session.id) }) {
            Label("Interrupt", systemImage: "stop.circle")
          }
        }

        Button(action: { vm.startHermesReply(to: session.id) }) {
          Label(
            vm.isHermesRecordingReply(to: session.id) ? "Send" : "Reply",
            systemImage: vm.isHermesRecordingReply(to: session.id) ? "paperplane.fill" : "mic.fill"
          )
        }
        .disabled(!vm.hermesAgentEnabled || !vm.canUseHermesReplyButton(for: session))

        Button(action: { vm.archiveHermesSession(session.id) }) {
          Label("Archive", systemImage: "archivebox")
        }
      }

      Button(role: .destructive, action: { pendingDeleteSession = session }) {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  private func chatMessagesView(messages: [HermesChatMessage], isWaiting: Bool) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(messages) { message in
            chatMessageRow(message)
              .id(message.id)
          }

          if isWaiting {
            waitingRow
          }

          Color.clear
            .frame(height: 1)
            .id(chatBottomID)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .defaultScrollAnchor(.bottom)
      .onAppear {
        if HermesChatScrollBehavior.shouldScrollToLatestOnAppear(
          messageCount: messages.count
        ) {
          scrollChatToBottom(proxy, animated: false)
        }
      }
      .onChange(of: vm.hermesChatMessages.count) { _, _ in
        scrollChatToBottom(proxy)
      }
      .onChange(of: vm.selectedHermesSessionID) { _, _ in
        scrollChatToBottom(proxy)
      }
      .onChange(of: isWaiting) { _, _ in
        scrollChatToBottom(proxy)
      }
    }
  }

  private func chatMessageRow(_ message: HermesChatMessage) -> some View {
    let isUser = message.role == .user

    return HStack(alignment: .top, spacing: 10) {
      if isUser {
        Color.clear
          .frame(width: messageSideInset)
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
      .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

      if isUser {
        chatAvatar(for: message.role)
      } else {
        Color.clear
          .frame(width: messageSideInset)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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
    VStack(alignment: .leading, spacing: 8) {
      switch message.role {
      case .assistant:
        HermesMarkdownView(text: message.text)
      case .user, .error:
        Text(message.text)
          .font(.body)
          .lineSpacing(3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      copyButtons(for: message.text)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(chatBubbleColor(for: message.role))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(chatBubbleStroke(for: message.role), lineWidth: 1)
    )
  }

  private func copyButtons(for text: String) -> some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)

      Button {
        HermesResponseClipboard.copyRaw(text)
      } label: {
        Label("Copy Raw", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .font(.caption)
      .help("Copy Markdown text")

      Button {
        HermesResponseClipboard.copyFormatted(text)
      } label: {
        Label("Copy Formatted", systemImage: "doc.richtext")
      }
      .buttonStyle(.borderless)
      .font(.caption)
      .help("Copy formatted rich text")
    }
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

        Stepper(
          value: $vm.hermesTimeoutSeconds,
          in: HermesAgentSettings.minimumTimeout...HermesAgentSettings.maximumTimeout,
          step: 15
        ) {
          Text("Timeout: \(timeoutDisplay(vm.hermesTimeoutSeconds))")
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
        Toggle("LLM post-processing", isOn: $vm.hermesPostProcessingEnabled)
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

  private func statusTitle(for status: HermesChatSession.Status) -> String {
    switch status {
    case .open: return "Open"
    case .waiting: return "Waiting"
    case .responded: return "Responded"
    case .error: return "Error"
    case .interrupted: return "Interrupted"
    case .archived, .closed: return "Archived"
    }
  }

  private func statusIcon(for status: HermesChatSession.Status) -> String {
    switch status {
    case .open: return "bubble.left"
    case .waiting: return "hourglass"
    case .responded: return "checkmark.circle.fill"
    case .error: return "exclamationmark.triangle.fill"
    case .interrupted: return "exclamationmark.circle.fill"
    case .archived, .closed: return "archivebox.fill"
    }
  }

  private func statusColor(for status: HermesChatSession.Status) -> Color {
    switch status {
    case .open: return .secondary
    case .waiting: return .orange
    case .responded: return .green
    case .error: return .red
    case .interrupted: return .orange
    case .archived, .closed: return .secondary
    }
  }

  private func selectFirstDisplayedSession() {
    let selectedID = vm.selectedHermesSessionID
    if let selectedID,
       displayedSessions.contains(where: { $0.id == selectedID }) {
      return
    }
    vm.selectHermesSession(displayedSessions.first?.id)
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

  private func scrollChatToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
    let scroll = {
      if animated {
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(chatBottomID, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(chatBottomID, anchor: .bottom)
      }
    }

    DispatchQueue.main.async {
      scroll()
      DispatchQueue.main.async {
        scroll()
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

  private func timeoutDisplay(_ seconds: Double) -> String {
    let value = Int(HermesAgentSettings.clampedTimeout(seconds))
    let minutes = value / 60
    let remainingSeconds = value % 60

    if remainingSeconds == 0, minutes > 0 {
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    if minutes > 0 {
      return "\(minutes)m \(remainingSeconds)s"
    }

    return "\(remainingSeconds)s"
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
}

#Preview {
  HermesAgentView(vm: DictationViewModel())
}
