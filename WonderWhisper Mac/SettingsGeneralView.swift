import SwiftUI

struct SettingsGeneralView: View {
    @ObservedObject var vm: DictationViewModel
    
    // Performance settings using @AppStorage for automatic UserDefaults sync
    @AppStorage("audio.recording.format") private var selectedAudioFormat: String = "wav"
    @AppStorage("audio.preprocess.smart") private var smartPreprocessingEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox("Insertion") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use AX direct insertion (faster when supported)", isOn: $vm.useAXInsertion)
                            .help("Requires Accessibility permission. Falls back to paste if not supported.")
                        Toggle("Paste with formatting (HTML/RTF)", isOn: $vm.pasteFormatted)
                            .help("Preserves paragraph spacing in apps that support rich text; falls back to plain text elsewhere.")

                        Divider()

                        ShortcutRecorderView(shortcut: $vm.pasteShortcut)
                        Text("Default: ⌃⌘V. Pastes last output (LLM preferred).")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

                        #if DEBUG
                        Divider()

                        Text("OCR Debugging (Debug Build Only)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Enable OCR debug logging", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "ocr.debug") },
                            set: { UserDefaults.standard.set($0, forKey: "ocr.debug") }
                        ))
                        .help("Logs detailed OCR processing information to help diagnose capture issues.")

                        Toggle("Save captured images to Desktop", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "ocr.saveImages") },
                            set: { UserDefaults.standard.set($0, forKey: "ocr.saveImages") }
                        ))
                        .help("Saves screenshots used for OCR to Desktop for analysis. Use sparingly as this creates many files.")

                        Toggle("Force accurate OCR for all apps", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "ocr.forceAccurate") },
                            set: { UserDefaults.standard.set($0, forKey: "ocr.forceAccurate") }
                        ))
                        .help("Always use the most accurate (but slower) OCR mode regardless of app type.")

                        Toggle("Extended OCR timeout", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "ocr.extendedTimeout") },
                            set: { UserDefaults.standard.set($0, forKey: "ocr.extendedTimeout") }
                        ))
                        .help("Use longer timeouts for OCR processing. May help with complex content but increases latency.")
                        #endif
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}
