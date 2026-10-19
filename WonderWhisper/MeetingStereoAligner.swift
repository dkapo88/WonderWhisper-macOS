import Foundation

/// One aligned 100 ms slice of both capture sources, silence where a source had no audio.
struct MeetingStereoFrame: Equatable, Sendable {
  let startTime: TimeInterval
  let microphone: [Float]
  let system: [Float]

  var duration: TimeInterval {
    Double(microphone.count) / Double(MeetingStereoAligner.sampleRate)
  }

  /// Interleaved little-endian PCM16, channel 0 the microphone and channel 1 the system audio.
  var interleavedPCM16: Data {
    let count = min(microphone.count, system.count)
    var values = [Int16](repeating: 0, count: count * 2)
    for index in 0..<count {
      values[index * 2] = Self.pcm16(microphone[index])
      values[index * 2 + 1] = Self.pcm16(system[index])
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func pcm16(_ sample: Float) -> Int16 {
    let finite = sample.isFinite ? sample : 0
    let clamped = max(-1, min(1, finite))
    let scale: Float = clamped < 0 ? 32_768 : 32_767
    return Int16((clamped * scale).rounded()).littleEndian
  }
}

/// Lines the microphone and system audio up on one timeline for a two-channel stream. The
/// sources arrive from separate capture paths, so frames are released only once both have
/// reached them, or once one source is 30 s behind (that audio is then late and needs
/// recovery from the retained CAF segments).
final class MeetingStereoAligner {
  static let sampleRate = 16_000
  static let frameSampleCount = 1_600
  static let maximumAlignmentWaitSamples = sampleRate * 30
  static let lateAudioToleranceSamples = frameSampleCount

  private struct Span {
    let startSample: Int
    let samples: [Float]

    var endSample: Int { startSample + samples.count }
  }

  private var spans: [MeetingAudioSource: [Span]] = [:]
  private var latestEndSamples: [MeetingAudioSource: Int] = [:]
  private var nextOutputSample = 0
  private var discardedLateAudioSampleCount = 0
  private(set) var hasDiscardedLateAudio = false

  func ingest(_ chunk: MeetingAudioChunk) -> [MeetingStereoFrame] {
    guard MeetingAudioSource.captureSources.contains(chunk.source),
          !chunk.samples.isEmpty else { return [] }
    let startSample = max(0, Int((chunk.startTime * Double(Self.sampleRate)).rounded()))
    let span = Span(startSample: startSample, samples: chunk.samples)
    let discardedSampleCount = max(0, min(span.endSample, nextOutputSample) - span.startSample)
    discardedLateAudioSampleCount += discardedSampleCount
    if discardedLateAudioSampleCount > Self.lateAudioToleranceSamples {
      hasDiscardedLateAudio = true
    }
    if let last = spans[chunk.source]?.last,
       last.startSample > span.startSample {
      let insertionIndex = spans[chunk.source]?.firstIndex {
        $0.startSample > span.startSample
      } ?? spans[chunk.source]?.endIndex ?? 0
      spans[chunk.source, default: []].insert(span, at: insertionIndex)
    } else {
      spans[chunk.source, default: []].append(span)
    }
    latestEndSamples[chunk.source] = max(
      latestEndSamples[chunk.source] ?? 0,
      span.endSample
    )
    return drain(until: safeOutputEndSample, includePartialFrame: false)
  }

  func finish() -> [MeetingStereoFrame] {
    let finalEnd = latestEndSamples.values.max() ?? nextOutputSample
    return drain(until: finalEnd, includePartialFrame: true)
  }

  private var safeOutputEndSample: Int {
    let newestEnd = latestEndSamples.values.max() ?? nextOutputSample
    let alignedEnd: Int = if let systemEnd = latestEndSamples[.systemAudio],
                             let microphoneEnd = latestEndSamples[.microphone] {
      min(systemEnd, microphoneEnd)
    } else {
      nextOutputSample
    }
    let boundedEnd = newestEnd - Self.maximumAlignmentWaitSamples
    if boundedEnd > alignedEnd {
      hasDiscardedLateAudio = true
    }
    return max(alignedEnd, boundedEnd, nextOutputSample)
  }

  private func drain(
    until endSample: Int,
    includePartialFrame: Bool
  ) -> [MeetingStereoFrame] {
    guard endSample > nextOutputSample else { return [] }
    var result: [MeetingStereoFrame] = []
    while nextOutputSample < endSample {
      let remaining = endSample - nextOutputSample
      guard remaining >= Self.frameSampleCount || includePartialFrame else { break }
      let sampleCount = min(Self.frameSampleCount, remaining)
      let range = nextOutputSample..<(nextOutputSample + sampleCount)
      result.append(
        MeetingStereoFrame(
          startTime: Double(nextOutputSample) / Double(Self.sampleRate),
          microphone: render(source: .microphone, range: range),
          system: render(source: .systemAudio, range: range)
        )
      )
      nextOutputSample += sampleCount
      discardConsumedSpans(through: nextOutputSample)
    }
    return result
  }

  private func render(
    source: MeetingAudioSource,
    range: Range<Int>
  ) -> [Float] {
    var result = Array(repeating: Float.zero, count: range.count)
    for span in spans[source] ?? [] where span.endSample > range.lowerBound {
      guard span.startSample < range.upperBound else { break }
      let overlapStart = max(span.startSample, range.lowerBound)
      let overlapEnd = min(span.endSample, range.upperBound)
      guard overlapEnd > overlapStart else { continue }
      let sourceOffset = overlapStart - span.startSample
      let destinationOffset = overlapStart - range.lowerBound
      let count = overlapEnd - overlapStart
      result.replaceSubrange(
        destinationOffset..<(destinationOffset + count),
        with: span.samples[sourceOffset..<(sourceOffset + count)]
      )
    }
    return result
  }

  private func discardConsumedSpans(through sample: Int) {
    for source in MeetingAudioSource.captureSources {
      spans[source]?.removeAll { $0.endSample <= sample }
    }
  }
}
