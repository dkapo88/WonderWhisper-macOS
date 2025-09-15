import SwiftUI

struct ParakeetAdvancedSettingsView: View {
    @AppStorage("parakeet.preemphasis") private var preEmphasisEnabled: Bool = true
    @AppStorage("parakeet.highpass.hz") private var highPassHz: Int = 60
    @AppStorage("parakeet.rms.target") private var targetRMS: Double = 0.06
    @AppStorage("parakeet.vad.enabled") private var vadEnabled: Bool = true
    @AppStorage("parakeet.vad.threshold") private var vadThreshold: Double = 0.5

    private let hpOptions: [Int] = [0, 40, 50, 60, 80]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
