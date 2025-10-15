import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var vm: DictationViewModel

    @State private var apiKeyText: String = ""
    @State private var showAXInfo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3)
                .bold()

            GroupBox("API Keys") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Groq API Key").font(.subheadline)
                        SecureField("Enter Groq API Key", text: $apiKeyText)
                        HStack {
                            Button("Save Groq Key") { vm.saveGroqApiKey(apiKeyText); apiKeyText = "" }
                            Text("Stored as \(AppConfig.groqAPIKeyAlias)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AssemblyAI API Key").font(.subheadline)
                        SecureField("Enter AssemblyAI API Key", text: $vm.assemblyAIKeyInput)
                        HStack {
                            Button("Save AssemblyAI Key") { vm.saveAssemblyAIKey(vm.assemblyAIKeyInput); vm.assemblyAIKeyInput = "" }
                            Text("Stored as \(AppConfig.assemblyAIAPIKeyAlias)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Global Shortcut") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Shortcut", selection: $vm.hotkeySelection) {
                        ForEach(HotkeyManager.Selection.allCases, id: \.self) { sel in
                            Text(sel.displayName).tag(sel)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: vm.hotkeySelection) { _, newValue in
                        showAXInfo = newValue.requiresAX && !Self.isAXTrusted()
                    }
                    if showAXInfo {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This shortcut requires Accessibility permission (for modifier/Fn detection).")
                                .font(.caption)
                            HStack(spacing: 8) {
                                Button("Open Accessibility Settings") { Self.openAXSettings() }
                                Text("System Settings → Privacy & Security → Accessibility")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Transcription & LLM") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Voice model", selection: $vm.transcriptionModel) {
                        Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                        Text("whisper-large-v3").tag("whisper-large-v3")
                        Text("distil-whisper-large-v3-en").tag("distil-whisper-large-v3-en")
                        Text("OpenAI · gpt-4o-mini-transcribe").tag("gpt-4o-mini-transcribe")
                        Text("OpenAI · gpt-4o-transcribe").tag("gpt-4o-transcribe")
                        Text("OpenAI · whisper-1").tag("whisper-1")
                    }
                    Toggle("Post-processing with LLM", isOn: $vm.llmEnabled)
                    Toggle("Include screen context", isOn: $vm.screenContextEnabled)
                        .help("When off, no screenshot, selection, OCR text, or app context is collected or used by the LLM. Tags remain empty.")
                    Toggle("Include clipboard context (last 10 seconds)", isOn: $vm.clipboardContextEnabled)
                        .help("Send clipboard text copied within 10 seconds before recording inside <CLIPBOARD> tags.")

                    Picker("LLM model", selection: $vm.llmModel) {
                        Text("moonshotai/kimi-k2-instruct").tag("moonshotai/kimi-k2-instruct")
                        Text("openai/gpt-oss-120b").tag("openai/gpt-oss-120b")
                    }
                    Toggle("Use AX direct insertion (faster when supported)", isOn: $vm.useAXInsertion)
                        .help("Requires Accessibility permission. Falls back to paste if not supported.")
                }
            }

            GroupBox("Vocabulary & Text Replacements") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom vocabulary (comma-separated)")
                    TextField("e.g. Groq, Kimi, WonderWhisper", text: $vm.vocabCustom)
                    Text("Text replacements (from=to per line; applied on-device after LLM)")
                    TextEditor(text: $vm.vocabSpelling)
                        .frame(minHeight: 80)
                        .border(Color.gray.opacity(0.2))
                }
            }

            Spacer()
        }
        .padding(16)
        .onAppear {
            showAXInfo = vm.hotkeySelection.requiresAX && !Self.isAXTrusted()
        }
    }

    private static func isAXTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
