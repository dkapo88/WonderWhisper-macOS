import AVFoundation
import Foundation

/// Writes saved 16 kHz mono microphone audio through the microphone gate, for recovery from
/// the retained segments: the recovered transcript leaves out what the live gate left out.
final class MeetingMicrophoneGatedWriter {
  enum WriterError: LocalizedError {
    case unsupportedFormat
    case allocationFailed

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat: return "Meeting microphone audio is not 16 kHz mono."
      case .allocationFailed: return "Could not allocate a microphone audio buffer."
      }
    }
  }

  static let processingFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: Double(MeetingMicrophoneGate.sampleRate),
    channels: 1,
    interleaved: false
  )

  private let output: AVAudioFile
  /// The gate, with what it has learned (noise floor, the user's level), for the next file.
  private(set) var gate: MeetingMicrophoneGate
  /// Whether any audio was let through (false: nothing in it was speech).
  private(set) var keptAudio = false

  init(output: AVAudioFile, gate: MeetingMicrophoneGate) {
    self.output = output
    self.gate = gate
  }

  convenience init(output: AVAudioFile, settings: MeetingMicrophoneGateSettings) {
    self.init(output: output, gate: MeetingMicrophoneGate(settings: settings))
  }

  /// `samples` start at `startTime` on the meeting timeline and follow the previous call.
  func write(_ samples: [Float], startTime: TimeInterval) throws {
    let chunk = MeetingAudioChunk(
      source: .microphone,
      samples: samples,
      startTime: startTime,
      duration: Double(samples.count) / Double(MeetingMicrophoneGate.sampleRate)
    )
    for gated in gate.process(chunk) {
      try append(gated.samples)
    }
  }

  func finish() throws {
    for gated in gate.flush() {
      try append(gated.samples)
    }
  }

  private func append(_ samples: [Float]) throws {
    guard !samples.isEmpty else { return }
    guard let format = Self.processingFormat,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
          ),
          let channel = buffer.floatChannelData?.pointee else {
      throw WriterError.allocationFailed
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { pointer in
      if let baseAddress = pointer.baseAddress {
        channel.update(from: baseAddress, count: samples.count)
      }
    }
    if !keptAudio, samples.contains(where: { $0 != 0 }) {
      keptAudio = true
    }
    try output.write(from: buffer)
  }

  /// Writes a gated copy of one saved microphone segment that starts at `startTime`.
  /// Returns false when nothing in it was let through, so it need not be transcribed.
  static func writeGatedCopy(
    of inputURL: URL,
    startTime: TimeInterval,
    settings: MeetingMicrophoneGateSettings,
    to outputURL: URL
  ) throws -> Bool {
    var gate = MeetingMicrophoneGate(settings: settings)
    return try writeGatedCopy(of: inputURL, startTime: startTime, gate: &gate, to: outputURL)
  }

  /// Runs a saved microphone segment through `gate` without writing anything, so it learns the
  /// noise floor and the user's level from audio before the part being recovered.
  static func warm(
    _ gate: inout MeetingMicrophoneGate,
    with inputURL: URL,
    startTime: TimeInterval
  ) throws {
    try forEachBlock(of: inputURL, startTime: startTime) { chunk in
      _ = gate.process(chunk)
    }
    _ = gate.flush()
  }

  private static func forEachBlock(
    of inputURL: URL,
    startTime: TimeInterval,
    _ body: (MeetingAudioChunk) throws -> Void
  ) throws {
    let input = try AVAudioFile(
      forReading: inputURL,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    guard let format = processingFormat,
          input.processingFormat.sampleRate == format.sampleRate,
          input.processingFormat.channelCount == 1 else {
      throw WriterError.unsupportedFormat
    }
    let blockSize = AVAudioFrameCount(MeetingStereoAligner.frameSampleCount)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
      throw WriterError.allocationFailed
    }
    var position: AVAudioFramePosition = 0
    while input.framePosition < input.length {
      let remaining = AVAudioFrameCount(min(Int64(blockSize), input.length - input.framePosition))
      try input.read(into: buffer, frameCount: remaining)
      guard buffer.frameLength > 0, let channel = buffer.floatChannelData?.pointee else { break }
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
      try body(MeetingAudioChunk(
        source: .microphone,
        samples: samples,
        startTime: startTime + Double(position) / format.sampleRate,
        duration: Double(samples.count) / format.sampleRate
      ))
      position += AVAudioFramePosition(buffer.frameLength)
    }
  }

  /// As above, continuing `gate` from the previous segment so its noise floor and the user's
  /// level carry over instead of being learned again for every saved minute.
  static func writeGatedCopy(
    of inputURL: URL,
    startTime: TimeInterval,
    gate: inout MeetingMicrophoneGate,
    to outputURL: URL
  ) throws -> Bool {
    let input = try AVAudioFile(
      forReading: inputURL,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    guard let format = processingFormat,
          input.processingFormat.sampleRate == format.sampleRate,
          input.processingFormat.channelCount == 1 else {
      throw WriterError.unsupportedFormat
    }
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: input.fileFormat.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let writer = MeetingMicrophoneGatedWriter(output: output, gate: gate)
    defer { gate = writer.gate }
    let blockSize = AVAudioFrameCount(MeetingStereoAligner.frameSampleCount)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
      throw WriterError.allocationFailed
    }
    var position: AVAudioFramePosition = 0
    while input.framePosition < input.length {
      let remaining = AVAudioFrameCount(min(Int64(blockSize), input.length - input.framePosition))
      try input.read(into: buffer, frameCount: remaining)
      guard buffer.frameLength > 0, let channel = buffer.floatChannelData?.pointee else { break }
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
      try writer.write(
        samples,
        startTime: startTime + Double(position) / format.sampleRate
      )
      position += AVAudioFramePosition(buffer.frameLength)
    }
    try writer.finish()
    // Written audio is only complete on disk once the file is closed.
    output.close()
    return writer.keptAudio
  }
}
