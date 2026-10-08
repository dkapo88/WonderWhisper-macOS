import SwiftUI

/// Settings → Integrations → Hermes (connection only; the chat stays in the main window).
struct HermesSettingsForm: View {
  @ObservedObject var vm: DictationViewModel
  @State private var isTestingHermes = false
  @State private var setupPromptCopied = false
  @State private var showsSetupPrompt = false

  var body: some View {
    SettingsPage {
      connectionSection
      contextSection
      setupSection
    }
  }

  private var connectionSection: some View {
    Section {
      Toggle("Enable Hermes agent", isOn: $vm.hermesAgentEnabled)

      LabeledContent {
        TextField("API base URL", text: $vm.hermesBaseURLString, prompt: Text("https://…"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 280)
      } label: {
        Text("API base URL")
        Text("Local gateway or remote server. URLs ending in /v1 also work.")
      }

      APIKeyRow(
        title: "API server key",
        alias: AppConfig.hermesAPIKeyAlias,
        prompt: "Bearer key",
        onSave: vm.saveHermesApiKey
      )

      LabeledContent {
        TextField(
          "Conversation prefix",
          text: $vm.hermesConversationName,
          prompt: Text(AppConfig.defaultHermesConversationName)
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
      } label: {
        Text("Conversation prefix")
        Text("Prefix for new Hermes conversation names.")
      }

      LabeledContent {
        TextField("Agent profile", text: $vm.hermesProfileName, prompt: Text("Server default"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
      } label: {
        Text("Agent profile")
        Text("Sent as the API model and checked by Test. Blank uses the server default.")
      }

      NumberStepperRow(
        title: "Request timeout",
        value: timeoutMinutesBinding,
        range: Self.timeoutMinuteRange,
        unit: "min"
      )

      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.small) {
          if let status = vm.hermesConnectionStatus {
            StatusBadge.connection(vm.hermesConnectionSucceeded, status)
              .textSelection(.enabled)
          }
          Button(action: testConnection) {
            if isTestingHermes {
              ProgressView().controlSize(.small)
            } else {
              Text("Test")
            }
          }
          .disabled(isTestingHermes)
          .accessibilityLabel("Test Hermes connection")
        }
      } label: {
        Text("Connection")
      }
    } header: {
      Text("Hermes")
    }
  }

  private var contextSection: some View {
    Section {
      Toggle("Screen text", isOn: $vm.hermesScreenContextEnabled)
      Toggle("Screenshot image", isOn: $vm.hermesScreenshotEnabled)
      Toggle("Copied text", isOn: $vm.hermesClipboardContextEnabled)
      NumberStepperRow(
        title: "Copied text freshness",
        subtitle: "Only included when the Hermes shortcut starts within this window.",
        value: $vm.hermesClipboardTimeoutSeconds,
        range: HermesClipboardContextPolicy.minimumRetentionWindow
          ... HermesClipboardContextPolicy.maximumRetentionWindow,
        unit: "s"
      )
      .disabled(!vm.hermesClipboardContextEnabled)
      Toggle(isOn: $vm.hermesPostProcessingEnabled) {
        Text("LLM post-processing")
        Text("Clean the transcript with the Dictation prompt before sending.")
      }
    } header: {
      Text("Context sent with voice turns")
    } footer: {
      Text("Set the Hermes shortcut in Settings → Shortcuts.")
        .settingsFootnote()
    }
  }

  private var setupSection: some View {
    Section {
      LabeledContent {
        Button {
          HermesResponseClipboard.copyRaw(Self.hermesSetupPrompt)
          setupPromptCopied = true
          Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            setupPromptCopied = false
          }
        } label: {
          Label(
            setupPromptCopied ? "Copied" : "Copy Prompt",
            systemImage: setupPromptCopied ? "checkmark" : "doc.on.doc"
          )
        }
      } label: {
        Text("Setup prompt")
        Text("Give this to Hermes to get the values for this page.")
      }
      DisclosureGroup("Show prompt", isExpanded: $showsSetupPrompt) {
        Text(Self.hermesSetupPrompt)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } header: {
      Text("Setup")
    }
  }

  private var timeoutMinutesBinding: Binding<Double> {
    Binding(
      get: {
        let minutes = (vm.hermesTimeoutSeconds / 60).rounded()
        return min(max(minutes, Self.timeoutMinuteRange.lowerBound), Self.timeoutMinuteRange.upperBound)
      },
      set: { minutes in
        let clamped = min(
          max(minutes.rounded(), Self.timeoutMinuteRange.lowerBound),
          Self.timeoutMinuteRange.upperBound
        )
        vm.hermesTimeoutSeconds = clamped * 60
      }
    )
  }

  private static let timeoutMinuteRange: ClosedRange<Double> = {
    let lower = max(1, (HermesAgentSettings.minimumTimeout / 60).rounded(.up))
    let upper = max(lower, (HermesAgentSettings.maximumTimeout / 60).rounded(.down))
    return lower...upper
  }()

  private func testConnection() {
    isTestingHermes = true
    Task {
      await vm.testHermesConnection()
      await MainActor.run { isTestingHermes = false }
    }
  }

  static let hermesSetupPrompt = """
I am setting up WonderWhisper, a macOS voice client that connects to a Hermes Agent API server.

Please help me find the exact connection settings I should enter in the WonderWhisper settings page:

1. Hermes API base URL
   * Give me the base URL for the Hermes API server.
   * Tell me whether I should enter the root URL or the `/v1` URL.
   * Confirm whether the URL is local-only, LAN/VPN-only, or publicly reachable.

2. API server key
   * Tell me whether this Hermes server requires a bearer API key.
   * If a key already exists, tell me where to retrieve it securely.
   * If I need to create one, give me the exact command or config steps.
   * Do not print a production secret unless I explicitly ask you to reveal it.

3. Conversation prefix
   * Recommend a short conversation prefix for this Mac client.
   * Explain whether the prefix affects session persistence, routing, or only naming.

4. Agent profile
   * List the available Hermes agent profiles/models from `/v1/models`.
   * Tell me what value to put in the Agent profile field.
   * If the field should be blank to use the server default profile, say that clearly.

Please return the answer as a small table with these exact fields:
* Hermes API base URL
* API key source or creation command
* Conversation prefix
* Agent profile
* Notes
"""
}
