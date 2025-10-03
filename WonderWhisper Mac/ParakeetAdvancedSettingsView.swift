import SwiftUI

struct ParakeetAdvancedSettingsView: View {
    @AppStorage("parakeet.version") private var version: String = "v3" // "v2" or "v3"
    @AppStorage("parakeet.preemphasis") private var preEmphasisEnabled: Bool = true
    @AppStorage("parakeet.highpass.hz") private var highPassHz: Int = 60
    @AppStorage("parakeet.rms.target") private var targetRMS: Double = 0.06
    @AppStorage("parakeet.vad.enabled") private var vadEnabled: Bool = true
    @AppStorage("parakeet.vad.threshold") private var vadThreshold: Double = 0.5
    @AppStorage("parakeet.vad.minSpeech") private var vadMinSpeech: Double = 0.25
    @AppStorage("parakeet.vad.minSilence") private var vadMinSilence: Double = 0.35
    @AppStorage("parakeet.vad.padding") private var vadPadding: Double = 0.10
    @AppStorage("parakeet.auto.enabled") private var autoEnabled: Bool = false
    @AppStorage("parakeet.auto.lastProfile") private var autoLastProfile: String = ""
    @AppStorage("parakeet.auto.lastSnrDb") private var autoLastSnrDb: Double = 0
    @AppStorage("parakeet.auto.lastLFR") private var autoLastLFR: Double = 0
    @AppStorage("parakeet.auto.lastHP") private var autoLastHP: Int = 0
    @AppStorage("parakeet.auto.lastRMS") private var autoLastRMS: Double = 0
    @AppStorage("parakeet.auto.lastVadT") private var autoLastVadT: Double = 0
    @AppStorage("parakeet.auto.lastMinSpeech") private var autoLastMinSpeech: Double = 0
    @AppStorage("parakeet.auto.lastMinSilence") private var autoLastMinSilence: Double = 0
    @AppStorage("parakeet.auto.lastPadding") private var autoLastPadding: Double = 0

    private let hpOptions: [Int] = [0, 40, 50, 60, 80]

    // MARK: - Presets
    // These presets are informed by internal testing and the VoiceInk
    // repository (see repomix-output.xml) where Silero VAD threshold ≈ 0.7
    // proved robust in noisy environments. Target RMS of 0.06–0.07 with
    // pre-emphasis and a 50–60 Hz high‑pass works well for general speech.
    private struct Preset: Identifiable {
        let id = UUID()
        let name: String
        let preEmphasis: Bool
        let highPass: Int
        let targetRMS: Double
        let vadEnabled: Bool
        let vadThreshold: Double
        let minSpeech: Double
        let minSilence: Double
        let padding: Double
    }

    private var presets: [Preset] {
        [
            // Balanced default for most rooms and mics
            Preset(
                name: "Balanced",
                preEmphasis: true,
                highPass: 60,
                targetRMS: 0.065,
                vadEnabled: true,
                vadThreshold: 0.50,
                minSpeech: 0.25,
                minSilence: 0.35,
                padding: 0.10
            ),
            // Capture softer speech in quiet spaces; slightly lower VAD gate
            Preset(
                name: "Quiet room",
                preEmphasis: true,
                highPass: 50,
                targetRMS: 0.070,
                vadEnabled: true,
                vadThreshold: 0.35,
                minSpeech: 0.20,
                minSilence: 0.30,
                padding: 0.10
            ),
            // Suppress background chatter/keyboard; higher VAD gate
            Preset(
                name: "Noisy room",
                preEmphasis: true,
                highPass: 80,
                targetRMS: 0.060,
                vadEnabled: true,
                vadThreshold: 0.70, // VoiceInk used ~0.7 for robustness
                minSpeech: 0.30,
                minSilence: 0.50,
                padding: 0.15
            ),
            // Conservative segmentation for long-form uploads; fewer false starts
            Preset(
                name: "Long-form",
                preEmphasis: true,
                highPass: 60,
                targetRMS: 0.060,
                vadEnabled: true,
                vadThreshold: 0.65,
                minSpeech: 0.30,
                minSilence: 0.75,
                padding: 0.10
            )
        ]
    }

    private func apply(_ p: Preset) {
        preEmphasisEnabled = p.preEmphasis
        highPassHz = p.highPass
        targetRMS = p.targetRMS
        vadEnabled = p.vadEnabled
        vadThreshold = p.vadThreshold
        vadMinSpeech = p.minSpeech
        vadMinSilence = p.minSilence
        vadPadding = p.padding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Preset buttons
            HStack(spacing: 8) {
                Text("Presets")
                ForEach(presets) { p in
                    Button(p.name) { apply(p) }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .help("Quickly apply recommended settings for common environments.")

            Toggle("Auto-adjust from environment", isOn: $autoEnabled)
                .help("Analyze input audio and adjust high‑pass, target RMS and VAD settings automatically. Uses heuristics similar to the presets.")
            if !autoLastProfile.isEmpty {
                Text("Auto (last): \(autoLastProfile.capitalized) • SNR \(String(format: "%.1f", autoLastSnrDb)) dB • Rumble \(String(format: "%.2f", autoLastLFR))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Effective: HP \(autoLastHP) Hz • RMS \(String(format: "%.3f", autoLastRMS)) • VAD T \(String(format: "%.2f", autoLastVadT))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider()

            HStack {
                Text("Engine version")
                Spacer()
                Picker("Engine version", selection: $version) {
                    Text("V2 (English)").tag("v2")
                    Text("V3 (Multilingual)").tag("v3")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .help("Choose Parakeet TDT version. V2 is English-only with higher recall; V3 supports 25 languages.")
            }
            Divider()
            Toggle("Pre-emphasis (0.97)", isOn: $preEmphasisEnabled)
            HStack {
                Text("High-pass cutoff")
                Spacer()
                Picker("High-pass cutoff", selection: $highPassHz) {
                    Text("Off").tag(0)
                    ForEach(hpOptions.filter { $0 > 0 }, id: \.self) { v in
                        Text("\(v) Hz").tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Target RMS")
                    Spacer()
                    Text(String(format: "%.3f", targetRMS)).monospacedDigit()
                }
                Slider(value: $targetRMS, in: 0.05...0.08, step: 0.005)
            }
            Divider()
            Toggle("Voice Activity Detection (Silero)", isOn: $vadEnabled)
            HStack {
                Text("VAD Threshold")
                Spacer()
                Text(String(format: "%.2f", vadThreshold)).monospacedDigit()
            }
            Slider(value: $vadThreshold, in: 0.2...0.8, step: 0.05)
            HStack {
                Text("Min speech (s)")
                Spacer()
                Text(String(format: "%.2f", vadMinSpeech)).monospacedDigit()
            }
            Slider(value: $vadMinSpeech, in: 0.10...0.60, step: 0.05)
            HStack {
                Text("Min silence (s)")
                Spacer()
                Text(String(format: "%.2f", vadMinSilence)).monospacedDigit()
            }
            Slider(value: $vadMinSilence, in: 0.20...0.80, step: 0.05)
            HStack {
                Text("Padding (s)")
                Spacer()
                Text(String(format: "%.2f", vadPadding)).monospacedDigit()
            }
            Slider(value: $vadPadding, in: 0.05...0.40, step: 0.05)
            Text("Tips: pre-emphasis + 50–60 Hz high‑pass + RMS ≈ 0.06–0.07. Increase VAD threshold in noise; lower it for quiet rooms.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(6)
    }
}

#Preview {
    ParakeetAdvancedSettingsView()
        .padding()
        .frame(width: 520)
}
