import Foundation
import AVFoundation

/// Decides whether a finished dictation recording holds anything worth transcribing.
///
/// The clip is cut into 30 ms windows that start every 15 ms (50% overlap). Each window's mean
/// is subtracted (DC removal) before its RMS is taken, and the level is `20·log10(rms)` against a
/// full scale of 1.0. A trailing window shorter than 15 ms is skipped, because the previous window
/// already covers its samples; a clip shorter than 15 ms is measured as one window. The clip is
/// silent when its loudest window is below -50 dBFS (or it has no samples at all).
enum DictationSilenceGate {
  static let windowSeconds = 0.030
  static let hopSeconds = 0.015
  static let silenceThresholdDBFS: Double = -50
  /// Level reported for a window with no energy at all.
  static let floorDBFS: Double = -160

  struct Analysis: Equatable {
    var loudestWindowDBFS: Double
    var windowCount: Int

    var isSilent: Bool { windowCount == 0 || loudestWindowDBFS < DictationSilenceGate.silenceThresholdDBFS }
  }

  static func analyze(samples: [Float], sampleRate: Double) -> Analysis {
    samples.withUnsafeBufferPointer { analyze(samples: $0, sampleRate: sampleRate) }
  }

  static func analyze(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Analysis {
    let count = samples.count
    guard count > 0, sampleRate > 0 else {
      return Analysis(loudestWindowDBFS: floorDBFS, windowCount: 0)
    }
    let window = max(1, Int((windowSeconds * sampleRate).rounded()))
    let hop = max(1, Int((hopSeconds * sampleRate).rounded()))
    let minimumPartial = hop
    var loudest = floorDBFS
    var windows = 0
    var start = 0
    while start < count {
      let end = min(start + window, count)
      let length = end - start
      // Short tails are already inside the previous overlapping window.
      if length < minimumPartial && start > 0 { break }
      loudest = max(loudest, dcRemovedLevel(samples, start: start, end: end))
      windows += 1
      if end == count { break }
      start += hop
    }
    return Analysis(loudestWindowDBFS: loudest, windowCount: windows)
  }

  /// Reads `url` and analyses it. Nil when the file cannot be read, in which case callers must
  /// treat the clip as not silent (never drop audio on a read error).
  static func analyze(fileURL url: URL) -> Analysis? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0 else { return Analysis(loudestWindowDBFS: floorDBFS, windowCount: 0) }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          (try? file.read(into: buffer)) != nil,
          let channels = buffer.floatChannelData else { return nil }
    // Dictation records mono; for more channels the loudest channel decides.
    var result = Analysis(loudestWindowDBFS: floorDBFS, windowCount: 0)
    for channel in 0..<Int(format.channelCount) {
      let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
      let analysis = analyze(samples: samples, sampleRate: format.sampleRate)
      if analysis.windowCount > result.windowCount || analysis.loudestWindowDBFS > result.loudestWindowDBFS {
        result = Analysis(
          loudestWindowDBFS: max(result.loudestWindowDBFS, analysis.loudestWindowDBFS),
          windowCount: max(result.windowCount, analysis.windowCount)
        )
      }
    }
    return result
  }

  private static func dcRemovedLevel(_ samples: UnsafeBufferPointer<Float>, start: Int, end: Int) -> Double {
    let length = Double(end - start)
    var sum = 0.0
    for index in start..<end { sum += Double(samples[index]) }
    let mean = sum / length
    var squares = 0.0
    for index in start..<end {
      let centred = Double(samples[index]) - mean
      squares += centred * centred
    }
    let rms = (squares / length).squareRoot()
    guard rms > 0, rms.isFinite else { return floorDBFS }
    return max(floorDBFS, 20 * log10(rms))
  }
}
