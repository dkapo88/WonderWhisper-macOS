import AppKit
import SwiftUI

/// Add or edit one webhook endpoint: name, URL, enabled, what to send and whether to split it,
/// signing secret and custom headers.
/// Secret values are written to the Keychain on Save and are never shown in plain text.
struct MeetingWebhookEditorSheet: View {
  private struct HeaderDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String
  }

  @ObservedObject var webhooks: MeetingWebhookCenter
  let isNew: Bool
  let onClose: () -> Void

  @State private var endpoint: MeetingWebhookEndpoint
  @State private var secretDraft = ""
  @State private var clearsSecret = false
  @State private var generatedSecretCopied = false
  @State private var headerDrafts: [HeaderDraft] = []
  /// The header set as read from the Keychain; nil when it could not be read.
  @State private var loadedHeaders: [String: String]? = [:]
  @State private var errorMessage: String?
  @State private var confirmingDelete = false

  init(
    webhooks: MeetingWebhookCenter,
    endpoint: MeetingWebhookEndpoint?,
    onClose: @escaping () -> Void
  ) {
    self.webhooks = webhooks
    self.isNew = endpoint == nil
    self.onClose = onClose
    _endpoint = State(initialValue: endpoint ?? MeetingWebhookEndpoint())
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $endpoint.name, prompt: Text("Grok Bot"))
          TextField("URL", text: $endpoint.url, prompt: Text("https://example.com/hook"))
          if let message = urlMessage {
            StatusBadge(.warning, message)
              .font(.footnote)
          }
          Toggle("Enabled", isOn: $endpoint.isEnabled)
        } header: {
          Text(isNew ? "New webhook" : "Edit webhook")
        }

        deliverySection
        signingSection
        headersSection
      }
      .formStyle(.grouped)

      Divider()

      footer
        .padding(DesignTokens.Spacing.medium)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .frame(width: 560, height: 640)
    .onAppear(perform: loadHeaders)
    .alert("Delete webhook?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) {
        webhooks.deleteEndpoint(endpoint.id)
        onClose()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes \(endpoint.displayName) and its Keychain secrets.")
    }
  }

  // MARK: - Sections

  private var deliverySection: some View {
    Section {
      Picker("Send", selection: $endpoint.content) {
        ForEach(MeetingWebhookContent.allCases, id: \.self) { content in
          Text(content.label).tag(content)
        }
      }
      Toggle("Split into multiple webhooks", isOn: $endpoint.splitIntoParts)
      if endpoint.splitIntoParts {
        TextField(
          "Max body size (characters)",
          value: $endpoint.maxBodyCharacters,
          format: .number.grouping(.never)
        )
      }
    } header: {
      Text("Delivery")
    } footer: {
      Text(deliveryFootnote)
        .settingsFootnote()
    }
  }

  private var deliveryFootnote: String {
    guard endpoint.splitIntoParts else {
      return "Summary only leaves out the transcript. The note is sent as one request."
    }
    let range = MeetingWebhookEndpoint.maxBodyCharactersRange
    return "For receivers that keep only the start of a long request: the note is sent as "
      + "several requests in order, each with the same note details plus part index and "
      + "total, and no body longer than the max (\(range.lowerBound) to "
      + "\(range.upperBound.formatted()))."
  }

  private var signingSection: some View {
    Section {
      SecureField(
        "Signing secret",
        text: $secretDraft,
        prompt: Text(endpoint.hasSecret && !clearsSecret ? "Saved in Keychain" : "None")
      )
      .onChange(of: secretDraft) { _, value in
        if !value.isEmpty { clearsSecret = false }
      }
      HStack {
        Button("Generate") {
          let secret = MeetingWebhookSigner.generateSecret()
          secretDraft = secret
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(secret, forType: .string)
          generatedSecretCopied = true
        }
        if endpoint.hasSecret || !secretDraft.isEmpty {
          Button("Clear") {
            secretDraft = ""
            clearsSecret = true
            generatedSecretCopied = false
          }
        }
        Spacer()
        if generatedSecretCopied {
          Text("New secret copied to the clipboard.")
            .settingsFootnote()
        } else if clearsSecret {
          Text("The secret is removed when you save.")
            .settingsFootnote()
        }
      }
    } header: {
      Text("Signature")
    } footer: {
      Text("When set, each request carries X-WonderWhisper-Signature: sha256=<hex>, an "
        + "HMAC-SHA256 of \"<X-WonderWhisper-Timestamp>.<raw body>\".")
        .settingsFootnote()
    }
  }

  private var headersSection: some View {
    Section {
      ForEach($headerDrafts) { $header in
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          TextField("Header", text: $header.name, prompt: Text("Authorization"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
          SecureField("Value", text: $header.value, prompt: Text("Value"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
          Button {
            headerDrafts.removeAll { $0.id == header.id }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove header \(header.name)")
        }
      }
      HStack {
        Spacer()
        Button("Add Header") {
          headerDrafts.append(HeaderDraft(name: "", value: ""))
        }
      }
    } header: {
      Text("Custom headers")
    } footer: {
      Text("Header values are stored in the Keychain. Content-Type and X-WonderWhisper-* "
        + "headers can't be overridden.")
        .settingsFootnote()
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Spacing.xSmall) {
      if !isNew {
        Button("Delete Webhook", role: .destructive) { confirmingDelete = true }
      }
      if let errorMessage {
        StatusBadge(.warning, errorMessage)
          .font(.footnote)
          .lineLimit(2)
      }
      Spacer()
      Button("Cancel", action: onClose)
        .keyboardShortcut(.cancelAction)
      Button("Save", action: save)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Actions

  private var urlMessage: String? {
    let trimmed = endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return MeetingWebhookURLValidator.validate(trimmed).message
  }

  private func loadHeaders() {
    guard !isNew else { return }
    do {
      let headers = try webhooks.headers(for: endpoint.id)
      loadedHeaders = headers
      headerDrafts = headers
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .map { HeaderDraft(name: $0.key, value: $0.value) }
    } catch {
      // Leave the stored headers alone: saving only replaces them if the user edits them.
      loadedHeaders = nil
      errorMessage = MeetingWebhookCredentialsError.userMessage
        + ". Stored headers are kept unless you add new ones."
    }
  }

  /// The header set to save, or nil to leave the stored one untouched. Unchanged headers,
  /// including headers that could not be read (`loaded` nil, no drafts), are never rewritten.
  static func headersToSave(
    loaded: [String: String]?,
    edited: [String: String],
    isNew: Bool
  ) -> [String: String]? {
    if isNew { return edited }
    guard let loaded else { return edited.isEmpty ? nil : edited }
    return loaded == edited ? nil : edited
  }

  private func save() {
    var headers: [String: String] = [:]
    for draft in headerDrafts {
      let name = draft.name.trimmingCharacters(in: .whitespaces)
      let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty || !value.isEmpty else { continue }
      guard !name.isEmpty else {
        errorMessage = "Every header value needs a header name."
        return
      }
      guard !value.isEmpty else {
        errorMessage = "Header \(name) needs a value."
        return
      }
      headers[name] = value
    }
    let secret: String?
    if !secretDraft.isEmpty {
      secret = secretDraft
    } else if clearsSecret {
      secret = ""
    } else {
      secret = nil
    }
    endpoint.maxBodyCharacters = MeetingWebhookEndpoint.clampedMaxBody(
      endpoint.maxBodyCharacters
    )
    let headersToSave = Self.headersToSave(
      loaded: loadedHeaders,
      edited: headers,
      isNew: isNew
    )
    if let message = webhooks.saveEndpoint(
      endpoint,
      signingSecret: secret,
      headers: headersToSave
    ) {
      errorMessage = message
      return
    }
    onClose()
  }
}
