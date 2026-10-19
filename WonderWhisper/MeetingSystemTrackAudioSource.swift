import Foundation
import AVFoundation
import FluidAudio

/// A meeting's retained system-audio segments as one continuous 16 kHz track, read from disk
/// as the diarizer asks for it, so an hour of audio never sits in memory. Sample 0 is
/// `startTime` on the meeting timeline; gaps between segments read as silence.
struct MeetingSystemTrackAudioSource: AudioSampleSource {
  static let sampleRate = 16_000

  struct Segment: Equatable, Sendable {
    let url: URL
    let startSample: Int
    let sampleCount: Int

    var endSample: Int { startSample + sampleCount }
  }

  let segments: [Segment]
  let startTime: TimeInterval
  let sampleCount: Int

  init(segments: [Segment], startTime: TimeInterval) {
    self.segments = segments.sorted { $0.startSample < $1.startSample }
    self.startTime = startTime
    sampleCount = self.segments.map(\.endSample).max() ?? 0
  }

  /// Nil when the meeting kept no readable system audio.
  init?(sessionDirectory: URL, audioFilenames: [String]) {
    var parsed: [(url: URL, startTime: TimeInterval, sampleCount: Int)] = []
    var seen: Set<String> = []
    for filename in audioFilenames {
      guard let segment = MeetingTranscriptRecoveryService.segment(filename: filename, duration: 1),
            segment.source == .systemAudio,
            seen.insert(segment.filename).inserted else { continue }
      let url = sessionDirectory.appendingPathComponent(segment.filename)
      guard let file = try? AVAudioFile(forReading: url),
            file.processingFormat.sampleRate == Double(Self.sampleRate),
            file.length > 0 else { continue }
      parsed.append((url, segment.startTime, Int(file.length)))
    }
    guard let firstStart = parsed.map(\.startTime).min() else { return nil }
    self.init(
      segments: parsed.map {
        Segment(
          url: $0.url,
          startSample: Int((($0.startTime - firstStart) * Double(Self.sampleRate)).rounded()),
          sampleCount: $0.sampleCount
        )
      },
      startTime: firstStart
    )
  }

  func copySamples(
    into destination: UnsafeMutablePointer<Float>,
    offset: Int,
    count: Int
  ) throws {
    guard count > 0 else { return }
    destination.update(repeating: 0, count: count)
    let range = offset..<(offset + count)
    for segment in segments where segment.endSample > range.lowerBound {
      guard segment.startSample < range.upperBound else { break }
      let overlapStart = max(segment.startSample, range.lowerBound)
      let overlapEnd = min(segment.endSample, range.upperBound)
      guard overlapEnd > overlapStart else { continue }
      try read(
        segment,
        from: overlapStart - segment.startSample,
        count: overlapEnd - overlapStart,
        into: destination.advanced(by: overlapStart - range.lowerBound)
      )
    }
  }

  private func read(
    _ segment: Segment,
    from frame: Int,
    count: Int,
    into destination: UnsafeMutablePointer<Float>
  ) throws {
    let file = try AVAudioFile(
      forReading: segment.url,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: AVAudioFrameCount(count)
    ) else { return }
    file.framePosition = AVAudioFramePosition(frame)
    try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
    guard let channel = buffer.floatChannelData?.pointee else { return }
    destination.update(from: channel, count: min(count, Int(buffer.frameLength)))
  }
}
