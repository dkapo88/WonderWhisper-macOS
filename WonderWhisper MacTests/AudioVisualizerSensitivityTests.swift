import CoreGraphics
import Testing
@testable import WonderWhisper_Mac

struct AudioVisualizerSensitivityTests {
  @Test func ambientLevelsAreGatedBeforeVisualBoosting() {
    #expect(AudioVisualizerSensitivity.gatedLevel(0.01) == 0)
  }

  @Test func lowSpeechLevelsAreNotOverBoosted() {
    let boosted = AudioVisualizerSensitivity.boostedLevel(0.04)

    #expect(boosted < 0.14)
  }
}
