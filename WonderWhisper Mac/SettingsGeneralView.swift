import SwiftUI
import ApplicationServices

struct SettingsGeneralView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var apiKeyText: String = ""
    @State private var showAXInfo: Bool = false
    
    // Performance settings using @AppStorage for automatic UserDefaults sync
    @AppStorage("audio.recording.format") private var selectedAudioFormat: String = "wav"
    @AppStorage("audio.preprocess.smart") private var smartPreprocessingEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Groq API Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Enter Groq API Key", text: $apiKeyText)
                        HStack {
                            Button("Save API Key") { vm.saveGroqApiKey(apiKeyText); apiKeyText = "" }
                            Text("Stored in Keychain as \(AppConfig.groqAPIKeyAlias)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Insertion") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use AX direct insertion (faster when supported)", isOn: $vm.useAXInsertion)
                            .help("Requires Accessibility permission. Falls back to paste if not supported.")
                        Toggle("Paste with formatting (HTML/RTF)", isOn: $vm.pasteFormatted)
                            .help("Preserves paragraph spacing in apps that support rich text; falls back to plain text elsewhere.")
                    }
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Audio enhancement (beta)", isOn: $vm.audioEnhancementEnabled)
                            .help("Applies a subtle high‑pass filter, pre‑emphasis, and loudness normalization before transcription to improve clarity in noisy/low‑volume conditions.")
                        
                        // Audio recording format selection for better compression
                        HStack {
                            Text("Recording format")
                            Spacer()
                            Picker("Recording Format", selection: $selectedAudioFormat) {
                                Text("WAV (largest, compatible)").tag("wav")
                                Text("AAC/M4A (smaller)").tag("aac")  
                                Text("MP3 (aggressive AAC, smallest)").tag("mp3")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(maxWidth: 200)
                        }
                        .help("MP3 uses aggressive AAC compression (16kbps) for 75% smaller uploads. AAC uses standard 32kbps compression.")
                    }
                }

                GroupBox("Network & Transcription") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcription timeout")
                            Spacer()
                            Stepper(value: $vm.transcriptionTimeoutSeconds, in: 5...120, step: 1) {
                                Text("\(Int(vm.transcriptionTimeoutSeconds))s")
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: 160)
                        }
                        .help("If no response within this time, the request fails and will be retried per network policy.")

                        Toggle("Force HTTP/2 for uploads (experimental)", isOn: $vm.forceHTTP2Uploads)
                            .help("Bypasses HTTP/3/QUIC for multipart uploads to avoid network stalls on some networks.")
                    }
                }
                
                GroupBox("Performance Optimizations") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Smart audio preprocessing", isOn: $smartPreprocessingEnabled)
                            .help("Only applies audio enhancement when needed based on quality analysis. Saves processing time for clean audio.")
                        
                        Text("⚡ This experimental feature can improve transcription speed by skipping unnecessary processing on clean audio.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                GroupBox("Screen Context") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Accurate OCR for code editors", isOn: $vm.accurateOCRForEditors)
                            .help("Improves text capture in editors like Cursor/VS Code/Xcode at the cost of a small latency increase (~0.2–0.6s). Turn off to prioritize speed.")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear { showAXInfo = vm.hotkeySelection.requiresAX && !Self.isAXTrusted() }
    }

    private static func isAXTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
