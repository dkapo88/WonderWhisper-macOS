import Foundation

/// Replaces the meeting microphone's audio with silence while the user is not speaking, so
/// the transcriber cannot invent words from near-silence ("yeah, yeah") or pick up quiet
/// voices elsewhere in the room. The saved audio is never gated; only what is transcribed.
///
/// Works on 10 ms frames of 16 kHz audio. A frame counts as speech when its level (after a
/// 120 Hz high-pass, so desk rumble does not count) is above all of:
/// - the noise floor (the quietest 100 ms block of the last 5 s, at most -50 dBFS) plus a
///   margin,
/// - once learned, the user's own speaking level minus a range (distant voices are much
///   quieter on a headset or laptop microphone than the user is),
/// - an absolute minimum.
/// Speech opens after 3 of 4 frames pass, stays open within 6 dB of the threshold, and is
/// held a little after it ends. Output runs 200 ms behind input so the start of a word is
/// kept too. Times on the chunks are unchanged.
struct MeetingMicrophoneGate {
  struct Tuning: Equatable, Sendable {
    let noiseMargin: Float
    let speakingRange: Float
    let absoluteMinimum: Float
    let hangoverFrames: Int
    let lookaheadFrames: Int

    static let normal = Self(
      noiseMargin: 10,
      speakingRange: 20,
      absoluteMinimum: -60,
      hangoverFrames: 50,
      lookaheadFrames: 20
    )

    static let strict = Self(
      noiseMargin: 15,
      speakingRange: 14,
      absoluteMinimum: -50,
      hangoverFrames: 35,
      lookaheadFrames: 20
    )
  }

  static let sampleRate = MeetingAudioChunkFramer.sampleRate
  static let frameSampleCount = 160
  static let initialSpeakingLevel: Float = -30
  static let speakingLevelBounds: ClosedRange<Float> = -50 ... -6
  static let initialNoiseFloor: Float = -65
  /// The noise floor never counts as louder than this, so speech without pauses cannot be
  /// taken for room noise.
  static let noiseFloorCeiling: Float = -50
  static let noiseBlockFrames = 10
  static let noiseWindowBlocks = 50
  static let stayOpenHysteresis: Float = 6
  static let fadeSampleCount = 80
  /// Speech frames needed before the user's own level is trusted.
  static let learningFrames = 30

  private struct Frame {
    let startTime: TimeInterval
    var samples: [Float]
    let muted: Bool
    var keep = false
  }

  let mode: MeetingMicrophoneGateMode
  private let tuning: Tuning?
  private let mutedRanges: [MeetingTimeRange]

  private var pending: [Frame] = []
  private var partial: [Float] = []
  private var partialStartTime: TimeInterval = 0
  private var partialMuted = false
  private var lastKept = false

  private var highPassPreviousInput: Float = 0
  private var highPassPreviousOutput: Float = 0
  private let highPassCoefficient: Float

  private var noiseBlockPower: Float = 0
  private var noiseBlockCount = 0
  private var noiseBlockLevels: [Float] = []
  private(set) var speakingLevel: Float = initialSpeakingLevel
  private var learnedFrames = 0
  private var nextFrameTime: TimeInterval?
  private var lastEmittedEnd: TimeInterval?
  private var recentAbove: [Bool] = []
  private var isSpeaking = false
  private var hangoverRemaining = 0

  /// `mutedRanges` are on the same timeline as the chunks; audio inside them is always silenced.
  init(mode: MeetingMicrophoneGateMode, mutedRanges: [MeetingTimeRange] = []) {
    self.mode = mode
    self.mutedRanges = mutedRanges
    switch mode {
    case .off: tuning = nil
    case .normal: tuning = .normal
    case .strict: tuning = .strict
    }
    let cutoff: Float = 120
    let rc = 1 / (2 * Float.pi * cutoff)
    let dt = 1 / Float(Self.sampleRate)
    highPassCoefficient = rc / (rc + dt)
  }

  init(settings: MeetingMicrophoneGateSettings) {
    self.init(mode: settings.mode, mutedRanges: settings.mutedRanges)
  }

  /// The user's own level is only used once learned: until then a quiet microphone must still
  /// be able to open the gate.
  var hasLearnedSpeakingLevel: Bool {
    learnedFrames >= Self.learningFrames
  }

  /// The quietest 100 ms of the last 5 s; before the first 100 ms is complete, the level so
  /// far, so the gate cannot open on room noise at the start of a stream.
  var measuredNoiseFloor: Float {
    if let quietest = noiseBlockLevels.min() { return quietest }
    if noiseBlockCount > 0 { return Self.decibels(noiseBlockPower / Float(noiseBlockCount)) }
    return Self.initialNoiseFloor
  }

  /// Only ever measured room noise (capped), never derived from the user's level, so a low
  /// learned level cannot let steady noise through.
  var noiseFloor: Float {
    min(measuredNoiseFloor, Self.noiseFloorCeiling)
  }

  /// Gates one chunk. `muted` silences it whatever the gate decides (the user pressed Mute);
  /// muted ranges are checked for every 10 ms frame. Returns the audio that is ready, which
  /// runs up to 200 ms behind the input.
  mutating func process(_ chunk: MeetingAudioChunk, muted: Bool = false) -> [MeetingAudioChunk] {
    guard chunk.source == .microphone, !chunk.samples.isEmpty else { return [chunk] }
    guard tuning != nil else {
      let samples = silencingMuted(chunk.samples, startTime: chunk.startTime, muted: muted)
      return [chunk.replacingSamples(samples)]
    }

    let expectedStart = partialStartTime + Double(partial.count) / Double(Self.sampleRate)
    if !partial.isEmpty,
       abs(chunk.startTime - expectedStart) > 0.001 || muted != partialMuted {
      closePartialFrame()
    }
    if partial.isEmpty {
      partialStartTime = chunk.startTime
      partialMuted = muted
    }
    partial.append(contentsOf: chunk.samples)
    while partial.count >= Self.frameSampleCount {
      let samples = Array(partial.prefix(Self.frameSampleCount))
      partial.removeFirst(Self.frameSampleCount)
      let startTime = partialStartTime
      partialStartTime += Double(Self.frameSampleCount) / Double(Self.sampleRate)
      append(Frame(
        startTime: startTime,
        samples: samples,
        muted: partialMuted || isInMutedRange(startTime: startTime, count: samples.count)
      ))
    }
    return emit(keepingLast: tuning?.lookaheadFrames ?? 0)
  }

  private func isInMutedRange(startTime: TimeInterval, count: Int) -> Bool {
    guard !mutedRanges.isEmpty else { return false }
    return mutedRanges.covers(
      start: startTime,
      end: startTime + Double(count) / Double(Self.sampleRate)
    )
  }

  /// With the gate off: silence the muted chunk, or the muted 10 ms frames within it.
  private func silencingMuted(_ samples: [Float], startTime: TimeInterval, muted: Bool) -> [Float] {
    if muted { return Array(repeating: 0, count: samples.count) }
    guard !mutedRanges.isEmpty else { return samples }
    var result = samples
    for offset in stride(from: 0, to: samples.count, by: Self.frameSampleCount) {
      let count = min(Self.frameSampleCount, samples.count - offset)
      let frameStart = startTime + Double(offset) / Double(Self.sampleRate)
      if isInMutedRange(startTime: frameStart, count: count) {
        result.replaceSubrange(offset..<(offset + count), with: repeatElement(0, count: count))
      }
    }
    return result
  }

  /// Everything still held back, for the end of the meeting.
  mutating func flush() -> [MeetingAudioChunk] {
    guard tuning != nil else { return [] }
    closePartialFrame()
    return emit(keepingLast: 0)
  }

  private mutating func closePartialFrame() {
    guard !partial.isEmpty else { return }
    let frame = Frame(
      startTime: partialStartTime,
      samples: partial,
      muted: partialMuted || isInMutedRange(startTime: partialStartTime, count: partial.count)
    )
    partial.removeAll(keepingCapacity: true)
    append(frame)
  }

  private mutating func append(_ frame: Frame) {
    var frame = frame
    if let nextFrameTime, abs(frame.startTime - nextFrameTime) > 0.001 {
      // A gap in the timeline (a resumed meeting): speech does not continue across it.
      isSpeaking = false
      hangoverRemaining = 0
      recentAbove.removeAll()
      highPassPreviousInput = 0
      highPassPreviousOutput = 0
    }
    nextFrameTime = frame.startTime + Double(frame.samples.count) / Double(Self.sampleRate)
    let speaking = classify(frame.samples, muted: frame.muted)
    if speaking {
      hangoverRemaining = tuning?.hangoverFrames ?? 0
      frame.keep = true
      // Look-ahead: the frames just before speech carry the start of the word.
      let lookahead = tuning?.lookaheadFrames ?? 0
      for index in pending.indices.suffix(lookahead) {
        pending[index].keep = true
      }
    } else if hangoverRemaining > 0 {
      hangoverRemaining -= 1
      frame.keep = true
    }
    pending.append(frame)
  }

  private mutating func classify(_ samples: [Float], muted: Bool) -> Bool {
    guard let tuning else { return true }
    var power: Float = 0
    for sample in samples {
      let value = sample.isFinite ? sample : 0
      let filtered = highPassCoefficient * (highPassPreviousOutput + value - highPassPreviousInput)
      highPassPreviousInput = value
      highPassPreviousOutput = filtered
      power += filtered * filtered
    }
    power /= Float(max(1, samples.count))
    let level = Self.decibels(power)

    noiseBlockPower += power
    noiseBlockCount += 1
    if noiseBlockCount >= Self.noiseBlockFrames {
      noiseBlockLevels.append(Self.decibels(noiseBlockPower / Float(noiseBlockCount)))
      if noiseBlockLevels.count > Self.noiseWindowBlocks {
        noiseBlockLevels.removeFirst(noiseBlockLevels.count - Self.noiseWindowBlocks)
      }
      noiseBlockPower = 0
      noiseBlockCount = 0
    }

    var threshold = max(noiseFloor + tuning.noiseMargin, tuning.absoluteMinimum)
    if hasLearnedSpeakingLevel {
      threshold = max(threshold, speakingLevel - tuning.speakingRange)
    }
    let above = level >= threshold
    recentAbove.append(above)
    if recentAbove.count > 4 { recentAbove.removeFirst() }

    guard !muted else {
      isSpeaking = false
      hangoverRemaining = 0
      return false
    }
    if isSpeaking {
      isSpeaking = level >= threshold - Self.stayOpenHysteresis
    } else {
      isSpeaking = recentAbove.filter { $0 }.count >= 3
    }
    // Learn only from speech clearly above the measured noise, so room noise can never pass
    // for (or drag down) the user's voice.
    if isSpeaking, above, level >= measuredNoiseFloor + tuning.noiseMargin {
      learnSpeakingLevel(from: level)
    }
    return isSpeaking
  }

  /// Follows the user's own level from their first clear speech: quickly upward, slowly
  /// downward, and only from speech near that level, so quiet voices in the room cannot drag
  /// it down.
  private mutating func learnSpeakingLevel(from level: Float) {
    if learnedFrames < Self.learningFrames {
      learnedFrames += 1
    }
    if learnedFrames == 1 {
      speakingLevel = level
    } else if level > speakingLevel {
      speakingLevel += 0.05 * (level - speakingLevel)
    } else if level > speakingLevel - 10 {
      speakingLevel += 0.01 * (level - speakingLevel)
    }
    speakingLevel = min(
      max(speakingLevel, Self.speakingLevelBounds.lowerBound),
      Self.speakingLevelBounds.upperBound
    )
  }

  private mutating func emit(keepingLast heldFrames: Int) -> [MeetingAudioChunk] {
    let readyCount = max(0, pending.count - heldFrames)
    guard readyCount > 0 else { return [] }
    var chunks: [MeetingAudioChunk] = []
    var runStart: TimeInterval = 0
    var runSamples: [Float] = []
    for index in 0..<readyCount {
      var frame = pending[index]
      if let lastEmittedEnd, abs(frame.startTime - lastEmittedEnd) > 0.001 {
        lastKept = false
      }
      lastEmittedEnd = frame.startTime + Double(frame.samples.count) / Double(Self.sampleRate)
      let keep = frame.keep && !frame.muted
      frame.samples = frame.muted
        ? Array(repeating: 0, count: frame.samples.count)
        : render(frame.samples, keep: keep)
      lastKept = keep
      let expected = runStart + Double(runSamples.count) / Double(Self.sampleRate)
      if !runSamples.isEmpty, abs(frame.startTime - expected) > 0.001 {
        chunks.append(Self.chunk(startTime: runStart, samples: runSamples))
        runSamples.removeAll(keepingCapacity: true)
      }
      if runSamples.isEmpty { runStart = frame.startTime }
      runSamples.append(contentsOf: frame.samples)
    }
    pending.removeFirst(readyCount)
    if !runSamples.isEmpty {
      chunks.append(Self.chunk(startTime: runStart, samples: runSamples))
    }
    return chunks
  }

  /// Kept frames pass unchanged; the first one after silence fades in and the first dropped
  /// frame fades out, so the gate does not click. Muted frames are always pure silence.
  private func render(_ samples: [Float], keep: Bool) -> [Float] {
    let fade = min(Self.fadeSampleCount, samples.count)
    if keep {
      guard !lastKept, fade > 0 else { return samples }
      var result = samples
      for index in 0..<fade {
        result[index] *= Float(index) / Float(fade)
      }
      return result
    }
    var result = Array(repeating: Float.zero, count: samples.count)
    if lastKept {
      for index in 0..<fade {
        result[index] = samples[index] * (1 - Float(index) / Float(fade))
      }
    }
    return result
  }

  private static func chunk(startTime: TimeInterval, samples: [Float]) -> MeetingAudioChunk {
    MeetingAudioChunk(
      source: .microphone,
      samples: samples,
      startTime: startTime,
      duration: Double(samples.count) / Double(sampleRate)
    )
  }

  static func decibels(_ power: Float) -> Float {
    10 * log10(max(power, 1e-12))
  }
}

extension MeetingAudioChunk {
  func replacingSamples(_ samples: [Float]) -> MeetingAudioChunk {
    MeetingAudioChunk(source: source, samples: samples, startTime: startTime, duration: duration)
  }
}
