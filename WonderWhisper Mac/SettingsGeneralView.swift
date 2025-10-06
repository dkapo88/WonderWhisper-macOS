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
                        Toggle("Use direct insertion when available", isOn: $vm.useAXInsertion)
                            .help("Requires Accessibility permission. Falls back to clipboard paste if not supported.")
                        Text("Inserts text via Accessibility APIs for lower latency in apps that support it.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Paste with formatting (HTML/RTF)", isOn: $vm.pasteFormatted)
                            .help("Preserves paragraph spacing in apps that support rich text; falls back to plain text elsewhere.")
                        Text("Keeps rich text when possible. Turn off for strictly plain text.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Paste Last Transcript shortcut")
                                Text("Set a global hotkey to paste your most recent output. Uses cleaned LLM output when available; otherwise pastes the raw transcript. Default: ⌃⌘V")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            ShortcutRecorderView(shortcut: $vm.pasteShortcut)
                        }
                    }
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Audio enhancement (beta)", isOn: $vm.audioEnhancementEnabled)
                            .help("Applies a high‑pass filter, pre‑emphasis, and loudness normalization before transcription to improve clarity in noisy/low‑volume conditions.")
                        Text("Improves clarity in noisy or low‑volume recordings at a minor CPU cost.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Voice processing (noise suppression + AGC)", isOn: $vm.voiceProcessingEnabled)
                            .help("Uses a live EQ + dynamics chain, and avoids auto‑raising mic gain to reduce pumping and background noise. Intended for live streaming capture.")
                        Text("Noise suppression and gentle AGC for live capture. Skips auto gain boosts to prevent fighting AGC.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Audio recording format selection for better compression
                        LabeledContent {
                            Picker("Recording Format", selection: $selectedAudioFormat) {
                                Text("WAV (largest, compatible)").tag("wav")
                                Text("AAC/M4A (smaller)").tag("aac")
                                Text("MP3 (smallest)").tag("mp3")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(maxWidth: 220)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recording format")
                                Text("Choose file size vs. compatibility. MP3/AAC upload faster; WAV is largest but widely supported.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                GroupBox("Network & Transcription") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            Stepper(value: $vm.transcriptionTimeoutSeconds, in: 5...120, step: 1) {
                                Text("\(Int(vm.transcriptionTimeoutSeconds))s")
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: 160)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Transcription timeout")
                                Text("Maximum time to wait before failing a request. Retries follow network policy.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Toggle("Force HTTP/2 for uploads (experimental)", isOn: $vm.forceHTTP2Uploads)
                            .help("Bypasses HTTP/3/QUIC for multipart uploads to avoid stalls on some networks.")
                        Text("Useful if your network has trouble with HTTP/3/QUIC. Leave off unless uploads stall.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                GroupBox("Performance Optimizations") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Smart audio preprocessing", isOn: $smartPreprocessingEnabled)
                            .help("Only applies audio enhancement when needed based on quality analysis. Saves processing time for clean audio.")
                        
                        Text("Automatically skips enhancement on clean audio to reduce latency. Experimental.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                GroupBox("Screen Context") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Accurate OCR for code editors", isOn: $vm.accurateOCRForEditors)
                            .help("Improves text capture in editors like Cursor/VS Code/Xcode at the cost of a small latency increase (~0.2–0.6s). Turn off to prioritize speed.")
                        Text("Improves capture fidelity in IDEs like Cursor, VS Code, and Xcode with a small latency trade‑off.")
                            .font(.caption)
                            .foregroundColor(.secondary)

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
