import Foundation

/// Replaces the meeting microphone's audio with silence while the user is not speaking, so
/// the transcriber cannot invent words from near-silence ("yeah, yeah") or pick up quiet
/// voices elsewhere in the room. The saved audio is never gated; only what is transcribed.
///
/// Works on 10 ms frames of 16 kHz audio. A frame counts as speech when its level (after a
/// 120 Hz high-pass, so desk rumble does not count) is above all of:
/// - the noise floor (the quietest 100 ms block of the last 5 s; once the user's level is
///   known, at most 10 dB under it, so speech without pauses is not taken for noise) plus a
///   margin,
/// - once learned, the user's own speaking level (`MeetingSpeakingLevelEstimator`) minus a
///   range (distant voices are much quieter on a headset or laptop microphone than the user),
/// - an absolute minimum.
/// Speech opens after 3 of 4 frames pass, stays open within 6 dB of the threshold, and is
/// held a little after it ends; opening needs the level to have swung by 9 dB within the last
/// half second and staying open 6 dB within the last 2 s, as speech does and steady noise
/// does not. Output runs 200 ms behind input so the start of a word is
/// kept too. Times on the chunks are unchanged.
struct MeetingMicrophoneGate {
  struct Tuning: Equatable, Sendable {
    let noiseMargin: Float
    let speakingRange: Float
    let absoluteMinimum: Float
    let hangoverFrames: Int
    let lookaheadFrames: Int
    /// How long the user's level remembers loud speech; when the user gets quieter (another
    /// microphone, gain, distance) the gate follows within this time.
    let levelMemory: TimeInterval
    /// Speech far under the user's level counts one frame in this many towards it.
    let distantVoiceWeight: Int
    /// Speech-like frames needed before the level drops by more than `speakingRange`.
    let largeDropFrames: Int

    /// Never lose the user: the level follows them down within 20 s.
    static let normal = Self(
      noiseMargin: 10,
      speakingRange: 20,
      absoluteMinimum: -60,
      hangoverFrames: 50,
      lookaheadFrames: 20,
      levelMemory: 20,
      distantVoiceWeight: 1,
      largeDropFrames: 300
    )

    /// Keep other voices out: the level is slow to follow quieter speech.
    static let strict = Self(
      noiseMargin: 15,
      speakingRange: 14,
      absoluteMinimum: -50,
      hangoverFrames: 35,
      lookaheadFrames: 20,
      levelMemory: 120,
      distantVoiceWeight: 4,
      largeDropFrames: 1_000
    )
  }

  static let sampleRate = MeetingAudioChunkFramer.sampleRate
  static let frameSampleCount = 160
  static let initialNoiseFloor: Float = -65
  /// Once the user's level is known, the noise floor counts as at most this far under it.
  static let floorBelowSpeaking: Float = 10
  static let noiseBlockFrames = 10
  static let noiseWindowBlocks = 50
  static let stayOpenHysteresis: Float = 6
  static let fadeSampleCount = 80
  /// Speech rises and falls between syllables; steady noise does not. A frame only teaches the
  /// user's level when it is this far above the quietest frame of the last half second.
  static let speechModulation: Float = 12
  static let modulationWindowFrames = 50
  /// The gate only opens while the level has swung this much within the last half second, and
  /// only stays open while it has swung `stayOpenModulation` within the last 2 s, as speech
  /// (with its breaths) does and a fan or hum that starts mid-meeting does not.
  static let openModulation: Float = 9
  static let stayOpenModulation: Float = 6
  static let stayOpenModulationFrames = 200
  /// In strict mode, once 3 s of the user's speech is known, speech far under their level
  /// (another voice in the room) is weighted down; before that a loud bump must be outgrown
  /// quickly.
  static let distantVoiceAfterFrames = 300

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
  private var speakingLevelEstimator: MeetingSpeakingLevelEstimator
  /// Index in `pending` of the first frame after the latest timeline gap; look-ahead never
  /// reaches back across a gap.
  private var contiguousStartIndex = 0
  private var nextFrameTime: TimeInterval?
  private var lastEmittedEnd: TimeInterval?
  private var recentAbove: [Bool] = []
  private var recentLevels: [Float] = []
  private var longerLevels: [Float] = []
  private var distantFrameCount = 0
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
    let levelTuning = tuning ?? .normal
    speakingLevelEstimator = MeetingSpeakingLevelEstimator(
      memory: levelTuning.levelMemory,
      largeDrop: levelTuning.speakingRange,
      largeDropFrames: levelTuning.largeDropFrames
    )
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
    speakingLevelEstimator.isLearned
  }

  var speakingLevel: Float? {
    hasLearnedSpeakingLevel ? speakingLevelEstimator.level : nil
  }

  /// The quietest 100 ms of the last 5 s; before the first 100 ms is complete, the level so
  /// far, so the gate cannot open on room noise at the start of a stream.
  var measuredNoiseFloor: Float {
    if let quietest = noiseBlockLevels.min() { return quietest }
    if noiseBlockCount > 0 { return Self.decibels(noiseBlockPower / Float(noiseBlockCount)) }
    return Self.initialNoiseFloor
  }

  /// Measured room noise; once the user's level is known, at most 10 dB under it, so long
  /// speech without a pause cannot be taken for the noise floor. Room noise never feeds the
  /// user's level, so this cannot pull the threshold under steady noise.
  var noiseFloor: Float {
    guard let speakingLevel else { return measuredNoiseFloor }
    return min(measuredNoiseFloor, speakingLevel - Self.floorBelowSpeaking)
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
      recentLevels.removeAll()
      longerLevels.removeAll()
      // A resumed meeting may use another microphone: learn the user's level again.
      speakingLevelEstimator.reset()
      distantFrameCount = 0
      highPassPreviousInput = 0
      highPassPreviousOutput = 0
      contiguousStartIndex = pending.count
    }
    nextFrameTime = frame.startTime + Double(frame.samples.count) / Double(Self.sampleRate)
    let speaking = classify(frame.samples, at: frame.startTime, muted: frame.muted)
    if speaking {
      hangoverRemaining = tuning?.hangoverFrames ?? 0
      frame.keep = true
      // Look-ahead: the frames just before speech carry the start of the word.
      let lookahead = tuning?.lookaheadFrames ?? 0
      for index in pending.indices.suffix(lookahead) where index >= contiguousStartIndex {
        pending[index].keep = true
      }
    } else if hangoverRemaining > 0 {
      hangoverRemaining -= 1
      frame.keep = true
    }
    pending.append(frame)
  }

  private mutating func classify(
    _ samples: [Float],
    at time: TimeInterval,
    muted: Bool
  ) -> Bool {
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

    recentLevels.append(level)
    if recentLevels.count > Self.modulationWindowFrames { recentLevels.removeFirst() }
    longerLevels.append(level)
    if longerLevels.count > Self.stayOpenModulationFrames { longerLevels.removeFirst() }
    // Speech-like sound clearly above the room noise teaches the user's level, whether or not
    // the gate is open, so a wrong level always corrects itself; steady noise never does.
    let recentQuietest = recentLevels.min() ?? level
    let recentLoudest = recentLevels.max() ?? level
    if !muted,
       level >= max(measuredNoiseFloor + tuning.noiseMargin, tuning.absoluteMinimum),
       level >= recentQuietest + Self.speechModulation {
      if let speakingLevel,
         tuning.distantVoiceWeight > 1,
         speakingLevelEstimator.count >= Self.distantVoiceAfterFrames,
         level < speakingLevel - tuning.speakingRange {
        distantFrameCount += 1
        if distantFrameCount % tuning.distantVoiceWeight == 0 {
          speakingLevelEstimator.add(level, at: time)
        }
      } else {
        speakingLevelEstimator.add(level, at: time)
      }
    }
    let opensModulated = recentLoudest - recentQuietest >= Self.openModulation
    let staysModulated = (longerLevels.max() ?? level) - (longerLevels.min() ?? level)
      >= Self.stayOpenModulation
    // Until the user's level is known, the quietest recent frame also counts as the floor:
    // speech that starts before the first pause dips between syllables, steady noise barely.
    let floor = hasLearnedSpeakingLevel ? noiseFloor : min(noiseFloor, recentQuietest)
    var threshold = max(floor + tuning.noiseMargin, tuning.absoluteMinimum)
    if let speakingLevel {
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
      isSpeaking = staysModulated && level >= threshold - Self.stayOpenHysteresis
    } else {
      isSpeaking = opensModulated && recentAbove.filter { $0 }.count >= 3
    }
    return isSpeaking
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
    contiguousStartIndex = max(0, contiguousStartIndex - readyCount)
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
