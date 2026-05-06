import SwiftUI

struct HermesAgentView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var hermesKeyInput: String = ""
  @State private var isTestingHermes: Bool = false
  @State private var hasSavedKey: Bool = false

  private let keychain = KeychainService()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        connectionSection
        hotkeySection
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear(perform: refreshKeyStatus)
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
}

#Preview {
  HermesAgentView(vm: DictationViewModel())
}
