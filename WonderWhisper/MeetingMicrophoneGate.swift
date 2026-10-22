import Foundation

/// Turns the meeting microphone's audio down by 20 dB while the user is not speaking, so the
/// transcriber cannot invent words from near-silence ("yeah, yeah") or from room noise; strict
/// mode also turns down quieter voices elsewhere in the room. It is turned down rather than
/// replaced with digital silence because Grok drops about half of the real speech when the
/// audio around it is exact zeros. Muted audio is exact silence. Then
/// `MeetingMicrophoneAutoGain` brings a quiet microphone up to a level the transcriber hears.
/// The saved audio is never gated; only what is transcribed.
///
/// Works on 10 ms frames of 16 kHz audio. A frame counts as speech when its level (after a
/// 120 Hz high-pass, so desk rumble does not count) is above all of:
/// - the noise floor (the quietest 100 ms block of the last 5 s; once the user's level is
///   known, low enough under it that speech without pauses is not taken for noise) plus a
///   margin,
/// - strict only: the user's own speaking level (`MeetingSpeakingLevelEstimator`) minus a
///   range (other voices are much quieter on a headset or laptop microphone than the user),
/// - an absolute minimum.
/// Speech opens after 3 of 4 frames pass, stays open within 6 dB of the threshold (and 6 dB
/// above the floor), and is
/// held a little after it ends; it also needs the level to have swung by 6 dB within the last
/// 2 s, as speech (with its syllables and breaths) does and a steady fan or hum does not.
/// Output runs 200 ms behind input so the start of a word is kept too. Times on the chunks
/// are unchanged. With the gate off, only the gain and mutes apply.
struct MeetingMicrophoneGate {
  struct Tuning: Equatable, Sendable {
    let noiseMargin: Float
    /// Strict only: leave out speech more than `speakingRange` under the user's level. Normal
    /// mode never uses the user's level to drop audio, so it cannot lose the user.
    let usesSpeakingLevel: Bool
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

    /// Silence and noise only: other voices are transcribed, the user is never lost.
    static let normal = Self(
      noiseMargin: 10,
      usesSpeakingLevel: false,
      speakingRange: 20,
      absoluteMinimum: -72,
      hangoverFrames: 50,
      lookaheadFrames: 20,
      levelMemory: 20,
      distantVoiceWeight: 1,
      largeDropFrames: 0
    )

    /// Keep other voices out: the level is slow to follow quieter speech.
    static let strict = Self(
      noiseMargin: 15,
      usesSpeakingLevel: true,
      speakingRange: 14,
      absoluteMinimum: -55,
      hangoverFrames: 35,
      lookaheadFrames: 20,
      levelMemory: 120,
      distantVoiceWeight: 4,
      largeDropFrames: 600
    )
  }

  static let sampleRate = MeetingAudioChunkFramer.sampleRate
  static let frameSampleCount = 160
  static let initialNoiseFloor: Float = -65
  /// Once the user's level is known, the floor plus margin sits at least this far under it,
  /// so evenly loud speech without a pause stays open.
  static let thresholdBelowSpeaking: Float = 10
  static let noiseBlockFrames = 10
  static let noiseWindowBlocks = 50
  static let stayOpenHysteresis: Float = 6
  /// Staying open also needs this much above the noise floor, so room noise right after
  /// speech cannot hold the gate open.
  static let stayOpenAboveFloor: Float = 6
  static let fadeSampleCount = 80
  /// What audio the gate leaves out is multiplied by (-20 dB): quiet enough that Grok invents
  /// nothing from room noise, loud enough that the speech around it is not cut off. The gain
  /// then raises speech and left-out audio alike, so the noise stays 20 dB further under the
  /// speech than it was; that is what was checked with Grok (room noise from a built-in
  /// microphone, +26 dB then -20 dB: no words).
  static let rejectedGain: Float = 0.1
  /// Saved audio fills capture pauses with exact digital silence (`MeetingAudioGapPadding`);
  /// this much of it counts as a gap, as the live gate saw it. A microphone never gives exact
  /// zeros for this long on its own (a hardware mute that does gets a harmless fresh start).
  static let paddedPauseFrames = 30
  /// Speech rises and falls between syllables; steady noise does not. A frame only teaches the
  /// user's level when it is this far above the quietest frame of the last half second.
  static let speechModulation: Float = 12
  static let modulationWindowFrames = 50
  /// The gate only opens or stays open while the level has swung this much within the last
  /// 2 s, as speech (syllables, breaths) does and a fan or hum that starts mid-meeting does not.
  static let openModulation: Float = 6
  static let openModulationFrames = 200
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
  let rejectedGain: Float
  private var autoGain: MeetingMicrophoneAutoGain?
  /// When set, `keptRanges` collects the times of the audio let through, so recovery can tell
  /// a saved minute with no speech in it (only turned-down noise) and skip transcribing it.
  var recordsKeptRanges = false
  private(set) var keptRanges: [MeetingTimeRange] = []

  private var pending: [Frame] = []
  private var partial: [Float] = []
  private var partialStartTime: TimeInterval = 0
  private var partialMuted = false
  /// The gain the last emitted frame ended at: 1 kept, `rejectedGain` left out, 0 muted.
  private var lastGain: Float = 0

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
  private var digitalSilenceFrames = 0
  private var lastEmittedEnd: TimeInterval?
  private var recentAbove: [Bool] = []
  private var recentLevels: [Float] = []
  private var modulationLevels: [Float] = []
  private var distantFrameCount = 0
  private var isSpeaking = false
  private var hangoverRemaining = 0

  /// `mutedRanges` are on the same timeline as the chunks; audio inside them is always silenced.
  /// `rejectedGain` 0 and `levelsAudio` false show the gate's decisions alone (tests).
  init(
    mode: MeetingMicrophoneGateMode,
    mutedRanges: [MeetingTimeRange] = [],
    rejectedGain: Float = Self.rejectedGain,
    levelsAudio: Bool = true
  ) {
    self.mode = mode
    self.mutedRanges = mutedRanges
    self.rejectedGain = rejectedGain
    autoGain = levelsAudio ? MeetingMicrophoneAutoGain() : nil
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

  /// Measured room noise; once the user's level is known, capped so the threshold stays
  /// 10 dB under it and long speech without a pause cannot be taken for the noise floor. The
  /// cap only ever lowers the threshold, and room noise never feeds the user's level.
  var noiseFloor: Float {
    let measured = measuredNoiseFloor
    guard let speakingLevel else { return measured }
    let margin = tuning?.noiseMargin ?? 0
    return min(measured, speakingLevel - Self.thresholdBelowSpeaking - margin)
  }

  /// Gates one chunk. `muted` silences it whatever the gate decides (the user pressed Mute);
  /// muted ranges are checked for every 10 ms frame. Returns the audio that is ready, which
  /// runs up to 200 ms behind the input.
  mutating func process(_ chunk: MeetingAudioChunk, muted: Bool = false) -> [MeetingAudioChunk] {
    guard chunk.source == .microphone, !chunk.samples.isEmpty else { return [chunk] }
    guard tuning != nil else {
      var samples = silencingMuted(chunk.samples, startTime: chunk.startTime, muted: muted)
      if recordsKeptRanges, !muted {
        recordUnmuted(chunk.samples, startTime: chunk.startTime)
      }
      if autoGain != nil {
        samples = applyingGain(
          to: samples,
          input: chunk.samples,
          startTime: chunk.startTime,
          muted: muted
        )
      }
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

  /// With the gate off everything not muted is let through, except exact silence (a capture
  /// pause padded in the saved audio), which is nothing to transcribe.
  private mutating func recordUnmuted(_ samples: [Float], startTime: TimeInterval) {
    for offset in stride(from: 0, to: samples.count, by: Self.frameSampleCount) {
      let frameCount = min(Self.frameSampleCount, samples.count - offset)
      let start = startTime + Double(offset) / Double(Self.sampleRate)
      guard samples[offset..<(offset + frameCount)].contains(where: { $0 != 0 }),
            !isInMutedRange(startTime: start, count: frameCount) else { continue }
      recordKept(start: start, end: start + Double(frameCount) / Double(Self.sampleRate))
    }
  }

  private mutating func recordKept(start: TimeInterval, end: TimeInterval) {
    if let last = keptRanges.last, abs(last.end - start) <= 0.001 {
      keptRanges[keptRanges.count - 1] = MeetingTimeRange(start: last.start, end: end)
    } else {
      keptRanges.append(MeetingTimeRange(start: start, end: end))
    }
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
    let isDigitalSilence = !frame.samples.contains { $0 != 0 }
    let timelineGap = nextFrameTime.map { abs(frame.startTime - $0) > 0.001 } ?? false
    let afterPaddedPause = !isDigitalSilence && digitalSilenceFrames >= Self.paddedPauseFrames
    digitalSilenceFrames = isDigitalSilence ? digitalSilenceFrames + 1 : 0
    if timelineGap || afterPaddedPause {
      // A gap in the timeline (a resumed meeting, or a capture pause padded with silence in the
      // saved audio): speech does not continue across it.
      isSpeaking = false
      hangoverRemaining = 0
      recentAbove.removeAll()
      recentLevels.removeAll()
      modulationLevels.removeAll()
      // A resumed meeting may use another microphone and room: learn the user's level and the
      // noise floor again.
      speakingLevelEstimator.reset()
      noiseBlockPower = 0
      noiseBlockCount = 0
      noiseBlockLevels.removeAll()
      distantFrameCount = 0
      highPassPreviousInput = 0
      highPassPreviousOutput = 0
      contiguousStartIndex = pending.count
    }
    nextFrameTime = frame.startTime + Double(frame.samples.count) / Double(Self.sampleRate)
    let speaking = classify(
      frame.samples,
      at: frame.startTime,
      muted: frame.muted,
      digitalSilence: isDigitalSilence
    )
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
    muted: Bool,
    digitalSilence: Bool
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
    // Muted audio (the user talking to someone in the room) must not teach the gate anything:
    // not the noise floor, not the level swing, not the user's level.
    guard !muted else {
      isSpeaking = false
      hangoverRemaining = 0
      recentAbove.removeAll()
      // Swings heard before the mute must not open the gate after it.
      recentLevels.removeAll()
      modulationLevels.removeAll()
      return false
    }
    // Exact digital silence (the second or two a microphone sends before its first real audio,
    // or a hardware mute) is no room: taken for the noise floor, it would let ordinary room
    // noise through as speech for the next few seconds.
    guard !digitalSilence else { return false }

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
    modulationLevels.append(level)
    if modulationLevels.count > Self.openModulationFrames { modulationLevels.removeFirst() }
    // Speech-like sound clearly above the room noise teaches the user's level, whether or not
    // the gate is open, so a wrong level always corrects itself; steady noise never does.
    let recentQuietest = recentLevels.min() ?? level
    if level >= max(measuredNoiseFloor + tuning.noiseMargin, tuning.absoluteMinimum),
       level >= recentQuietest + Self.speechModulation {
      if let speakingLevel,
         tuning.distantVoiceWeight > 1,
         speakingLevelEstimator.count >= Self.distantVoiceAfterFrames,
         level < speakingLevel - tuning.speakingRange {
        distantFrameCount += 1
        speakingLevelEstimator.add(
          level,
          at: time,
          counts: distantFrameCount % tuning.distantVoiceWeight == 0
        )
      } else {
        speakingLevelEstimator.add(level, at: time)
      }
    }
    let modulated = (modulationLevels.max() ?? level) - (modulationLevels.min() ?? level)
      >= Self.openModulation
    // Until the user's level is known, the quietest recent frame also counts as the floor:
    // speech that starts before the first pause dips between syllables, steady noise barely.
    let floor = hasLearnedSpeakingLevel ? noiseFloor : min(noiseFloor, recentQuietest)
    var threshold = max(floor + tuning.noiseMargin, tuning.absoluteMinimum)
    if tuning.usesSpeakingLevel, let speakingLevel {
      threshold = max(threshold, speakingLevel - tuning.speakingRange)
    }
    let above = level >= threshold
    recentAbove.append(above)
    if recentAbove.count > 4 { recentAbove.removeFirst() }

    if isSpeaking {
      isSpeaking = modulated
        && level >= max(threshold - Self.stayOpenHysteresis, floor + Self.stayOpenAboveFloor)
    } else {
      isSpeaking = modulated && recentAbove.filter { $0 }.count >= 3
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
        lastGain = 0
      }
      let frameEnd = frame.startTime + Double(frame.samples.count) / Double(Self.sampleRate)
      lastEmittedEnd = frameEnd
      let keep = frame.keep && !frame.muted
      if keep, recordsKeptRanges {
        recordKept(start: frame.startTime, end: frameEnd)
      }
      let gain: Float = frame.muted ? 0 : keep ? 1 : rejectedGain
      let input = frame.samples
      frame.samples = frame.muted
        ? Array(repeating: 0, count: frame.samples.count)
        : render(frame.samples, gain: gain)
      lastGain = gain
      if autoGain != nil {
        frame.samples = applyingGain(
          to: frame.samples,
          input: input,
          startTime: frame.startTime,
          muted: frame.muted
        )
      }
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

  /// The gain, frame by frame. Muted audio is skipped rather than learned from: a mute is not
  /// another microphone, so the user's level and gain carry on when they unmute. Muted input
  /// that is exact zeros (a capture pause padded in the saved audio) still counts towards a
  /// fresh start, as it does for the gate. `input` is the audio before the gate.
  private mutating func applyingGain(
    to samples: [Float],
    input: [Float],
    startTime: TimeInterval,
    muted: Bool
  ) -> [Float] {
    var result = samples
    for offset in stride(from: 0, to: samples.count, by: Self.frameSampleCount) {
      let end = min(offset + Self.frameSampleCount, samples.count)
      let frameStart = startTime + Double(offset) / Double(Self.sampleRate)
      if muted || isInMutedRange(startTime: frameStart, count: end - offset) {
        if input[offset..<min(end, input.count)].contains(where: { $0 != 0 }) {
          autoGain?.skip(end - offset, startTime: frameStart)
        } else {
          _ = autoGain?.process(Array(samples[offset..<end]), startTime: frameStart)
        }
      } else if let gained = autoGain?.process(Array(samples[offset..<end]), startTime: frameStart) {
        result.replaceSubrange(offset..<end, with: gained)
      }
    }
    return result
  }

  /// The times let through since the last call (with `recordsKeptRanges` set).
  mutating func takeKeptRanges() -> [MeetingTimeRange] {
    defer { keptRanges.removeAll() }
    return keptRanges
  }

  /// Kept frames pass unchanged and left-out ones are turned down; where the gain changes it
  /// moves over the first 5 ms of the frame, so the gate does not click. Muted frames are always
  /// pure silence.
  private func render(_ samples: [Float], gain: Float) -> [Float] {
    let fade = min(Self.fadeSampleCount, samples.count)
    if gain == lastGain || fade == 0 {
      return gain == 1 ? samples : samples.map { $0 * gain }
    }
    var result = samples
    for index in result.indices {
      let ramp = index < fade
        ? lastGain + (gain - lastGain) * Float(index) / Float(fade)
        : gain
      result[index] *= ramp
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

  /// Always finite: a corrupt sample (infinite, or so large its square overflows) must not
  /// reach the level estimators, which turn levels into histogram bins.
  static func decibels(_ power: Float) -> Float {
    guard !power.isNaN else { return -120 }
    return min(10 * log10(max(power, 1e-12)), 40)
  }
}

extension MeetingAudioChunk {
  func replacingSamples(_ samples: [Float]) -> MeetingAudioChunk {
    MeetingAudioChunk(source: source, samples: samples, startTime: startTime, duration: duration)
  }
}
