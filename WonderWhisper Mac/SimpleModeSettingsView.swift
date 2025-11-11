import SwiftUI
import AppKit
#if canImport(FluidAudio)
import FluidAudio
#endif

struct SimpleModeSettingsView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var openRouterKeyInput: String = ""
  @State private var groqKeyInput: String = ""
  @State private var customModelDraft: String = ""
  @State private var isDownloadingParakeet: Bool = false

  private let keychain = KeychainService()

  private var hasOpenRouterKey: Bool {
    keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias) != nil
  }
  private var hasGroqKey: Bool {
    keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) != nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        llmSection
        voiceEngineSection
        customModelSection
        openRouterSection
        groqSection
        parakeetSection
        audioSection
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var voiceEngineSection: some View {
    GroupBox("Transcription engine") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Engine", selection: $vm.simpleVoiceEngine) {
          ForEach(SimpleVoiceEngine.allCases) { engine in
            Text(engine.displayName).tag(engine)
          }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        Text(vm.simpleVoiceEngine.detail)
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var llmSection: some View {
    GroupBox("Language model") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable LLM post-processing", isOn: $vm.simpleLLMEnabled)
          .help("Turn this off to use raw transcription without additional formatting.")

        VStack(alignment: .leading, spacing: 6) {
          Text("Default OpenRouter model")
            .font(.callout.weight(.semibold))
          Picker("Model", selection: $vm.simpleSelectedModel) {
            ForEach(vm.simpleModelOptions) { option in
              Text(option.displayName).tag(option.modelID)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 360)
          Text("Applies to Dictate and Command modes when LLM output is enabled.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding(.top, 4)
    }
  }

  private var customModelSection: some View {
    GroupBox("Custom models") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Add additional OpenRouter model IDs to the picker above.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack(spacing: 8) {
          TextField("provider/model-id", text: $customModelDraft)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
          Button("Add") {
            vm.addCustomSimpleModel(id: customModelDraft)
            customModelDraft = ""
          }
          .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if vm.simpleCustomModels.isEmpty {
          Text("No additional models added yet.")
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(vm.simpleCustomModels, id: \.self) { model in
              HStack {
                Text(model)
                  .font(.callout)
                Spacer()
                Button(role: .destructive) {
                  vm.removeCustomSimpleModel(id: model)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
              }
              .padding(.vertical, 4)
              Divider()
            }
          }
        }
      }
      .padding(.top, 4)
    }
  }

  private var openRouterSection: some View {
    GroupBox("OpenRouter API key") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Text(hasOpenRouterKey ? "Status: Saved" : "Status: Missing")
            .font(.callout.weight(.semibold))
            .foregroundColor(hasOpenRouterKey ? .green : .red)
          if hasOpenRouterKey {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
          }
        }

        SecureField("Paste OpenRouter API key", text: $openRouterKeyInput)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 360)

        Button("Save key") {
          vm.saveOpenRouterKey(openRouterKeyInput)
          openRouterKeyInput = ""
        }
        .disabled(openRouterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.top, 4)
    }
  }

  private var groqSection: some View {
    GroupBox("Groq API key") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Text(hasGroqKey ? "Status: Saved" : "Status: Missing")
            .font(.callout.weight(.semibold))
            .foregroundColor(hasGroqKey ? .green : .red)
          if hasGroqKey {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
          }
        }

        SecureField("Paste Groq API key", text: $groqKeyInput)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 360)

        Button("Save key") {
          vm.saveGroqApiKey(groqKeyInput)
          groqKeyInput = ""
        }
        .disabled(groqKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.top, 4)
    }
  }

  private var parakeetSection: some View {
    GroupBox("Parakeet voice model") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          statusLabel(title: "Framework", ok: ParakeetManager.isLinked)
          statusLabel(title: "Models", ok: ParakeetManager.modelsPresent())
        }

        HStack(spacing: 12) {
          Button(isDownloadingParakeet ? "Downloading…" : "Download / Update Parakeet") {
            downloadParakeet()
          }
          .disabled(isDownloadingParakeet)

          Button("Show in Finder") {
            NSWorkspace.shared.selectFile(ParakeetManager.effectiveModelsDirectory.path, inFileViewerRootedAtPath: "")
          }
        }

        Text("Simple Mode always uses Parakeet v3 locally for transcription. Downloading ensures the model is ready before the first dictation.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var audioSection: some View {
    GroupBox("Audio feedback") {
      VStack(alignment: .leading, spacing: 8) {
        Text("Chime volume")
          .font(.callout.weight(.semibold))
        Slider(value: $vm.chimeVolume, in: 0...1)
          .frame(maxWidth: 360)
        Text("Controls the start/stop chime loudness relative to system volume.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private func statusLabel(title: String, ok: Bool) -> some View {
    Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
      .foregroundColor(ok ? .green : .red)
      .font(.caption.weight(.semibold))
  }

  private func downloadParakeet() {
    #if canImport(FluidAudio)
    isDownloadingParakeet = true
    Task {
      defer { isDownloadingParakeet = false }
      do {
        _ = try await AsrModels.downloadAndLoad(version: .v2)
        _ = try await AsrModels.downloadAndLoad(version: .v3)
      } catch {
        // Swallow errors; status badges reflect current state.
      }
    }
    #endif
  }
}

#Preview {
  SimpleModeSettingsView(vm: DictationViewModel())
}
