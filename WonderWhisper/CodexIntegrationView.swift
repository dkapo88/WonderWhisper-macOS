import SwiftUI

struct CodexIntegrationView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var isTestingConnection = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        connectionSection
        hotkeySection
        behaviorSection
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var connectionSection: some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable Codex voice tasks", isOn: $vm.codexEnabled)

        TextField(CodexTaskDirectory.defaultRoot, text: $vm.codexRootFolder)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 520)

        Text("New tasks are created in a task folder inside today's date folder.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack(spacing: 10) {
          Button {
            testConnection()
          } label: {
            if isTestingConnection {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Test Codex", systemImage: "bolt.horizontal.circle")
            }
          }
          .disabled(isTestingConnection)

          if let status = vm.codexConnectionStatus {
            Text(status)
              .font(.callout)
              .foregroundColor(vm.codexConnectionSucceeded == true ? .green : .secondary)
              .textSelection(.enabled)
          }
        }

        Text("WonderWhisper uses Codex's local App Server and desktop task bridge. No API key is required.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var hotkeySection: some View {
    GroupBox("Dedicated Hotkey") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Activation key", selection: codexSelectionBinding) {
          Text("None").tag(HotkeyManager.Selection?.none)
          ForEach(HotkeyManager.Selection.allCases, id: \.self) { option in
            Text(option.displayName)
              .tag(Optional(option))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 300)

        Text("With no Codex response window open, the shortcut creates a new task. Otherwise it replies to the frontmost Codex response window.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var behaviorSection: some View {
    GroupBox("Task Behavior") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Pin new tasks in Codex", isOn: $vm.codexPinNewTasks)
          .toggleStyle(.checkbox)
          .help("Briefly opens the new task in Codex and uses its Pin Task shortcut.")

        Toggle("Monitor all projectless Codex tasks", isOn: $vm.codexMonitorProjectlessTasks)
          .toggleStyle(.checkbox)
          .help("Shows newly completed replies from projectless tasks created in either app.")

        Toggle("LLM post-processing", isOn: $vm.codexPostProcessingEnabled)
          .toggleStyle(.checkbox)
          .help("Clean the voice transcript with the Dictation prompt before sending.")

        Toggle("Copied text / clipboard", isOn: $vm.codexClipboardContextEnabled)
          .toggleStyle(.checkbox)
          .help("Attach recently copied text to Codex voice turns.")

        Stepper(
          "Clipboard freshness: \(Int(vm.codexClipboardTimeoutSeconds)) seconds",
          value: $vm.codexClipboardTimeoutSeconds,
          in: HermesClipboardContextPolicy.minimumRetentionWindow...HermesClipboardContextPolicy.maximumRetentionWindow,
          step: 1
        )
        .frame(maxWidth: 360, alignment: .leading)
        .disabled(!vm.codexClipboardContextEnabled)

        HStack(spacing: 10) {
          Button {
            vm.startCodexRecording()
          } label: {
            Label(
              vm.isCodexRecording ? "Send Recording" : "New Voice Task",
              systemImage: vm.isCodexRecording ? "paperplane.fill" : "mic.fill"
            )
          }
          .disabled(!vm.codexEnabled || vm.codexIsSending)

          if vm.codexIsSending {
            ProgressView()
              .controlSize(.small)
          }

          if vm.codexMonitorProjectlessTasks {
            Label("Monitoring projectless tasks", systemImage: "wave.3.right.circle")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        Text("Automatic pinning requires Accessibility permission. Codex's local integration APIs are experimental, so a future desktop update may require a compatibility adjustment.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var codexSelectionBinding: Binding<HotkeyManager.Selection?> {
    Binding(
      get: { vm.codexSelection },
      set: { vm.setCodexSelection($0) }
    )
  }

  private func testConnection() {
    isTestingConnection = true
    Task {
      await vm.testCodexConnection()
      await MainActor.run { isTestingConnection = false }
    }
  }
}
