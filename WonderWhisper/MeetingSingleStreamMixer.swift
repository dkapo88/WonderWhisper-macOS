import Accelerate
import Foundation

final class MeetingSingleStreamMixer {
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
  private var echoCanceller = MeetingAdaptiveEchoCanceller()
  private var discardedLateAudioSampleCount = 0
  private(set) var hasDiscardedLateAudio = false

  func ingest(_ chunk: MeetingAudioChunk) -> [MeetingAudioChunk] {
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

  func finish() -> [MeetingAudioChunk] {
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
  ) -> [MeetingAudioChunk] {
    guard endSample > nextOutputSample else { return [] }
    var result: [MeetingAudioChunk] = []
    while nextOutputSample < endSample {
      let remaining = endSample - nextOutputSample
      guard remaining >= Self.frameSampleCount || includePartialFrame else { break }
      let sampleCount = min(Self.frameSampleCount, remaining)
      let range = nextOutputSample..<(nextOutputSample + sampleCount)
      let system = render(source: .systemAudio, range: range)
      let microphone = render(source: .microphone, range: range)
      let cleanedMicrophone = echoCanceller.process(
        reference: system,
        microphone: microphone
      )
      let mixed = Self.mix(system: system, microphone: cleanedMicrophone)
      result.append(
        MeetingAudioChunk(
          source: .mixed,
          samples: mixed,
          startTime: Double(nextOutputSample) / Double(Self.sampleRate),
          duration: Double(sampleCount) / Double(Self.sampleRate)
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

  private static func mix(system: [Float], microphone: [Float]) -> [Float] {
    let count = min(system.count, microphone.count)
    guard count > 0 else { return [] }
    var result = Array(repeating: Float.zero, count: count)
    var systemGain: Float = 0.9
    system.withUnsafeBufferPointer { systemBuffer in
      microphone.withUnsafeBufferPointer { microphoneBuffer in
        result.withUnsafeMutableBufferPointer { outputBuffer in
          guard let systemBase = systemBuffer.baseAddress,
                let microphoneBase = microphoneBuffer.baseAddress,
                let outputBase = outputBuffer.baseAddress else { return }
          vDSP_vsmul(
            systemBase,
            1,
            &systemGain,
            outputBase,
            1,
            vDSP_Length(count)
          )
          vDSP_vadd(
            outputBase,
            1,
            microphoneBase,
            1,
            outputBase,
            1,
            vDSP_Length(count)
          )
          var minimum: Float = -1
          var maximum: Float = 1
          vDSP_vclip(
            outputBase,
            1,
            &minimum,
            &maximum,
            outputBase,
            1,
            vDSP_Length(count)
          )
        }
      }
    }
    return result
  }
}

final class MeetingAdaptiveEchoCanceller {
  private var coefficients: [Float]
  private var referenceHistory: [Float]
  private var historyHead = 0
  private var referenceEnergy: Double = 0
  private let adaptationRate: Float

  init(filterLength: Int = 512, adaptationRate: Float = 0.08) {
    let length = max(8, filterLength)
    self.coefficients = Array(repeating: 0, count: length)
    self.referenceHistory = Array(repeating: 0, count: length * 2)
    self.adaptationRate = adaptationRate
  }

  func process(
    reference: [Float],
    microphone: [Float]
  ) -> [Float] {
    let count = min(reference.count, microphone.count)
    guard count > 0 else { return [] }
    var residual = Array(repeating: Float.zero, count: count)
    var head = historyHead
    var energy = referenceEnergy
    let filterLength = coefficients.count
    let epsilon = 0.0001

    reference.withUnsafeBufferPointer { referenceBuffer in
      microphone.withUnsafeBufferPointer { microphoneBuffer in
        coefficients.withUnsafeMutableBufferPointer { coefficientBuffer in
          referenceHistory.withUnsafeMutableBufferPointer { historyBuffer in
            residual.withUnsafeMutableBufferPointer { outputBuffer in
              guard let referenceBase = referenceBuffer.baseAddress,
                    let microphoneBase = microphoneBuffer.baseAddress,
                    let coefficientBase = coefficientBuffer.baseAddress,
                    let historyBase = historyBuffer.baseAddress,
                    let outputBase = outputBuffer.baseAddress else { return }

              var coefficientMinimum: Float = -2
              var coefficientMaximum: Float = 2
              for index in 0..<count {
                let rawReference = referenceBase[index]
                let rawMicrophone = microphoneBase[index]
                let referenceSample = rawReference.isFinite
                  ? max(-1, min(1, rawReference))
                  : 0
                let microphoneSample = rawMicrophone.isFinite
                  ? max(-1, min(1, rawMicrophone))
                  : 0

                head = head == 0 ? filterLength - 1 : head - 1
                let oldestReference = historyBase[head]
                historyBase[head] = referenceSample
                historyBase[head + filterLength] = referenceSample
                energy += Double(referenceSample * referenceSample)
                  - Double(oldestReference * oldestReference)
                energy = max(0, energy)

                var estimatedEcho: Float = 0
                vDSP_dotpr(
                  coefficientBase,
                  1,
                  historyBase + head,
                  1,
                  &estimatedEcho,
                  vDSP_Length(filterLength)
                )
                if !estimatedEcho.isFinite {
                  vDSP_vclr(coefficientBase, 1, vDSP_Length(filterLength))
                  estimatedEcho = 0
                }

                let error = microphoneSample - estimatedEcho
                outputBase[index] = max(-1, min(1, error.isFinite ? error : 0))
                guard energy > epsilon else { continue }
                var normalizedStep = Float(
                  Double(adaptationRate) * Double(error) / (energy + epsilon)
                )
                guard normalizedStep.isFinite else {
                  vDSP_vclr(coefficientBase, 1, vDSP_Length(filterLength))
                  continue
                }
                vDSP_vsma(
                  historyBase + head,
                  1,
                  &normalizedStep,
                  coefficientBase,
                  1,
                  coefficientBase,
                  1,
                  vDSP_Length(filterLength)
                )
                vDSP_vclip(
                  coefficientBase,
                  1,
                  &coefficientMinimum,
                  &coefficientMaximum,
                  coefficientBase,
                  1,
                  vDSP_Length(filterLength)
                )
              }
            }
          }
        }
      }
    }

    historyHead = head
    referenceEnergy = energy.isFinite ? energy : 0
    return residual
  }
}
