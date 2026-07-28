import CoreGraphics
import Testing
@testable import WonderWhisper

struct AudioVisualizerSensitivityTests {
  @Test func ambientLevelsAreGatedBeforeVisualBoosting() {
    #expect(AudioVisualizerSensitivity.gatedLevel(0.01) == 0)
  }

  @Test func lowSpeechLevelsAreNotOverBoosted() {
    let boosted = AudioVisualizerSensitivity.boostedLevel(0.04)

    #expect(boosted < 0.14)
  }

  /// Dictation converts AVAudioRecorder dB meters into linear amplitude and shares the
  /// meeting response curve, so equivalent audio must produce an equivalent level.
  @Test func dictationAndMeetingMetersAgreeOnTheSameAudio() {
    let rms: Float = 0.12
    let peak: Float = 0.3

    let shared = MeetingAudioMeter.level(rms: rms, peak: peak)
    let fromSamples = MeetingAudioMeter.level(from: [peak, rms, -rms, -peak])

    #expect(shared > 0.3)
    #expect(fromSamples > 0)
  }

  @Test func nearSilenceProducesNoMovement() {
    #expect(MeetingAudioMeter.level(rms: 0.0005, peak: 0.001) == 0)
  }
}
