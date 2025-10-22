import Foundation
import AVFoundation

final class AssemblyAIStreamingProvider: TranscriptionProvider {
  private let apiKey: String
  private let session: URLSession

  // Live session state (v3)
  private var liveTask: URLSessionWebSocketTask?
  private var liveAccumulator: TranscriptAccumulator?
  private var liveReceiveTask: Task<Void, Never>?
  private var pendingBinaryChunks: [Data] = []

  init(apiKey: String) {
    self.apiKey = apiKey
    let config = NetworkConfiguration.createConfiguration(timeout: 60, maxConnections: 4)
    config.timeoutIntervalForResource = 300
    self.session = URLSession(configuration: config)
  }

  // MARK: TranscriptionProvider
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderError.missingAPIKey
    }

    // AssemblyAI Realtime v3 endpoint (WebSocket). Sample rate must match audio sent.
    // Reference: https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api
    let sampleRate: Double = 16_000
    // Tunable end-of-turn parameters; allow a fast endpointing mode
    let fast = UserDefaults.standard.bool(forKey: "transcription.fastEndpointing")
    let minSilence = fast ? 120 : 160
    let maxSilence = fast ? 600 : 2400
    let query = [
      "sample_rate=\(Int(sampleRate))",
      "format_turns=true",
      "end_of_turn_confidence_threshold=0.6",
      "min_end_of_turn_silence_when_confident=\(minSilence)",
      "max_turn_silence=\(maxSilence)"
    ].joined(separator: "&")
    guard let url = URL(string: "wss://streaming.assemblyai.com/v3/ws?\(query)") else {
      throw ProviderError.invalidURL
    }

    // Open WebSocket with Authorization header
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    // Some environments prefer an Origin; harmless to include for compatibility
    request.setValue("https://api.assemblyai.com", forHTTPHeaderField: "Origin")
    let task = session.webSocketTask(with: request)
    task.resume()

    // v2 does not require explicit session parameters; query includes sample_rate

    // Start a background receiver to collect transcripts
    let transcripts = TranscriptAccumulator()
    let receiveTask = Task {
      await self.receiveLoop(task: task, accumulator: transcripts)
    }

    // Do not block: buffer file chunks until Begin

    do {
      // Read the file as audio and stream PCM16 frames (binary)
      try await streamFileAsPCM16(url: fileURL, sampleRate: sampleRate, to: task)

      // Send v3 termination message
      try await sendJSON(["type": "Terminate"], over: task)

      // Keep socket open to receive final messages; wait for Termination or timeout
      try await transcripts.waitForTermination(timeoutSeconds: 3.0)
    } catch {
      receiveTask.cancel()
      task.cancel(with: .goingAway, reason: nil)
      throw error
    }

    receiveTask.cancel()
    let finalText = await transcripts.finalTranscript()
    return finalText
  }

  // MARK: - Realtime v3 live session API
  func beginRealtimeSession(sampleRate: Double = 16_000) async throws {
    guard liveTask == nil else { return }
    let fast = UserDefaults.standard.bool(forKey: "transcription.fastEndpointing")
    let minSilence = fast ? 120 : 160
    let maxSilence = fast ? 600 : 2400
    let query = [
      "sample_rate=\(Int(sampleRate))",
      "format_turns=true",
      "end_of_turn_confidence_threshold=0.6",
      "min_end_of_turn_silence_when_confident=\(minSilence)",
      "max_turn_silence=\(maxSilence)"
    ].joined(separator: "&")
    guard let url = URL(string: "wss://streaming.assemblyai.com/v3/ws?\(query)") else {
      throw ProviderError.invalidURL
    }
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("https://assemblyai.com", forHTTPHeaderField: "Origin")
    let task = session.webSocketTask(with: request)
    task.resume()
    let accumulator = TranscriptAccumulator()
    self.liveAccumulator = accumulator
    self.liveTask = task
    self.liveReceiveTask = Task { [weak self] in
      await self?.receiveLoop(task: task, accumulator: accumulator)
    }
    // Do not block start; we will buffer and flush when Begin arrives
  }

  func feedPCM16(_ data: Data) async throws {
    guard let task = liveTask, let acc = liveAccumulator else { return }
    if await acc.hasBegun() {
      try await task.send(.data(data))
    } else {
      pendingBinaryChunks.append(data)
    }
  }

  func endRealtimeSessionAndGetTranscript() async throws -> String {
    guard let task = liveTask, let accumulator = liveAccumulator else { return "" }
    // Send termination and wait
    try await sendJSON(["type": "Terminate"], over: task)
    try await accumulator.waitForTermination(timeoutSeconds: 3.0)
    liveReceiveTask?.cancel()
    task.cancel(with: .goingAway, reason: nil)
    self.liveTask = nil
    self.liveReceiveTask = nil
    let text = await accumulator.finalTranscript()
    self.liveAccumulator = nil
    pendingBinaryChunks.removeAll(keepingCapacity: false)  // Clean up pending chunks
    return text
  }

  // MARK: - Sending helpers
  private func sendJSON(_ dict: [String: Any], over task: URLSessionWebSocketTask) async throws {
    let data = try JSONSerialization.data(withJSONObject: dict, options: [])
    guard let text = String(data: data, encoding: .utf8) else { return }
    try await task.send(.string(text))
  }

  private func sendAudioChunk(_ pcm16le: Data, over task: URLSessionWebSocketTask) async throws {
    // v3 expects raw binary PCM16 frames (little-endian)
    try await task.send(.data(pcm16le))
  }

  // MARK: - Receive loop
  private func receiveLoop(task: URLSessionWebSocketTask, accumulator: TranscriptAccumulator?) async {
    while true {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          await accumulator?.ingest(jsonText: text)
          if let acc = accumulator { await flushPendingIfReady(task: task, accumulator: acc) }
        case .data:
          break // Not expected
        @unknown default:
          break
        }
      } catch {
        break
      }
    }
  }

  private func flushPendingIfReady(task: URLSessionWebSocketTask, accumulator: TranscriptAccumulator) async {
    guard await accumulator.hasBegun() else { return }
    while !pendingBinaryChunks.isEmpty {
      let first = pendingBinaryChunks.removeFirst()
      try? await task.send(.data(first))
    }
  }

  // Abort live session immediately without attempting to finalize
  func abortRealtimeSession() async {
    liveReceiveTask?.cancel()
    liveTask?.cancel(with: .goingAway, reason: nil)
    liveTask = nil
    liveReceiveTask = nil
    liveAccumulator = nil
    pendingBinaryChunks.removeAll(keepingCapacity: false)  // Release capacity to free memory
  }

  // MARK: - Audio streaming
  private func streamFileAsPCM16(url: URL, sampleRate: Double, to task: URLSessionWebSocketTask) async throws {
    // Convert source file to mono PCM16 16k and stream in ~50ms chunks
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    let sourceFile = try AVAudioFile(forReading: url)
    let converter = AVAudioConverter(from: sourceFile.processingFormat, to: targetFormat)!

    // 50ms frames at 16kHz = 800 samples per channel
    let frameCount: AVAudioFrameCount = 800
    let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)!

    var eof = false
    while !eof {
      let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
        do {
          let readCapacity = min(2048, Int(inNumPackets))
          guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: AVAudioFrameCount(readCapacity)) else {
            outStatus.pointee = .noDataNow
            return nil
          }
          try sourceFile.read(into: inputBuffer)
          if inputBuffer.frameLength == 0 {
            outStatus.pointee = .endOfStream
            return nil
          }
          outStatus.pointee = .haveData
          return inputBuffer
        } catch {
          outStatus.pointee = .endOfStream
          return nil
        }
      }

      outputBuffer.frameLength = frameCount
      let status = converter.convert(to: outputBuffer, error: nil, withInputFrom: inputBlock)
      switch status {
      case .haveData:
        if let data = outputBuffer.int16ChannelData {
          let samples = data[0]
          let bytes = UnsafeBufferPointer(start: samples, count: Int(outputBuffer.frameLength))
          let chunk = Data(buffer: bytes)
          if let acc = liveAccumulator { await flushPendingIfReady(task: task, accumulator: acc) }
          if let acc = liveAccumulator, await acc.hasBegun() {
            try await sendAudioChunk(chunk, over: task)
          } else {
            pendingBinaryChunks.append(chunk)
          }
          // Maintain ~50ms pacing to mimic realtime
          try await Task.sleep(nanoseconds: 50_000_000)
        }
      case .endOfStream:
        eof = true
      case .inputRanDry, .error:
        eof = true
      @unknown default:
        eof = true
      }
    }
  }
}

// MARK: - Accumulator
private actor TranscriptAccumulator {
  private var segments: [String] = []
  private var lastAppended: String = ""
  private var terminated: Bool = false
  private var began: Bool = false

  func ingest(jsonText: String) {
    guard let data = jsonText.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

    // v3 message types: Begin, Turn, Termination
    if let type = obj["type"] as? String {
      switch type {
      case "Turn":
        if let transcript = obj["transcript"] as? String, !transcript.isEmpty {
          // Prefer only formatted final turns if available
          let isFormatted = (obj["turn_is_formatted"] as? Bool) ?? true
          if isFormatted && transcript != lastAppended {
            segments.append(transcript)
            lastAppended = transcript
          }
        }
      case "Begin":
        began = true
        break
      case "Termination":
        terminated = true
      default:
        break
      }
    } else if let transcript = obj["transcript"] as? String, !transcript.isEmpty {
      if transcript != lastAppended {
        segments.append(transcript)
        lastAppended = transcript
      }
    }
  }

  func finalTranscript() -> String {
    return segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func waitForTermination(timeoutSeconds: Double) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if terminated { return }
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
  }

  func waitForBegin(timeoutSeconds: Double) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if began { return }
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
  }

  func hasBegun() -> Bool { began }
}



