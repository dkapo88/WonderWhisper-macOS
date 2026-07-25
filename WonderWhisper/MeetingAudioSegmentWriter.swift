import AVFoundation
import Foundation

enum MeetingAudioSegmentWriterError: LocalizedError {
  case bufferAllocationFailed
  case fileAlreadyExists(String)

  var errorDescription: String? {
    switch self {
    case .bufferAllocationFailed:
      return "Could not allocate a buffer for retained meeting audio."
    case .fileAlreadyExists(let filename):
      return "Retained meeting audio already exists at \(filename)."
    }
  }
}

final class MeetingAudioSegmentWriter {
  private let directory: URL
  private let source: MeetingAudioSource
  private let segmentFrameLimit: Int
  private let processingFormat: AVAudioFormat?
  private let fileSettings: [String: Any]

  private var currentFile: AVAudioFile?
  private var currentSegmentFrames = 0
  private var segmentIndex: Int
  private let initialSegmentIndex: Int
  private let timelineOffset: TimeInterval
  private(set) var filenames: [String] = []

  init(directory: URL,
       source: MeetingAudioSource,
       segmentDuration: TimeInterval = 60,
       initialSegmentIndex: Int = 0,
       timelineOffset: TimeInterval = 0) {
    self.directory = directory
    self.source = source
    self.segmentFrameLimit = max(16_000, Int(segmentDuration * 16_000))
    self.segmentIndex = max(0, initialSegmentIndex)
    self.initialSegmentIndex = max(0, initialSegmentIndex)
    self.timelineOffset = max(0, timelineOffset)
    self.processingFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )
    self.fileSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]
  }

  func append(samples: [Float]) throws {
    var offset = 0
    while offset < samples.count {
      if currentFile == nil || currentSegmentFrames >= segmentFrameLimit {
        try rotateFile()
      }
      let available = segmentFrameLimit - currentSegmentFrames
      let count = min(available, samples.count - offset)
      try write(samples: samples, offset: offset, count: count)
      offset += count
      currentSegmentFrames += count
    }
  }

  func finish() {
    currentFile = nil
    currentSegmentFrames = 0
  }

  private func rotateFile() throws {
    currentFile = nil
    currentSegmentFrames = 0
    segmentIndex += 1
    let filename: String
    if timelineOffset > 0 {
      let localSegment = segmentIndex - initialSegmentIndex - 1
      let startTime = timelineOffset
        + Double(localSegment * segmentFrameLimit) / 16_000
      filename = String(
        format: "%@-%04d-%lld.caf",
        source.filenamePrefix,
        segmentIndex,
        Int64((startTime * 1_000).rounded())
      )
    } else {
      filename = String(
        format: "%@-%04d.caf",
        source.filenamePrefix,
        segmentIndex
      )
    }
    let url = directory.appendingPathComponent(filename)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw MeetingAudioSegmentWriterError.fileAlreadyExists(filename)
    }
    currentFile = try AVAudioFile(
      forWriting: url,
      settings: fileSettings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    filenames.append(filename)
  }

  private func write(samples: [Float], offset: Int, count: Int) throws {
    guard count > 0 else { return }
    guard let file = currentFile,
          let processingFormat,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(count)
          ),
          let channel = buffer.floatChannelData?.pointee else {
      throw MeetingAudioSegmentWriterError.bufferAllocationFailed
    }
    buffer.frameLength = AVAudioFrameCount(count)
    samples.withUnsafeBufferPointer { sourceBuffer in
      guard let baseAddress = sourceBuffer.baseAddress else { return }
      channel.update(from: baseAddress.advanced(by: offset), count: count)
    }
    try file.write(from: buffer)
  }
}
