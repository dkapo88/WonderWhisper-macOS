import SwiftUI

private enum HermesSessionListScope: String, CaseIterable, Identifiable {
  case active = "Active"
  case archive = "Archive"

  var id: String { rawValue }
}

enum HermesChatScrollBehavior {
  static let bottomAnchorID = "hermes-chat-bottom"
}

struct HermesAgentView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var sessionListScope: HermesSessionListScope = .active
  @State private var showClearActiveConfirmation: Bool = false
  @State private var pendingDeleteSession: HermesChatSession?
  @State private var textReplyDrafts: [UUID: String] = [:]

  private let chatBottomID = HermesChatScrollBehavior.bottomAnchorID
  private let sessionListWidth: CGFloat = 280
  private let messageSideInset: CGFloat = 64

  var body: some View {
    chatSection
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          if vm.hermesIsSending {
            ProgressView().controlSize(.small)
          }
          Button {
            sessionListScope = .active
            vm.startNewHermesSessionRecording()
          } label: {
            Label("New Session", systemImage: "plus")
          }
          .disabled(!vm.hermesAgentEnabled)
          .help(vm.hermesAgentEnabled
            ? "Record a new Hermes session"
            : "Turn on Hermes in Settings → Integrations")

          if !vm.activeHermesSessions.isEmpty {
            Button {
              showClearActiveConfirmation = true
            } label: {
              Label("Archive Active", systemImage: "archivebox")
            }
            .help("Archive all active Hermes sessions")
          }

          Button {
            SettingsRouter.shared.show(.integrations, integration: .hermes)
          } label: {
            Label("Hermes Settings", systemImage: "gearshape")
          }
          .help("Hermes settings")
        }
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

  private var chatSection: some View {
    Group {
      if vm.hermesSessions.isEmpty {
        emptyChatView
      } else {
        HStack(alignment: .top, spacing: 0) {
          sessionListView
            .frame(width: sessionListWidth)
            .frame(maxHeight: .infinity)
            .padding(DesignTokens.Spacing.small)

          Divider()

          selectedSessionView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DesignTokens.Spacing.medium)
            .layoutPriority(1)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var emptyChatView: some View {
    ContentUnavailableView {
      Label("No Hermes sessions yet", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text(vm.hermesAgentEnabled
        ? "Use the Hermes shortcut or New Session to start talking."
        : "Turn on Hermes in Settings → Integrations to start a session.")
    } actions: {
      if !vm.hermesAgentEnabled {
        Button("Open Hermes Settings") {
          SettingsRouter.shared.show(.integrations, integration: .hermes)
        }
      }
    }
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

        chatTranscript(for: session)
          .layoutPriority(1)

        textReplyComposer(for: session)
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
            vm.isHermesRecordingReply(to: session.id) ? "Send" : "Voice",
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

  private func chatTranscript(for session: HermesChatSession) -> some View {
    Group {
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
      }
    }
  }

  private func textReplyComposer(for session: HermesChatSession) -> some View {
    let draft = textReplyDraftBinding(for: session.id)
    let canSend = vm.canUseHermesTextReply(for: session)
      && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return VStack(alignment: .leading, spacing: 8) {
      Divider()

      HStack(alignment: .bottom, spacing: 10) {
        TextEditor(text: draft)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 46, idealHeight: 64, maxHeight: 110)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.secondary.opacity(0.18))
          )
          .disabled(!vm.canUseHermesTextReply(for: session))

        Button {
          sendTextReply(for: session)
        } label: {
          Label("Send", systemImage: "paperplane.fill")
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend)
      }

      Text(vm.canUseHermesTextReply(for: session)
           ? "Type a reply to this Hermes session. Press Command-Return to send."
           : "Text replies are unavailable while this session is archived, waiting, or recording.")
        .font(.caption)
        .foregroundColor(.secondary)
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
        if !messages.isEmpty {
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
          contextLabelsView(message)
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

  private func contextLabelsView(_ message: HermesChatMessage) -> some View {
    HermesContextLabelsView(
      labels: message.contextLabels,
      clipboardText: message.clipboardText
    )
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

  private func textReplyDraftBinding(for sessionID: UUID) -> Binding<String> {
    Binding(
      get: { textReplyDrafts[sessionID] ?? "" },
      set: { textReplyDrafts[sessionID] = $0 }
    )
  }

  private func sendTextReply(for session: HermesChatSession) {
    let text = textReplyDrafts[session.id] ?? ""
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // Clear only once the reply is accepted. Both of `sendHermesTextReply`'s guards return
    // synchronously, so clearing first destroyed what Dane typed against a rejection the app
    // already knew about — no network, no race. The guards' `settingsNotice` is still what tells
    // him why; this only stops the text going with it.
    guard vm.sendHermesTextReply(trimmed, to: session.id) else { return }
    textReplyDrafts[session.id] = ""
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

private struct HermesContextLabelsView: View {
  let labels: [String]
  let clipboardText: String?

  @State private var isClipboardPreviewPresented = false

  var body: some View {
    HStack(spacing: 6) {
      ForEach(labels, id: \.self) { label in
        if isClipboardLabel(label), let clipboardText {
          Button {
            isClipboardPreviewPresented.toggle()
          } label: {
            contextLabel(label, isInteractive: true)
          }
          .buttonStyle(.plain)
          .help("Preview copied text sent with this message")
          .popover(isPresented: $isClipboardPreviewPresented, arrowEdge: .bottom) {
            clipboardPreview(clipboardText)
          }
        } else if isClipboardLabel(label) {
          contextLabel(label, isInteractive: false)
            .help("Clipboard preview is unavailable for older messages")
        } else {
          contextLabel(label, isInteractive: false)
        }
      }
    }
  }

  private func contextLabel(_ label: String, isInteractive: Bool) -> some View {
    HStack(spacing: 4) {
      Text(label)
      if isInteractive {
        Image(systemName: "eye")
          .font(.system(size: 9, weight: .semibold))
      }
    }
    .font(.caption2.weight(.semibold))
    .foregroundColor(isInteractive ? .accentColor : .secondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(
          isInteractive
            ? Color.accentColor.opacity(0.12)
            : Color.secondary.opacity(0.10)
        )
    )
  }

  private func clipboardPreview(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label("Clipboard text", systemImage: "doc.on.clipboard")
          .font(.headline)
        Spacer()
        Button {
          HermesResponseClipboard.copyRaw(text)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
      }

      ScrollView {
        Text(text)
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 240)
    }
    .padding(14)
    .frame(width: 430)
  }

  private func isClipboardLabel(_ label: String) -> Bool {
    label.localizedCaseInsensitiveCompare("Clipboard") == .orderedSame
  }
}

#Preview {
  HermesAgentView(vm: DictationViewModel())
}
