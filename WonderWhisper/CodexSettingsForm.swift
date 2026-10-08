import SwiftUI

/// Settings → Integrations → Codex.
struct CodexSettingsForm: View {
  @ObservedObject var vm: DictationViewModel
  @State private var isTestingConnection = false

  var body: some View {
    SettingsPage {
      Section {
        Toggle("Enable Codex voice tasks", isOn: $vm.codexEnabled)

        LabeledContent {
          TextField("Task folder", text: $vm.codexRootFolder, prompt: Text(CodexTaskDirectory.defaultRoot))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
        } label: {
          Text("Task folder")
          Text("New tasks go in a task folder inside today's date folder.")
        }

        LabeledContent {
          HStack(spacing: DesignTokens.Spacing.small) {
            if let status = vm.codexConnectionStatus {
              StatusBadge.connection(vm.codexConnectionSucceeded, status)
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
            .accessibilityLabel("Test Codex connection")
          }
        } label: {
          Text("Connection")
          Text("Uses Codex's local App Server. No API key needed.")
        }
      } header: {
        Text("Codex")
      }

      Section {
        Toggle(isOn: $vm.codexPostProcessingEnabled) {
          Text("LLM post-processing")
          Text("Clean the transcript with the Dictation prompt before sending.")
        }
        Toggle(isOn: $vm.codexClipboardContextEnabled) {
          Text("Include copied text")
          Text("Attach recently copied text to voice turns.")
        }
        NumberStepperRow(
          title: "Copied text freshness",
          value: $vm.codexClipboardTimeoutSeconds,
          range: HermesClipboardContextPolicy.minimumRetentionWindow
            ... HermesClipboardContextPolicy.maximumRetentionWindow,
          unit: "s"
        )
        .disabled(!vm.codexClipboardContextEnabled)
      } header: {
        Text("Voice turns")
      }

      Section {
        Toggle(isOn: $vm.codexPinNewTasks) {
          Text("Pin new tasks in Codex")
          Text("Briefly opens the new task and uses Codex's Pin Task shortcut.")
        }
        Toggle(isOn: $vm.codexMonitorProjectlessTasks) {
          Text("Monitor all projectless tasks")
          Text("Shows newly completed replies from projectless tasks created in either app.")
        }
        LabeledContent {
          HStack(spacing: DesignTokens.Spacing.small) {
            if vm.codexIsSending {
              ProgressView().controlSize(.small)
            }
            Button {
              vm.startCodexRecording()
            } label: {
              Label(
                vm.isCodexRecording ? "Send Recording" : "New Voice Task",
                systemImage: vm.isCodexRecording ? "paperplane" : "mic"
              )
            }
            .disabled(!vm.codexEnabled || vm.codexIsSending)
          }
        } label: {
          Text("Try it")
          Text("Set the Codex shortcut in Settings → Shortcuts.")
        }
      } header: {
        Text("Tasks")
      } footer: {
        Text("Automatic pinning needs Accessibility permission. Codex's local APIs are "
          + "experimental, so a Codex update may need a compatibility fix.")
          .settingsFootnote()
      }
    }
  }

  private func testConnection() {
    isTestingConnection = true
    Task {
      await vm.testCodexConnection()
      await MainActor.run { isTestingConnection = false }
    }
  }
}
