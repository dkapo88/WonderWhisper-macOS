import Foundation
import AVFoundation

/// Reads an audio file as 16 kHz mono Float32, the input Qwen3-ASR expects.
enum QwenAudioDecoder {
  static func decode16kMonoFloat(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    else {
      throw QwenASRError.emptyAudio
    }
    try file.read(into: sourceBuffer)

    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ) else {
      throw QwenASRError.decodeFailed
    }

    if sourceFormat.sampleRate == 16_000,
       sourceFormat.channelCount == 1,
       sourceFormat.commonFormat == .pcmFormatFloat32 {
      return floatSamples(from: sourceBuffer)
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw QwenASRError.decodeFailed
    }
    let ratio = 16_000 / sourceFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 256
    guard let dest = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
      throw QwenASRError.decodeFailed
    }

    var conversionError: NSError?
    var supplied = false
    let status = converter.convert(to: dest, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }
    if let conversionError { throw conversionError }
    if status == .error { throw QwenASRError.decodeFailed }
    return floatSamples(from: dest)
  }

  private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?.pointee else { return [] }
    let count = Int(buffer.frameLength)
    return Array(UnsafeBufferPointer(start: channel, count: count))
  }
}
