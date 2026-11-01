import Foundation
import Testing
@testable import WonderWhisper

struct DictationSilenceGateTests {
  private let rate = DictationAudioFixtures.sampleRate

  @Test func emptyAndDigitalSilenceAreSilent() {
    #expect(DictationSilenceGate.analyze(samples: [], sampleRate: rate).isSilent)
    let zeros = DictationSilenceGate.analyze(samples: DictationAudioFixtures.silence(seconds: 2), sampleRate: rate)
    #expect(zeros.isSilent)
    #expect(zeros.loudestWindowDBFS == DictationSilenceGate.floorDBFS)
  }

  @Test func aConstantOffsetIsRemovedBeforeMeasuring() {
    let dc = [Float](repeating: 0.4, count: 32_000)
    #expect(DictationSilenceGate.analyze(samples: dc, sampleRate: rate).isSilent)
    // A quiet tone riding on a large offset is measured at the tone's level.
    let tone = DictationAudioFixtures.sine(seconds: 1, rmsDBFS: -40, offset: 0.3)
    let analysis = DictationSilenceGate.analyze(samples: tone, sampleRate: rate)
    #expect(!analysis.isSilent)
    #expect(abs(analysis.loudestWindowDBFS - -40) < 0.5)
  }

  @Test func thresholdIsMinusFiftyDBFS() {
    let above = DictationSilenceGate.analyze(
      samples: DictationAudioFixtures.sine(seconds: 1, rmsDBFS: -49),
      sampleRate: rate
    )
    let below = DictationSilenceGate.analyze(
      samples: DictationAudioFixtures.sine(seconds: 1, rmsDBFS: -51),
      sampleRate: rate
    )
    #expect(!above.isSilent)
    #expect(below.isSilent)
  }

  @Test func quietRoomNoiseIsSilentButQuietSpeechLevelIsNot() {
    var generator = SeededNoise(seed: 7)
    // About -62 dBFS RMS of noise: a quiet room on a close microphone.
    let noise = (0..<48_000).map { _ in generator.next() * 0.0014 }
    #expect(DictationSilenceGate.analyze(samples: noise, sampleRate: rate).isSilent)
    // Whispered speech peaks well above -50 dBFS even when its average is low: one 300 ms
    // syllable at -42 dBFS in two seconds of that noise is enough.
    var clip = noise + noise.prefix(16_000)
    let syllable = DictationAudioFixtures.sine(seconds: 0.3, rmsDBFS: -42, frequency: 220)
    for (index, sample) in syllable.enumerated() { clip[20_000 + index] += sample }
    #expect(!DictationSilenceGate.analyze(samples: clip, sampleRate: rate).isSilent)
  }

  @Test func windowsAreThirtyMillisecondsWithFifteenMillisecondHops() {
    // 1 s at 16 kHz: windows of 480 samples every 240 samples; the last starts at 15_600.
    let analysis = DictationSilenceGate.analyze(samples: DictationAudioFixtures.silence(seconds: 1), sampleRate: rate)
    #expect(analysis.windowCount == 66)
  }

  @Test func aShortBurstBetweenWindowStartsIsCaughtByTheOverlap() {
    // 20 ms burst starting mid-window: half of it sits in each of two windows without overlap,
    // and the overlapping window still contains most of it.
    var clip = DictationAudioFixtures.silence(seconds: 1)
    let burst = DictationAudioFixtures.sine(seconds: 0.02, rmsDBFS: -40)
    for (index, sample) in burst.enumerated() { clip[8_100 + index] = sample }
    let analysis = DictationSilenceGate.analyze(samples: clip, sampleRate: rate)
    #expect(!analysis.isSilent)
    #expect(analysis.loudestWindowDBFS > -44)
  }

  @Test func trailingPartialWindowIsCoveredByThePreviousWindow() {
    // 490 samples: one full window (0..<480), then a 10-sample tail that is shorter than a hop
    // and is measured inside the window starting at 240 (240..<490).
    var clip = [Float](repeating: 0, count: 490)
    let tail = DictationAudioFixtures.sine(seconds: 0.000_625, rmsDBFS: -10)
    for (index, sample) in tail.enumerated() { clip[480 + index] = sample }
    let analysis = DictationSilenceGate.analyze(samples: clip, sampleRate: rate)
    #expect(analysis.windowCount == 2)
    #expect(!analysis.isSilent)
  }

  @Test func clipShorterThanAHopIsMeasuredAsOneWindow() {
    let clip = DictationAudioFixtures.sine(seconds: 0.005, rmsDBFS: -30)
    let analysis = DictationSilenceGate.analyze(samples: clip, sampleRate: rate)
    #expect(analysis.windowCount == 1)
    #expect(!analysis.isSilent)
  }

  @Test func analysesTheSavedRecording() throws {
    let silent = try DictationAudioFixtures.writeWAV(
      DictationAudioFixtures.silence(seconds: 1),
      to: DictationAudioFixtures.temporaryURL()
    )
    let speech = try DictationAudioFixtures.writeWAV(
      DictationAudioFixtures.sine(seconds: 1, rmsDBFS: -30),
      to: DictationAudioFixtures.temporaryURL()
    )
    defer {
      try? FileManager.default.removeItem(at: silent)
      try? FileManager.default.removeItem(at: speech)
    }
    #expect(DictationSilenceGate.analyze(fileURL: silent)?.isSilent == true)
    #expect(DictationSilenceGate.analyze(fileURL: speech)?.isSilent == false)
    #expect(DictationSilenceGate.analyze(fileURL: URL(fileURLWithPath: "/nonexistent.wav")) == nil)
  }
}

/// Deterministic uniform noise in -1...1.
struct SeededNoise {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> Float {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
  }
}
