import AVFoundation
import Foundation
import Testing
@testable import WonderWhisper

struct ParakeetInputPaddingTests {
  @Test func shortClipsArePaddedToOneAndAHalfSecondsPlusTrailingSilence() {
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 0) == 30_400)
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 1_600) == 30_400)
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 24_000) == 30_400)
  }

  @Test func longerClipsGetFourHundredMillisecondsOfTrailingSilence() {
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 24_001) == 30_401)
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 48_000) == 54_400)
    // Just under the 15 s window: padding pushes the input across the window boundary.
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 238_400) == 244_800)
    #expect(ParakeetInputPadding.paddedSampleCount(forModelSamples: 960_000) == 966_400)
  }

  @Test func paddingAtOtherSampleRatesMatchesSixteenKilohertz() {
    #expect(ParakeetInputPadding.paddedFrameCount(forFrames: 48_000, sampleRate: 48_000) == 91_200)
    #expect(ParakeetInputPadding.paddedFrameCount(forFrames: 4_800, sampleRate: 48_000) == 91_200)
    #expect(ParakeetInputPadding.paddedFrameCount(forFrames: 16_000, sampleRate: 16_000) == 30_400)
  }

  @Test func paddedBufferKeepsTheAudioAndAppendsZeros() throws {
    let samples = DictationAudioFixtures.sine(seconds: 0.25, rmsDBFS: -20)
    let url = try DictationAudioFixtures.writeWAV(samples, to: DictationAudioFixtures.temporaryURL())
    defer { try? FileManager.default.removeItem(at: url) }
    let originalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int

    let buffer = try #require(try ParakeetInputPadding.paddedBuffer(contentsOf: url))
    #expect(Int(buffer.frameLength) == 30_400)
    let channel = try #require(buffer.floatChannelData?[0])
    // Original audio intact (16-bit quantisation only).
    for index in stride(from: 0, to: samples.count, by: 97) {
      #expect(abs(channel[index] - samples[index]) < 0.001)
    }
    for index in samples.count..<30_400 { #expect(channel[index] == 0) }
    // The recording itself is untouched.
    let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(originalSize == sizeAfter)
  }

  @Test func paddedBufferAcrossTheFifteenSecondWindow() throws {
    let samples = DictationAudioFixtures.sine(seconds: 14.9, rmsDBFS: -20)
    let url = try DictationAudioFixtures.writeWAV(samples, to: DictationAudioFixtures.temporaryURL())
    defer { try? FileManager.default.removeItem(at: url) }
    let buffer = try #require(try ParakeetInputPadding.paddedBuffer(contentsOf: url))
    #expect(Int(buffer.frameLength) == 238_400 + 6_400)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect(channel[238_399] != 0 || channel[238_398] != 0)
    #expect(channel[238_400] == 0 && channel[244_799] == 0)
  }

  @Test func emptyRecordingHasNoBuffer() throws {
    let url = try DictationAudioFixtures.writeWAV([], to: DictationAudioFixtures.temporaryURL())
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try ParakeetInputPadding.paddedBuffer(contentsOf: url) == nil)
  }
}
