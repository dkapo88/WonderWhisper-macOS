import Foundation
import AVFoundation
import OSLog

// Deepgram Streaming (v1 listen) – binary PCM16 frames over WebSocket
// Docs: https://developers.deepgram.com/docs/live-streaming-audio
final class DeepgramStreamingProvider: TranscriptionProvider {
  private let apiKey: String
  private let session: URLSession

  // Live state
  private var ws: URLSessionWebSocketTask?
  private var recvTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var acc: DeepgramAccumulator?
  private var isConnected: Bool = false
  private var connectionStartTime: Date?
  private var reconnectAttempts: Int = 0
  private let maxReconnectAttempts: Int = 3

  init(apiKey: String) {
    self.apiKey = apiKey
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 10  // Reduced from 60
    cfg.timeoutIntervalForResource = 120 // Reduced from 300
    cfg.waitsForConnectivity = false // Don't wait if no connectivity
    cfg.allowsCellularAccess = true
    self.session = URLSession(configuration: cfg)
  }

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingAPIKey }
    try await beginRealtime()
    // Stream file as PCM16 16 kHz mono in ~50ms chunks
    try await streamFileAsPCM16(url: fileURL, sampleRate: 16_000)
    // Close stream; Deepgram finalizes when stream ends
    let text = try await endRealtime()
    return text
  }

  // Live API used by DictationController for mic streaming
  func beginRealtime() async throws {
    // Clean up any existing connection first
    if ws != nil {
      AppLog.dictation.log("Deepgram: Cleaning up existing connection before starting new one")
      await cleanupConnection()
    }
    
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      AppLog.dictation.error("Deepgram: API key is missing or empty")
      throw ProviderError.missingAPIKey
    }

    // Build URL with parameters; allow fast-path formatting toggle and explicit language
    var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
    let lang = UserDefaults.standard.string(forKey: "transcription.language") ?? "en-US"
    let fastFmt = UserDefaults.standard.bool(forKey: "transcription.fastFormatting")
    let smart = fastFmt ? "false" : "true"
    let punct = fastFmt ? "false" : "true"
    comps.queryItems = [
      URLQueryItem(name: "model", value: "nova-2"),
      URLQueryItem(name: "language", value: lang),
      URLQueryItem(name: "smart_format", value: smart),
      URLQueryItem(name: "punctuate", value: punct),
      URLQueryItem(name: "encoding", value: "linear16"),
      URLQueryItem(name: "sample_rate", value: "16000"),
      URLQueryItem(name: "channels", value: "1"),
      URLQueryItem(name: "endpointing", value: "true"),
      URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "filler_words", value: "false"),
      URLQueryItem(name: "profanity_filter", value: "false")
    ]
    guard let url = comps.url else {
      AppLog.dictation.error("Deepgram: Failed to create WebSocket URL")
      throw ProviderError.invalidURL
    }
    
    var req = URLRequest(url: url)
    // Fix authentication format - should be lowercase 'token'
    req.setValue("token \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 5.0 // Reduced to 5 second connection timeout for faster failure detection
    
    AppLog.dictation.log("Deepgram: Initiating WebSocket connection to \(url.absoluteString)")
    
    // Deepgram allows binary PCM; we'll send 16 kHz mono PCM16
    let task = session.webSocketTask(with: req)
    task.resume()
    
    let acc = DeepgramAccumulator()
    self.acc = acc
    self.ws = task
    self.connectionStartTime = Date()
    self.isConnected = false
    self.reconnectAttempts = 0 // Reset reconnection counter on new session
    
    // Start message receive loop
    self.recvTask = Task { [weak self] in
      await self?.receiveLoop(task: task, accumulator: acc)
    }
    
    // Start keep-alive mechanism
    self.keepAliveTask = Task { [weak self] in
      await self?.keepAliveLoop(task: task)
    }

    AppLog.dictation.log("Deepgram: WebSocket connection initiated successfully")
    // No artificial delay; first successful send will confirm readiness
  }

  func feedPCM16(_ data: Data) async throws {
    guard let task = ws else {
      // Silently return if no WebSocket - don't spam errors during normal shutdown
      return
    }
    
    // Try to send even if not marked as connected - WebSocket might be ready
    do {
      // Send immediately; Deepgram v1/listen accepts binary after WS open
      try await task.send(.data(data))
      // Mark as connected on successful send if not already marked
      if !isConnected {
        isConnected = true
        AppLog.dictation.log("Deepgram: Connection confirmed via successful audio send")
      }
      // Only log periodically to avoid spam
      if data.count > 0 && Int.random(in: 1...200) == 1 {
        AppLog.dictation.log("Deepgram: Sent \(data.count) bytes of audio data")
      }
    } catch {
      // Only log connection errors occasionally to avoid spam
      if Int.random(in: 1...50) == 1 {
        AppLog.dictation.error("Deepgram: Failed to send audio data: \(error.localizedDescription)")
      }
      isConnected = false
      // Don't throw - let the connection attempt to recover
    }
  }

  func endRealtime() async throws -> String {
    guard let task = ws, let acc = acc else { return "" }
    
    AppLog.dictation.log("Deepgram: Ending realtime session")
    
    // Send a final message to signal end of audio stream (optional)
    let finishMessage = ["type": "CloseStream"]
    if let jsonData = try? JSONSerialization.data(withJSONObject: finishMessage),
       let jsonString = String(data: jsonData, encoding: .utf8) {
      try? await task.send(.string(jsonString))
    }
    
    // Reduce wait time for final messages - shorter delay for better responsiveness
    try? await Task.sleep(nanoseconds: 150_000_000) // Reduced from 300ms to 150ms
    
    // Clean up tasks and connection
    recvTask?.cancel()
    keepAliveTask?.cancel()
    task.cancel(with: .goingAway, reason: nil)
    
    let sessionDuration = connectionStartTime.map { Date().timeIntervalSince($0) } ?? 0
    AppLog.dictation.log("Deepgram: Session ended after \(String(format: "%.2f", sessionDuration))s")
    
    // Clean up connection
    await cleanupConnection()
    self.connectionStartTime = nil
    
    let text = await acc.finalTranscript()
    self.acc = nil
    return text
  }

  // Internal helpers
  private func receiveLoop(task: URLSessionWebSocketTask, accumulator: DeepgramAccumulator) async {
    AppLog.dictation.log("Deepgram: Starting message receive loop")
    
    while !Task.isCancelled && ws === task {
      do {
        let message = try await task.receive()
        
        // Validate we're still using the same connection
        guard ws === task && !Task.isCancelled else {
          AppLog.dictation.log("Deepgram: Connection changed during receive, exiting loop")
          break
        }
        
        switch message {
        case .string(let text):
          if !isConnected {
            isConnected = true
            AppLog.dictation.log("Deepgram: WebSocket connection established")
          }
          await accumulator.ingest(jsonText: text)
          
        case .data(let data):
          AppLog.dictation.log("Deepgram: Received binary data (\(data.count) bytes) - unexpected")
          
        @unknown default:
          AppLog.dictation.log("Deepgram: Received unknown message type")
        }
      } catch {
        let nsError = error as NSError
        // Only log connection errors if we haven't already disconnected
        if isConnected {
          AppLog.dictation.error("Deepgram: WebSocket receive error - \(nsError.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
        }
        isConnected = false
        
        // Don't attempt reconnection if we're being cancelled intentionally
        if !Task.isCancelled {
          AppLog.dictation.log("Deepgram: Connection lost, exiting receive loop")
          // Note: In a production environment, you might want to trigger reconnection here
          // For now, we'll just log and break to avoid infinite reconnection loops during shutdown
        }
        break
      }
    }
    
    AppLog.dictation.log("Deepgram: Message receive loop ended")
  }
  
  private func keepAliveLoop(task: URLSessionWebSocketTask) async {
    AppLog.dictation.log("Deepgram: Starting keep-alive loop")
    
    // Wait for connection to be established first
    while !isConnected && !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    while !Task.isCancelled && ws === task {
      // Wait 15 seconds between keep-alive messages (longer interval)
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      
      // Check if we're still connected and using the same task
      guard !Task.isCancelled, let currentTask = ws, currentTask === task, isConnected else {
        AppLog.dictation.log("Deepgram: Keep-alive stopping - connection changed or disconnected")
        break
      }
      
      let keepAliveMessage = ["type": "KeepAlive"]
      do {
        if let jsonData = try? JSONSerialization.data(withJSONObject: keepAliveMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
          try await task.send(.string(jsonString))
          AppLog.dictation.log("Deepgram: Sent keep-alive message")
        }
      } catch {
        AppLog.dictation.error("Deepgram: Failed to send keep-alive: \(error.localizedDescription)")
        break
      }
    }
    
    AppLog.dictation.log("Deepgram: Keep-alive loop ended")
  }
  
  // Connection health check
  func isConnectionHealthy() -> Bool {
    return ws != nil && isConnected
  }
  
  // Abort session immediately without finalizing
  func abort() async {
    await cleanupConnection()
    acc = nil
  }
  
  // Helper to clean up connection state
  private func cleanupConnection() async {
    // Mark as disconnected first to stop new operations
    isConnected = false
    
    // Cancel tasks gracefully
    recvTask?.cancel()
    keepAliveTask?.cancel()
    
    // Give tasks a moment to finish before closing WebSocket
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    
    // Close WebSocket connection
    ws?.cancel(with: .goingAway, reason: Data("Session ended".utf8))
    
    // Clear references
    ws = nil
    recvTask = nil
    keepAliveTask = nil
    
    // Reset connection state
    connectionStartTime = nil
    reconnectAttempts = 0
    
    // Brief delay to allow cleanup to complete
    try? await Task.sleep(nanoseconds: 50_000_000) // Reduced from 100ms to 50ms
  }
  
  // Attempt reconnection if needed (basic implementation)
  private func attemptReconnection() async {
    guard self.reconnectAttempts < self.maxReconnectAttempts else {
      AppLog.dictation.error("Deepgram: Max reconnection attempts (\(self.maxReconnectAttempts)) reached")
      return
    }
    
    self.reconnectAttempts += 1
    let delay = min(pow(2.0, Double(self.reconnectAttempts)), 10.0) // Exponential backoff, max 10s
    AppLog.dictation.log("Deepgram: Attempting reconnection #\(self.reconnectAttempts) in \(delay)s")
    
    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    
    do {
      // Clean up existing connection
      if let task = self.ws {
        self.recvTask?.cancel()
        self.keepAliveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
      }
      
      // Reset state
      self.ws = nil
      self.recvTask = nil
      self.keepAliveTask = nil
      self.isConnected = false
      
      // Attempt new connection
      try await beginRealtime()
      
      if self.isConnected {
        AppLog.dictation.log("Deepgram: Reconnection successful")
        self.reconnectAttempts = 0 // Reset on success
      }
      
    } catch {
      AppLog.dictation.error("Deepgram: Reconnection attempt #\(self.reconnectAttempts) failed: \(error.localizedDescription)")
      
      if self.reconnectAttempts < self.maxReconnectAttempts {
        await attemptReconnection()
      }
    }
  }

  private func streamFileAsPCM16(url: URL, sampleRate: Double) async throws {
    guard let task = ws else { return }
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forReading: url)
    let conv = AVAudioConverter(from: file.processingFormat, to: target)!
    let frames: AVAudioFrameCount = 800 // ~50ms @16k
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames)!
    var eof = false
    while !eof {
      let ib: AVAudioConverterInputBlock = { n, status in
        do {
          let cap = min(2048, Int(n))
          guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(cap)) else { status.pointee = .noDataNow; return nil }
          try file.read(into: buf)
          if buf.frameLength == 0 { status.pointee = .endOfStream; return nil }
          status.pointee = .haveData
          return buf
        } catch { status.pointee = .endOfStream; return nil }
      }
      out.frameLength = frames
      let st = conv.convert(to: out, error: nil, withInputFrom: ib)
      switch st {
      case .haveData:
        if let ch = out.int16ChannelData {
          let p = ch[0]
          let bytes = UnsafeBufferPointer(start: p, count: Int(out.frameLength))
          let data = Data(buffer: bytes)
          try await task.send(.data(data))
          try await Task.sleep(nanoseconds: 30_000_000)
        }
      case .endOfStream: eof = true
      default: eof = true
      }
    }
  }
}

private actor DeepgramAccumulator {
  private(set) var isOpen: Bool = false
  private var segments: [String] = []
  private var lastFinalTime: Date = Date()
  private var currentInterim: String = ""

  func ingest(jsonText: String) {
    guard let data = jsonText.data(using: .utf8) else {
      AppLog.dictation.error("Deepgram: Failed to decode JSON data")
      return
    }
    
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      AppLog.dictation.error("Deepgram: Failed to parse JSON: \(jsonText)")
      return
    }
    
    let messageType = obj["type"] as? String ?? "unknown"
    
    switch messageType {
    case "Metadata":
      isOpen = true
      AppLog.dictation.log("Deepgram: Connection opened with metadata")
      return
      
    case "Results":
      handleResults(obj)
      
    case "UtteranceEnd":
      AppLog.dictation.log("Deepgram: Utterance ended")
      
    case "SpeechStarted":
      AppLog.dictation.log("Deepgram: Speech started")
      
    case "Error":
      if let error = obj["error"] as? String {
        AppLog.dictation.error("Deepgram: Server error - \(error)")
      }
      
    default:
      AppLog.dictation.log("Deepgram: Unknown message type: \(messageType)")
    }
  }
  
  private func handleResults(_ obj: [String: Any]) {
    guard let channel = obj["channel"] as? [String: Any],
          let alternatives = channel["alternatives"] as? [[String: Any]],
          let firstAlt = alternatives.first else {
      AppLog.dictation.error("Deepgram: Invalid results structure")
      return
    }
    
    let transcript = firstAlt["transcript"] as? String ?? ""
    let confidence = firstAlt["confidence"] as? Double ?? 0.0
    let isFinal = obj["is_final"] as? Bool ?? false
    let speechFinal = obj["speech_final"] as? Bool ?? false
    
    // Filter out empty or very low confidence final transcripts to reduce noise
    if isFinal && (transcript.isEmpty || confidence < 0.1) {
      AppLog.dictation.log("Deepgram: Filtered out low-confidence/empty FINAL transcript (conf: \(String(format: "%.2f", confidence)))")
      return
    }
    
    // Log transcript info for debugging
    let type = isFinal ? "FINAL" : "INTERIM"
    if !transcript.isEmpty || isFinal {
      AppLog.dictation.log("Deepgram: \(type) transcript (conf: \(String(format: "%.2f", confidence))): \"\(transcript)\"")
    }
    
    if isFinal && !transcript.isEmpty {
      // This is a final result with meaningful content
      segments.append(transcript)
      lastFinalTime = Date()
      currentInterim = "" // Clear interim since we got final
    } else if !isFinal && !transcript.isEmpty {
      // This is an interim result - store for potential use
      currentInterim = transcript
    }
    
    // Handle speech_final which indicates end of speech segment
    if speechFinal {
      AppLog.dictation.log("Deepgram: Speech segment completed")
    }
  }

  func finalTranscript() -> String {
    let finalText = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    AppLog.dictation.log("Deepgram: Final transcript assembled: \"\(finalText)\"")
    return finalText
  }
  
  func getCurrentTranscript() -> String {
    // Return accumulated final segments plus current interim if available
    let final = segments.joined(separator: " ")
    if !currentInterim.isEmpty && !final.isEmpty {
      return "\(final) \(currentInterim)".trimmingCharacters(in: .whitespacesAndNewlines)
    } else if !currentInterim.isEmpty {
      return currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}


