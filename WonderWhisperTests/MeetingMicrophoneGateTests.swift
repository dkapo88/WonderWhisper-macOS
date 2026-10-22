import AVFoundation
import Foundation
import Testing
@testable import WonderWhisper

struct MeetingMicrophoneGateTests {
  private static let sampleRate = Double(MeetingMicrophoneGate.sampleRate)

  /// Deterministic white noise at a given RMS level (dBFS).
  private static func noise(seconds: Double, level: Float, seed: UInt64 = 1) -> [Float] {
    var state = seed
    let amplitude = pow(10, level / 20) * Float(3).squareRoot()
    return (0..<Int(seconds * sampleRate)).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let unit = Float(state >> 40) / Float(1 << 24)
      return (unit * 2 - 1) * amplitude
    }
  }

  /// Voice-like audio: a 180 Hz tone with harmonics, its loudness rising and falling four
  /// times a second like syllables, with a short pause between words, at roughly the given
  /// RMS level (dBFS).
  private static func speech(seconds: Double, level: Float) -> [Float] {
    let peak = pow(10, level / 20) * 2.2
    return (0..<Int(seconds * sampleRate)).map { index in
      let time = Double(index) / sampleRate
      // A 120 ms pause between words, every 750 ms, with faint room noise in it.
      if time.truncatingRemainder(dividingBy: 0.75) > 0.63 {
        return Float((index &* 7_919) % 1_000 - 500) / 500 * 0.0005
      }
      let syllable = 0.55 + 0.45 * sin(2 * .pi * 4 * time)
      let tone = sin(2 * .pi * 180 * time) + 0.5 * sin(2 * .pi * 360 * time)
        + 0.25 * sin(2 * .pi * 720 * time)
      return Float(syllable * tone / 1.75) * peak
    }
  }

  private static func chunks(_ samples: [Float], startTime: TimeInterval = 0) -> [MeetingAudioChunk] {
    stride(from: 0, to: samples.count, by: 1_600).map { offset in
      let slice = Array(samples[offset..<min(offset + 1_600, samples.count)])
      return MeetingAudioChunk(
        source: .microphone,
        samples: slice,
        startTime: startTime + Double(offset) / sampleRate,
        duration: Double(slice.count) / sampleRate
      )
    }
  }

  private static func run(
    _ samples: [Float],
    mode: MeetingMicrophoneGateMode,
    mutedRanges: [MeetingTimeRange] = []
  ) -> [MeetingAudioChunk] {
    var gate = MeetingMicrophoneGate(mode: mode, mutedRanges: mutedRanges)
    var output: [MeetingAudioChunk] = []
    for chunk in chunks(samples) {
      output += gate.process(chunk)
    }
    return output + gate.flush()
  }

  /// The output laid back on one timeline.
  private static func timeline(_ chunks: [MeetingAudioChunk], count: Int) -> [Float] {
    var result = [Float](repeating: 0, count: count)
    for chunk in chunks {
      let start = Int((chunk.startTime * sampleRate).rounded())
      for (offset, sample) in chunk.samples.enumerated() where start + offset < count {
        result[start + offset] = sample
      }
    }
    return result
  }

  /// Share of samples in `range` (seconds) that were let through.
  private static func keptShare(_ samples: [Float], from start: Double, to end: Double) -> Double {
    let lower = Int(start * sampleRate)
    let upper = min(samples.count, Int(end * sampleRate))
    guard upper > lower else { return 0 }
    let kept = samples[lower..<upper].filter { $0 != 0 }.count
    return Double(kept) / Double(upper - lower)
  }

  @Test func quietRoomNoiseIsSilenced() {
    let input = Self.noise(seconds: 10, level: -62)
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(output, from: 0, to: 10) == 0)
  }

  @Test func steadyBackgroundNoiseIsSilencedOnceMeasured() {
    let input = Self.noise(seconds: 10, level: -45)
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(output, from: 1.5, to: 10) == 0)
  }

  @Test func speechIsKeptWithTheStartOfTheWordAndSilenceBetweenIsDropped() {
    let quiet = Self.noise(seconds: 3, level: -65)
    let input = quiet + Self.speech(seconds: 2, level: -25) + quiet
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(output, from: 3, to: 5) > 0.97)
    // The look-ahead keeps a little before the speech starts.
    #expect(Self.keptShare(output, from: 2.9, to: 3) == 1)
    // The hangover lets the word finish, then the gate closes.
    #expect(Self.keptShare(output, from: 5, to: 5.4) == 1)
    #expect(Self.keptShare(output, from: 6, to: 8) == 0)
    #expect(Self.keptShare(output, from: 0, to: 2.7) == 0)
  }

  @Test func keptSpeechIsUnchanged() {
    let quiet = Self.noise(seconds: 2, level: -65)
    let voice = Self.speech(seconds: 2, level: -25)
    let input = quiet + voice + quiet
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    let start = Int(2.5 * Self.sampleRate)
    let end = Int(3.5 * Self.sampleRate)
    #expect(Array(output[start..<end]) == Array(input[start..<end]))
  }

  @Test func outputCoversTheInputTimelineExactlyOnce() {
    let input = Self.noise(seconds: 1, level: -65) + Self.speech(seconds: 1.234, level: -25)
    let output = Self.run(input, mode: .normal)
    #expect(output.reduce(0) { $0 + $1.samples.count } == input.count)
    var expectedStart = 0.0
    for chunk in output {
      #expect(abs(chunk.startTime - expectedStart) < 0.0001)
      #expect(abs(chunk.duration - Double(chunk.samples.count) / Self.sampleRate) < 0.0001)
      expectedStart += chunk.duration
    }
  }

  @Test func timelineGapsAreKept() {
    var gate = MeetingMicrophoneGate(mode: .normal)
    let first = Self.chunks(Self.speech(seconds: 0.5, level: -25))
    let second = Self.chunks(Self.speech(seconds: 0.5, level: -25), startTime: 10)
    var output: [MeetingAudioChunk] = []
    for chunk in first + second { output += gate.process(chunk) }
    output += gate.flush()
    let starts = output.map(\.startTime)
    #expect(starts.first == 0)
    #expect(starts.contains { abs($0 - 10) < 0.0001 })
    #expect(output.reduce(0) { $0 + $1.samples.count } == 16_000)
  }

  @Test func strictLeavesOutQuieterVoicesInTheRoom() {
    let quiet = Self.noise(seconds: 1, level: -65)
    let user = Self.speech(seconds: 3, level: -22)
    let distant = Self.speech(seconds: 2, level: -42)
    let input = quiet + user + quiet + distant + quiet
    let strict = Self.timeline(Self.run(input, mode: .strict), count: input.count)
    let normal = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(strict, from: 1, to: 4) > 0.97)
    #expect(Self.keptShare(strict, from: 5.5, to: 7) == 0)
    #expect(Self.keptShare(normal, from: 5.5, to: 7) > 0.9)
  }

  @Test func normalLeavesOutFaintVoices() {
    let quiet = Self.noise(seconds: 1, level: -65)
    let input = quiet + Self.speech(seconds: 3, level: -22) + quiet
      + Self.speech(seconds: 2, level: -52) + quiet
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(output, from: 5.5, to: 7) == 0)
  }

  @Test func offPassesEverythingThroughUnchanged() {
    let input = Self.noise(seconds: 2, level: -62)
    var gate = MeetingMicrophoneGate(mode: .off)
    var output: [MeetingAudioChunk] = []
    for chunk in Self.chunks(input) { output += gate.process(chunk) }
    #expect(gate.flush().isEmpty)
    #expect(output.flatMap(\.samples) == input)
  }

  @Test func mutedRangesAreSilencedInEveryMode() {
    let input = Self.speech(seconds: 4, level: -25)
    let muted = [MeetingTimeRange(start: 1, end: 2)]
    for mode in MeetingMicrophoneGateMode.allCases {
      let output = Self.timeline(
        Self.run(input, mode: mode, mutedRanges: muted),
        count: input.count
      )
      #expect(Self.keptShare(output, from: 1.0, to: 2.0) == 0)
      #expect(Self.keptShare(output, from: 2.6, to: 4) > 0.97)
    }
  }

  @Test func mutedRangesAreExactEvenWithOneSecondBlocks() {
    // Soniox recovery feeds the gate one second at a time.
    let input = Self.speech(seconds: 8, level: -25)
    let muted = [MeetingTimeRange(start: 2.6, end: 4.6), MeetingTimeRange(start: 0, end: 0.45)]
    for mode in MeetingMicrophoneGateMode.allCases {
      var gate = MeetingMicrophoneGate(mode: mode, mutedRanges: muted)
      var output: [MeetingAudioChunk] = []
      for offset in stride(from: 0, to: input.count, by: 16_000) {
        let block = Array(input[offset..<min(offset + 16_000, input.count)])
        output += gate.process(MeetingAudioChunk(
          source: .microphone,
          samples: block,
          startTime: Double(offset) / Self.sampleRate,
          duration: Double(block.count) / Self.sampleRate
        ))
      }
      output += gate.flush()
      let timeline = Self.timeline(output, count: input.count)
      #expect(Self.keptShare(timeline, from: 0, to: 0.45) == 0)
      #expect(Self.keptShare(timeline, from: 2.6, to: 4.6) == 0)
      #expect(Self.keptShare(timeline, from: 4.62, to: 5.0) == 1)
      #expect(Self.keptShare(timeline, from: 2.0, to: 2.58) > 0.99)
    }
  }

  @Test func aQuietMicrophoneStillOpensTheGate() {
    for level: Float in [-48, -52, -55] {
      let quiet = Self.noise(seconds: 1, level: -72)
      let input = quiet + Self.speech(seconds: 3, level: level) + quiet
      for mode in [MeetingMicrophoneGateMode.normal] {
        let output = Self.timeline(Self.run(input, mode: mode), count: input.count)
        #expect(Self.keptShare(output, from: 1.2, to: 4) > 0.95, "level \(level)")
        #expect(Self.keptShare(output, from: 4.7, to: 5) == 0, "level \(level)")
      }
    }
  }

  @Test func steadyNoiseAfterTheUserSpeaksStaysSilenced() {
    for seed: UInt64 in 1...4 {
      let room = Self.noise(seconds: 1, level: -70, seed: seed)
      let normalInput = room + Self.speech(seconds: 2, level: -38)
        + Self.noise(seconds: 30, level: -52, seed: seed + 10)
      let normal = Self.timeline(Self.run(normalInput, mode: .normal), count: normalInput.count)
      #expect(Self.keptShare(normal, from: 1.2, to: 3) > 0.95)
      #expect(Self.keptShare(normal, from: 10, to: 33) == 0)

      let strictInput = room + Self.speech(seconds: 2, level: -38)
        + Self.noise(seconds: 30, level: -50, seed: seed + 20)
      let strict = Self.timeline(Self.run(strictInput, mode: .strict), count: strictInput.count)
      #expect(Self.keptShare(strict, from: 10, to: 33) == 0)
    }
  }

  @Test func roomNoiseAtTheStartOfAStreamIsNotLetThrough() {
    for level: Float in [-58, -54, -51] {
      let input = Self.noise(seconds: 3, level: level)
      let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
      #expect(Self.keptShare(output, from: 0, to: 3) == 0, "level \(level)")
    }
  }

  @Test func speechFromTheFirstMomentIsKept() {
    let input = Self.speech(seconds: 3, level: -25) + Self.noise(seconds: 2, level: -65)
    let output = Self.timeline(Self.run(input, mode: .normal), count: input.count)
    #expect(Self.keptShare(output, from: 0.1, to: 3) > 0.97)
  }

  @Test func speechDoesNotCarryAcrossATimelineGap() {
    var gate = MeetingMicrophoneGate(mode: .normal)
    var output: [MeetingAudioChunk] = []
    let before = Self.noise(seconds: 1, level: -70) + Self.speech(seconds: 1, level: -25)
    for chunk in Self.chunks(before) { output += gate.process(chunk) }
    output += gate.flush()
    for chunk in Self.chunks(Self.noise(seconds: 2, level: -62), startTime: 60) {
      output += gate.process(chunk)
    }
    output += gate.flush()
    let after = output.filter { $0.startTime >= 60 }.flatMap(\.samples)
    #expect(after.count == 32_000)
    #expect(after.allSatisfy { $0 == 0 })
  }

  @Test func aLoudBumpBeforeSpeakingDoesNotLockOutQuieterSpeech() {
    let room = Self.noise(seconds: 1, level: -70)
    let cases: [(bumpSeconds: Double, bump: Float, speech: Float)] = [
      (0.06, -10, -32), (0.4, -14, -38), (0.3, -10, -32), (0.12, -15, -35)
    ]
    for (bumpSeconds, bump, speechLevel) in cases {
      let input = room + Self.speech(seconds: bumpSeconds, level: bump)
        + Self.speech(seconds: 6, level: speechLevel) + room
      let end = 1 + bumpSeconds + 6
      for mode in [MeetingMicrophoneGateMode.normal, .strict] {
        let output = Self.timeline(Self.run(input, mode: mode), count: input.count)
        #expect(
          Self.keptShare(output, from: end - 4, to: end) > 0.95,
          "\(mode) bump \(bump) then \(speechLevel)"
        )
      }
    }
  }

  @Test func loudSteadyRoomNoiseStaysSilenced() {
    for level: Float in [-44, -40, -36, -32] {
      let input = Self.noise(seconds: 20, level: level)
      for mode in [MeetingMicrophoneGateMode.normal, .strict] {
        let output = Self.timeline(Self.run(input, mode: mode), count: input.count)
        #expect(Self.keptShare(output, from: 0, to: 20) == 0, "\(mode) \(level)")
      }
    }
  }

  @Test func lookAheadDoesNotReachBackAcrossATimelineGap() {
    var gate = MeetingMicrophoneGate(mode: .normal)
    var output: [MeetingAudioChunk] = []
    for chunk in Self.chunks(Self.noise(seconds: 2, level: -62)) {
      output += gate.process(chunk)
    }
    for chunk in Self.chunks(Self.speech(seconds: 1, level: -25), startTime: 30) {
      output += gate.process(chunk)
    }
    output += gate.flush()
    let beforeGap = output.filter { $0.startTime < 30 }.flatMap(\.samples)
    #expect(beforeGap.count == 32_000)
    #expect(beforeGap.allSatisfy { $0 == 0 })
    let afterGap = output.filter { $0.startTime >= 30 }.flatMap(\.samples)
    #expect(afterGap.filter { $0 != 0 }.count > 13_000)
  }

  @Test func aFanStartingMidMeetingClosesTheGateQuickly() {
    let input = Self.noise(seconds: 1, level: -70) + Self.speech(seconds: 3, level: -25)
      + Self.noise(seconds: 2, level: -70) + Self.noise(seconds: 30, level: -45, seed: 9)
    for mode in [MeetingMicrophoneGateMode.normal, .strict] {
      let output = Self.timeline(Self.run(input, mode: mode), count: input.count)
      #expect(Self.keptShare(output, from: 7.5, to: 36) == 0, "\(mode)")
    }
  }

  @Test func anotherVoiceFarBelowTheUserIsLeftOut() {
    let input = Self.noise(seconds: 1, level: -70) + Self.speech(seconds: 4, level: -22)
      + Self.noise(seconds: 1, level: -70) + Self.speech(seconds: 20, level: -45)
    for mode in [MeetingMicrophoneGateMode.normal, .strict] {
      let output = Self.timeline(Self.run(input, mode: mode), count: input.count)
      #expect(Self.keptShare(output, from: 1, to: 5) > 0.95, "\(mode)")
      #expect(Self.keptShare(output, from: 6, to: 16) == 0, "\(mode)")
    }
  }

  @Test func liveMuteFlagSilencesTheChunk() {
    var gate = MeetingMicrophoneGate(mode: .off)
    let chunk = Self.chunks(Self.speech(seconds: 0.1, level: -25))[0]
    let output = gate.process(chunk, muted: true)
    #expect(output.count == 1)
    #expect(output[0].samples.allSatisfy { $0 == 0 })
    #expect(output[0].startTime == chunk.startTime)
  }

  @Test func systemAudioIsNeverGated() {
    var gate = MeetingMicrophoneGate(mode: .strict)
    let chunk = MeetingAudioChunk(
      source: .systemAudio,
      samples: Self.noise(seconds: 0.1, level: -62),
      startTime: 0,
      duration: 0.1
    )
    #expect(gate.process(chunk, muted: true).first?.samples == chunk.samples)
  }

  @Test func muteRecorderJoinsChunksAndAnswersByTime() {
    let recorder = MeetingMicrophoneMuteRecorder()
    #expect(!recorder.observe(start: 0, end: 0.1))
    recorder.setMuted(true)
    #expect(recorder.observe(start: 0.1, end: 0.2))
    #expect(recorder.observe(start: 0.2, end: 0.3))
    recorder.setMuted(false)
    #expect(!recorder.observe(start: 0.3, end: 0.4))
    recorder.setMuted(true)
    recorder.observe(start: 5, end: 5.1)
    #expect(recorder.ranges == [
      MeetingTimeRange(start: 0.1, end: 0.3),
      MeetingTimeRange(start: 5, end: 5.1)
    ])
    #expect(recorder.covers(start: 0.2, end: 0.3))
    #expect(!recorder.covers(start: 0.3, end: 0.4))
  }

  @Test func liveGateSilencesWhatTheRecorderMarkedMuted() {
    let recorder = MeetingMicrophoneMuteRecorder()
    let gate = MeetingLiveMicrophoneGate(mode: .off, muteRecorder: recorder)
    let chunks = Self.chunks(Self.speech(seconds: 0.3, level: -25))
    recorder.observe(start: 0, end: 0.1)
    recorder.setMuted(true)
    recorder.observe(start: 0.1, end: 0.2)
    recorder.setMuted(false)
    recorder.observe(start: 0.2, end: 0.3)
    let output = chunks.flatMap { gate.process($0) }
    #expect(output.count == 3)
    #expect(output[0].samples == chunks[0].samples)
    #expect(output[1].samples.allSatisfy { $0 == 0 })
    #expect(output[2].samples == chunks[2].samples)
    #expect(gate.flush().isEmpty)
  }

  @Test func muteRecorderKeepsEarlierRangesOnResume() {
    let earlier = [MeetingTimeRange(start: 1, end: 2)]
    let recorder = MeetingMicrophoneMuteRecorder(ranges: earlier)
    recorder.setMuted(true)
    recorder.observe(start: 30, end: 30.1)
    #expect(recorder.ranges.first == earlier[0])
    #expect(recorder.ranges.count == 2)
  }

  @Test func gateModeDefaultsToNormalAndReadsSavedValues() throws {
    let suite = "MeetingMicrophoneGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(MeetingMicrophoneGateMode.selected(defaults: defaults) == .normal)
    defaults.set("strict", forKey: MeetingMicrophoneGateMode.defaultsKey)
    #expect(MeetingMicrophoneGateMode.selected(defaults: defaults) == .strict)
    defaults.set("nonsense", forKey: MeetingMicrophoneGateMode.defaultsKey)
    #expect(MeetingMicrophoneGateMode.selected(defaults: defaults) == .normal)
  }

  @Test func gatedCopyOfASavedSegmentDropsSilenceAndKeepsSpeech() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingMicrophoneGateTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = try #require(MeetingMicrophoneGatedWriter.processingFormat)

    func write(_ samples: [Float], to url: URL) throws {
      let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
      )
      buffer.frameLength = AVAudioFrameCount(samples.count)
      for (index, sample) in samples.enumerated() {
        buffer.floatChannelData?.pointee[index] = sample
      }
      try file.write(from: buffer)
      file.close()
    }

    func read(_ url: URL) throws -> [Float] {
      let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
      var samples: [Float] = []
      // One read can return fewer frames than asked for.
      while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        samples += UnsafeBufferPointer(
          start: buffer.floatChannelData?.pointee,
          count: Int(buffer.frameLength)
        )
      }
      return samples
    }

    let silentURL = directory.appendingPathComponent("microphone-1.caf")
    try write(Self.noise(seconds: 3, level: -62), to: silentURL)
    let silentCopy = directory.appendingPathComponent("silent-gated.caf")
    #expect(try !MeetingMicrophoneGatedWriter.writeGatedCopy(
      of: silentURL,
      startTime: 0,
      settings: MeetingMicrophoneGateSettings(mode: .normal),
      to: silentCopy
    ))

    let quiet = Self.noise(seconds: 1, level: -65)
    let input = quiet + Self.speech(seconds: 1, level: -25) + quiet + quiet
    let speechURL = directory.appendingPathComponent("microphone-2.caf")
    try write(input, to: speechURL)
    let speechCopy = directory.appendingPathComponent("speech-gated.caf")
    #expect(try MeetingMicrophoneGatedWriter.writeGatedCopy(
      of: speechURL,
      startTime: 60,
      settings: MeetingMicrophoneGateSettings(
        mode: .normal,
        mutedRanges: [MeetingTimeRange(start: 0, end: 30)]
      ),
      to: speechCopy
    ))
    let gated = try read(speechCopy)
    #expect(gated.count == input.count)
    #expect(Self.keptShare(gated, from: 1, to: 2) > 0.97)
    #expect(Self.keptShare(gated, from: 3, to: 4) == 0)

    // One gate carried across segments keeps what it learned about the user's level.
    var carried = MeetingMicrophoneGate(mode: .normal)
    _ = try MeetingMicrophoneGatedWriter.writeGatedCopy(
      of: speechURL,
      startTime: 0,
      gate: &carried,
      to: directory.appendingPathComponent("carried-1.caf")
    )
    #expect(carried.hasLearnedSpeakingLevel)
    #expect(try MeetingMicrophoneGatedWriter.writeGatedCopy(
      of: speechURL,
      startTime: 60,
      gate: &carried,
      to: directory.appendingPathComponent("carried-2.caf")
    ))

    // A segment recorded while muted (on the meeting timeline) is not transcribed at all.
    let mutedCopy = directory.appendingPathComponent("muted-gated.caf")
    #expect(try !MeetingMicrophoneGatedWriter.writeGatedCopy(
      of: speechURL,
      startTime: 60,
      settings: MeetingMicrophoneGateSettings(
        mode: .normal,
        mutedRanges: [MeetingTimeRange(start: 59, end: 65)]
      ),
      to: mutedCopy
    ))
  }

  @Test func sessionsWithoutGateFieldsDecodeAsBefore() throws {
    let session = MeetingSession(title: "Old")
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )
    json.removeValue(forKey: "microphoneGateMode")
    json.removeValue(forKey: "microphoneMutedRanges")
    let decoded = try JSONDecoder().decode(
      MeetingSession.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.microphoneGateMode == nil)
    #expect(decoded.microphoneMutedRanges.isEmpty)
    #expect(MeetingMicrophoneGateSettings(session: decoded) == .passThrough)
    #expect(!MeetingMicrophoneGateSettings(session: decoded).changesAudio)

    json["microphoneGateMode"] = "from-the-future"
    let future = try JSONDecoder().decode(
      MeetingSession.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(future.microphoneGateMode == nil)
  }
}
