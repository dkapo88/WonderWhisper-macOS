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

    private let hpOptions: [Int] = [0, 40, 50, 60, 80]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Text("Helps low-volume speech: enable pre-emphasis, use 50–60 Hz high-pass, RMS ≈ 0.06–0.07.")
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
