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
  @State private var showModelBrowser: Bool = false

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
        voiceEngineSection
        combinedLLMSection
        openRouterSection
        groqSection
        parakeetSection
        audioSection
        recordingSection
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showModelBrowser) {
      OpenRouterModelBrowserView(vm: vm)
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

  private var combinedLLMSection: some View {
    GroupBox("Language model") {
      VStack(alignment: .leading, spacing: 16) {
        Toggle("Enable LLM post-processing", isOn: $vm.simpleLLMEnabled)
          .help("Turn this off to use raw transcription without additional formatting.")
        
        Divider()
        
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Favorite Models")
              .font(.callout.weight(.semibold))
            Text("Manage your OpenRouter models. Click a model to set it as active.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Button(action: { showModelBrowser = true }) {
            HStack(spacing: 4) {
              Image(systemName: "magnifyingglass")
              Text("Browse Models")
            }
          }
        }

        if vm.favoriteOpenRouterModels.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("No favorites yet. Browse the OpenRouter catalog to add models.")
              .font(.callout)
              .foregroundColor(.secondary)
          }
          .padding(.vertical, 8)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(vm.favoriteOpenRouterModels) { favorite in
              Button(action: {
                if vm.simpleSelectedModel != favorite.id {
                  vm.setActiveOpenRouterModel(id: favorite.id)
                }
              }) {
                HStack(spacing: 8) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.name)
                      .font(.callout.weight(.medium))
                      .foregroundColor(.primary)
                    Text(favorite.id)
                      .font(.caption2)
                      .foregroundColor(.secondary)
                  }
                  
                  Spacer()
                  
                  if vm.simpleSelectedModel == favorite.id {
                    Label("Active", systemImage: "checkmark.circle.fill")
                      .font(.caption.weight(.semibold))
                      .foregroundColor(.green)
                  }
                  
                  Button(role: .destructive, action: {
                    vm.removeFavoriteOpenRouterModel(id: favorite.id)
                  }) {
                    Image(systemName: "trash")
                      .foregroundColor(.red)
                  }
                  .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(vm.simpleSelectedModel == favorite.id ? Color.green.opacity(0.1) : Color.clear)
                .cornerRadius(6)
              }
              .buttonStyle(.plain)
              
              if favorite.id != vm.favoriteOpenRouterModels.last?.id {
                Divider()
              }
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

  private var recordingSection: some View {
    GroupBox("Recording") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Auto-mute system audio during recording", isOn: $vm.autoMuteEnabled)
          .help("Automatically mutes system audio when recording starts and unmutes when recording stops.")
        
        Text("When enabled, system audio will be muted before recording starts and unmuted after recording stops. This prevents music, video calls, or other audio from interfering with transcription.")
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
