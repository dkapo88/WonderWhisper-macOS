import Foundation
import AVFoundation
import OSLog

/// SonioxStreamingProvider implements real-time streaming transcription via Soniox WebSocket API.
/// Unlike batch providers, this streams audio in real-time and receives preview/final tokens continuously.
///
/// Key behavior:
/// - Connects to wss://stt-rt.soniox.com/transcribe-websocket
/// - Sends PCM16 audio as binary frames
/// - Receives token-by-token results with is_final flag
/// - On stop: returns preview text immediately (no waiting for full finalization)
/// - Supports vocabulary terms via context.terms
/// - Supports language hints for improved accuracy
actor SonioxStreamingProvider: TranscriptionProvider {
  private let apiKeyProvider: () -> String?
  private let vocabularyProvider: () -> String?
  private let languageProvider: () -> String?

  private var webSocketTask: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var sessionDelegate: SonioxSessionDelegate?

  // Streaming state
  private var isStreaming: Bool = false
  private var isConfigSent: Bool = false  // Track if config has been sent (audio must wait)
  private var isServerFinished: Bool = false // Track if server signaled end of stream
  private var pendingAudioBuffer: [Data] = []  // Buffer audio until config is sent
  private let accumulator = SonioxTokenAccumulator()

  // Audio progress tracking for smart end-of-stream waiting
  private var lastTotalAudioProcMs: Int = 0  // Last reported total_audio_proc_ms from server

  // Audio format - dynamically set based on actual input
  private var inputSampleRate: Double = 16_000 // Default to 16k, but will be updated

  // Configuration - use the active V3 model per Soniox documentation
  private var currentModel: String = "stt-rt-v3"

  // Callback for live transcript updates
  private var onPreviewUpdate: ((String) -> Void)?

  // Keepalive timer to prevent WebSocket timeout during silence
  private var keepaliveTask: Task<Void, Never>?

  init(apiKeyProvider: @escaping () -> String?,
       vocabularyProvider: @escaping () -> String? = { nil },
       languageProvider: @escaping () -> String? = { nil }) {
    self.apiKeyProvider = apiKeyProvider
    self.vocabularyProvider = vocabularyProvider
    self.languageProvider = languageProvider
  }

  // MARK: - TranscriptionProvider (file-based fallback)

  nonisolated func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    // For file-based transcription, we don't use streaming - just return empty
    // The streaming interface should be used instead
    throw ProviderError.notImplemented
  }

  // MARK: - Streaming Interface

  func setOnPreviewUpdate(_ callback: @escaping (String) -> Void) {
    self.onPreviewUpdate = callback
  }

  /// Update the model to use for streaming
  func updateSettings(_ settings: TranscriptionSettings) {
    // Soniox uses its own model naming, but we can use this to configure
    AppLog.dictation.log("SonioxStreaming: Settings updated - model: \(settings.model)")
  }

  /// Set the actual input sample rate from the audio recorder
  /// Must be called before beginRealtime() or feedPCM16()
  func setInputSampleRate(_ rate: Double) {
    inputSampleRate = rate
    AppLog.dictation.log("SonioxStreaming: Input sample rate set to \(rate) Hz")
  }

  /// Begin a streaming transcription session
  func beginRealtime() async throws {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw ProviderError.missingAPIKey
    }

    // Clean up any existing session
    if isStreaming {
      AppLog.dictation.log("SonioxStreaming: Cleaning up existing session")
      stopKeepaliveTimer()
      _ = try? await endRealtime()
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    AppLog.dictation.log("SonioxStreaming: Beginning real-time session")

    // Reset state
    await accumulator.reset()
    pendingAudioBuffer.removeAll()
    totalBytesSent = 0
    lastLogTime = Date()
    firstAudioSent = false
    isConfigSent = false
    isServerFinished = false
    lastTotalAudioProcMs = 0
    isStreaming = true

    // Create URLSession with delegate for WebSocket
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 300 // 5 minutes max
    config.timeoutIntervalForResource = 300
    
    let delegate = SonioxSessionDelegate()
    self.sessionDelegate = delegate
    urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

    // Connect to Soniox WebSocket
    guard let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket") else {
      throw ProviderError.invalidURL
    }

    webSocketTask = urlSession?.webSocketTask(with: url)
    // Start connection - messages sent before open are queued by URLSession
    webSocketTask?.resume()

    AppLog.dictation.log("SonioxStreaming: WebSocket task started (optimistic connection)")

    // Start receiving messages immediately (this will handle the open event implicitly via messages)
    Task { [weak self] in
      guard let self = self else { return }
      await self.receiveMessages()
    }

    // Send initial configuration immediately (will be queued if connection is pending)
    // Note: This might throw if connection fails instantly, which is what we want.
    try await sendConfiguration(apiKey: apiKey)

    // Start keepalive timer to prevent timeout during silence (every 15 seconds)
    startKeepaliveTimer()

    AppLog.dictation.log("SonioxStreaming: Session initialized")
  }

  // Track bytes sent for logging
  private var totalBytesSent: Int = 0
  private var lastLogTime: Date = Date()
  private var firstAudioSent: Bool = false

  /// Feed PCM16 audio data to the streaming session
  func feedPCM16(_ data: Data) async throws {
    guard isStreaming else { return }
    guard !data.isEmpty else { return }

    // If config hasn't been sent yet, buffer the audio
    // Soniox requires the text config message BEFORE any binary audio
    if !isConfigSent {
      pendingAudioBuffer.append(data)
      if pendingAudioBuffer.count == 1 {
        AppLog.dictation.log("SonioxStreaming: Buffering audio until config is sent...")
      }
      return
    }

    guard let task = webSocketTask else {
      AppLog.dictation.log("SonioxStreaming: feedPCM16 skipped - no WebSocket task")
      return
    }

    // Send as binary WebSocket frame
    let message = URLSessionWebSocketTask.Message.data(data)
    do {
      try await task.send(message)
      totalBytesSent += data.count

      // Log first audio chunk for debugging
      if !firstAudioSent {
        firstAudioSent = true
        AppLog.dictation.log("SonioxStreaming: First audio chunk sent (\(data.count) bytes)")
      }

      // Log every second to avoid spam
      let now = Date()
      if now.timeIntervalSince(lastLogTime) >= 1.0 {
        let bytesPerSec = inputSampleRate * 2.0 // 16-bit = 2 bytes/sample
        let durationSec = Double(totalBytesSent) / bytesPerSec
        AppLog.dictation.log("SonioxStreaming: Sent \(self.totalBytesSent) bytes total (~\(String(format: "%.1f", durationSec))s of audio)")
        lastLogTime = now
      }
    } catch {
      AppLog.dictation.error("SonioxStreaming: Failed to send audio: \(error.localizedDescription)")
    }
  }

  /// End the streaming session and return the transcript
  /// Waits for preview tokens to finish processing before returning
  func endRealtime() async throws -> String {
    guard isStreaming else {
      AppLog.dictation.log("SonioxStreaming: Not streaming, returning empty")
      return ""
    }

    AppLog.dictation.log("SonioxStreaming: Ending session - waiting for preview tokens to complete")
    stopKeepaliveTimer()

    // Calculate how much audio we sent (in milliseconds)
    let bytesPerMs = inputSampleRate * 2.0 / 1000.0  // 16-bit = 2 bytes/sample
    let audioSentMs = Int(Double(totalBytesSent) / bytesPerMs)
    AppLog.dictation.log("SonioxStreaming: Audio sent: \(audioSentMs)ms, server processed: \(self.lastTotalAudioProcMs)ms")

    // Signal end of audio stream by sending empty frame
    if let task = webSocketTask {
      try? await task.send(.data(Data()))
    }

    // Wait for server to finish processing our audio
    // Keep checking status until total_audio_proc_ms catches up or finished signal received
    let tolerance = 200  // Allow 200ms tolerance for processing lag
    let maxWaitMs = 2000  // Reduced max wait to 2 seconds for better latency
    let startTime = Date()

    while lastTotalAudioProcMs < (audioSentMs - tolerance) && !isServerFinished {
      // Check timeout
      let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
      if elapsed > maxWaitMs {
        AppLog.dictation.log("SonioxStreaming: Timeout waiting for processing (waited \(elapsed)ms)")
        break
      }

      // Check if connection is still valid
      guard webSocketTask != nil, isStreaming else { break }

      // Wait briefly to allow receiveMessages Task to process incoming frames
      // We must yield here to allow the actor to process handleTextMessage calls
      try? await Task.sleep(nanoseconds: 20_000_000) // 20ms poll
    }

    let finalProcMs = lastTotalAudioProcMs
    AppLog.dictation.log("SonioxStreaming: Processing complete - sent: \(audioSentMs)ms, processed: \(finalProcMs)ms")
    
    // Send explicit finalize message just in case
    if !isServerFinished, let task = webSocketTask {
         let finalizeMsg = ["type": "finalize"]
         if let data = try? JSONSerialization.data(withJSONObject: finalizeMsg),
            let str = String(data: data, encoding: .utf8) {
             try? await task.send(.string(str))
         }
    }

    isStreaming = false

    // Close the connection
    if let task = webSocketTask {
      task.cancel(with: .normalClosure, reason: nil)
    }

    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    sessionDelegate = nil

    // Get the accumulated preview text
    let transcript = await accumulator.getPreviewTranscript()
    await accumulator.reset()

    AppLog.dictation.log("SonioxStreaming: Session ended, transcript length: \(transcript.count)")
    return transcript
  }

  /// Abort streaming session immediately without processing
  func abort() async {
    isStreaming = false

    stopKeepaliveTimer()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    sessionDelegate = nil

    await accumulator.reset()
    pendingAudioBuffer.removeAll()
  }

  // MARK: - Keepalive Timer

  private func startKeepaliveTimer() {
    stopKeepaliveTimer()
    keepaliveTask = Task {
      while !Task.isCancelled && isStreaming {
        try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
        guard isStreaming, let task = webSocketTask else { break }

        // Send keepalive message per Soniox docs
        let keepalive = ["type": "keepalive"]
        if let data = try? JSONSerialization.data(withJSONObject: keepalive),
           let jsonString = String(data: data, encoding: .utf8) {
          let message = URLSessionWebSocketTask.Message.string(jsonString)
          try? await task.send(message)
          AppLog.dictation.log("SonioxStreaming: Sent keepalive")
        }
      }
    }
  }

  private func stopKeepaliveTimer() {
    keepaliveTask?.cancel()
    keepaliveTask = nil
  }

  // MARK: - Private Methods

  private func sendConfiguration(apiKey: String) async throws {
    guard let task = webSocketTask else { return }

    // Build configuration per Soniox WebSocket API docs
    var config: [String: Any] = [
      "api_key": apiKey,
      "model": currentModel,
      "audio_format": "pcm_s16le",  // 16-bit signed little-endian PCM
      "sample_rate": Int(inputSampleRate),  // Use actual input sample rate!
      "num_channels": 1  // Mono audio (not num_audio_channels)
    ]

    // Add language hints if available
    if let language = languageProvider(), !language.isEmpty {
      // Soniox expects an array of language codes
      config["language_hints"] = [language]
      // Also enable language identification to be robust
      config["enable_language_identification"] = true
    } else {
      // Default to English
      config["language_hints"] = ["en"]
      // Enable ID to support auto-switching if user speaks something else (model supports it)
      config["enable_language_identification"] = true
    }
    
    // Enable endpoint detection for faster finalization per docs
    config["enable_endpoint_detection"] = true

    // Add vocabulary terms as context
    if let vocab = vocabularyProvider(), !vocab.isEmpty {
      // Parse comma-separated vocabulary into array of terms
      let terms = vocab
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      if !terms.isEmpty {
        config["context"] = ["terms": terms]
      }
    }

    guard let data = try? JSONSerialization.data(withJSONObject: config),
          let jsonString = String(data: data, encoding: .utf8) else {
      throw ProviderError.decodingFailed
    }

    var diagnosticConfig = config
    diagnosticConfig["api_key"] = "<redacted>"
    let diagnosticData = try? JSONSerialization.data(withJSONObject: diagnosticConfig)
    let diagnosticString = diagnosticData.flatMap { String(data: $0, encoding: .utf8) } ?? "<unavailable>"
    AppLog.dictation.log("SonioxStreaming: Sending config: \(diagnosticString, privacy: .public)")
    let message = URLSessionWebSocketTask.Message.string(jsonString)
    try await task.send(message)

    AppLog.dictation.log("SonioxStreaming: Configuration sent successfully")

    // Mark config as sent and flush any buffered audio
    isConfigSent = true
    if !pendingAudioBuffer.isEmpty {
      AppLog.dictation.log("SonioxStreaming: Flushing \(self.pendingAudioBuffer.count) buffered audio chunks")
      for audioData in pendingAudioBuffer {
        let audioMessage = URLSessionWebSocketTask.Message.data(audioData)
        try? await task.send(audioMessage)
        totalBytesSent += audioData.count
      }
      pendingAudioBuffer.removeAll()
    }
  }

  private func receiveMessages() async {
    guard let task = webSocketTask else { return }

    while isStreaming {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          await handleTextMessage(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            await handleTextMessage(text)
          }
        @unknown default:
          break
        }
      } catch {
        if isStreaming {
          AppLog.dictation.error("SonioxStreaming: Receive error: \(error.localizedDescription)")
        }
        break
      }
    }
  }

  private func handleTextMessage(_ text: String) async {
    // Log raw message for debugging (truncate if too long)
    // Use %{public}@ to avoid Apple's privacy redaction in logs
    let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text
    AppLog.dictation.log("SonioxStreaming: Received message: \(truncated, privacy: .public)")

    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      AppLog.dictation.error("SonioxStreaming: Failed to parse JSON")
      return
    }

    // Check for error response and surface to UI
    if let error = json["error"] as? String {
      AppLog.dictation.error("SonioxStreaming: Server error: \(error, privacy: .public)")
      onPreviewUpdate?("[Error: \(error)]")
      return
    }

    // Check for error in different format
    if let errorObj = json["error"] as? [String: Any], let message = errorObj["message"] as? String {
      AppLog.dictation.error("SonioxStreaming: Server error: \(message, privacy: .public)")
      onPreviewUpdate?("[Error: \(message)]")
      return
    }

    // Check for status field indicating error
    if let status = json["status"] as? String, status != "ok" {
      AppLog.dictation.error("SonioxStreaming: Status not ok: \(status, privacy: .public), full response: \(truncated, privacy: .public)")
      onPreviewUpdate?("[Status: \(status)]")
      return
    }

    // Check for error_code/error_message format (Soniox API error response)
    if let errorCode = json["error_code"] as? Int, errorCode != 0 {
      let errorMessage = json["error_message"] as? String ?? "Unknown error"
      AppLog.dictation.error("SonioxStreaming: API error \(errorCode): \(errorMessage, privacy: .public)")
      onPreviewUpdate?("[API Error \(errorCode): \(errorMessage)]")
      return
    }

    // Handle "started" response (config acknowledged)
    if let started = json["started"] as? Bool, started {
      AppLog.dictation.log("SonioxStreaming: Received started acknowledgment")
      return
    }

    // Handle finished response (stream complete)
    if let finished = json["finished"] as? Bool, finished {
      AppLog.dictation.log("SonioxStreaming: Received finished signal")
      isServerFinished = true
      return
    }

    // Parse tokens array
    guard let tokens = json["tokens"] as? [[String: Any]] else {
      // Log unrecognized message types for debugging
      let keys = json.keys.sorted().joined(separator: ", ")
      AppLog.dictation.log("SonioxStreaming: No tokens in message, keys: [\(keys, privacy: .public)]")
      // Show message in preview for debugging if it's an unexpected format
      if !json.keys.isEmpty && json["tokens"] == nil && json["finished"] == nil {
        AppLog.dictation.log("SonioxStreaming: Full response: \(truncated, privacy: .public)")
      }
      return
    }

    // Track audio processing progress for smart end-of-stream detection
    if let totalMs = json["total_audio_proc_ms"] as? Int {
      lastTotalAudioProcMs = totalMs
      if let finalMs = json["final_audio_proc_ms"] as? Int {
        AppLog.dictation.log("SonioxStreaming: Audio progress - final: \(finalMs)ms, total: \(totalMs)ms")
      }
    }

    // Clear non-final tokens before processing - each response gives us a fresh view
    // of the current non-final state (non-final tokens may change between responses)
    await accumulator.clearNonFinal()

    var newTokenCount = 0
    var finalCount = 0
    var nonFinalCount = 0
    for token in tokens {
      guard let tokenText = token["text"] as? String else { continue }
      let isFinal = token["is_final"] as? Bool ?? false
      newTokenCount += 1
      if isFinal { finalCount += 1 } else { nonFinalCount += 1 }

      await accumulator.addToken(text: tokenText, isFinal: isFinal)
    }

    if newTokenCount > 0 {
      AppLog.dictation.log("SonioxStreaming: Processed \(newTokenCount) tokens (final: \(finalCount), non-final: \(nonFinalCount))")
    }

    // Notify about preview updates
    let preview = await accumulator.getPreviewTranscript()
    if !preview.isEmpty {
      AppLog.dictation.log("SonioxStreaming: Current transcript (\(preview.count) chars): \"\(preview.prefix(100), privacy: .public)\"...")
    }
    onPreviewUpdate?(preview)
  }
}

// MARK: - Token Accumulator

private actor SonioxTokenAccumulator {
  // Soniox sends tokens incrementally:
  // - Non-final tokens (is_final: false) are provisional and may change
  // - Final tokens (is_final: true) are confirmed and won't change
  // 
  // Per the docs, non-final tokens may appear multiple times and change
  // until they stabilize. Final tokens are sent only once.
  //
  // We track: finalizedText (confirmed) + currentNonFinal (preview that may change)
  private var finalizedText: String = ""
  private var currentNonFinal: String = ""

  func addToken(text: String, isFinal: Bool) {
    // Skip the <fin> marker token or any xml tags that might appear due to hallucinations
    if text == "<fin>" || text.contains("<") || text.contains(">") { return }
    
    if isFinal {
      // Final token - append to finalized text
      // Final tokens are confirmed and sent only once
      finalizedText += text
    } else {
      // Non-final token - this is a provisional preview
      // Non-final tokens in each response represent the COMPLETE current preview
      // (we call clearNonFinal() before processing each response)
      currentNonFinal += text
    }
  }
  
  /// Clear non-final tokens when we receive a new batch
  /// Call this at the start of processing each response message
  func clearNonFinal() {
    currentNonFinal = ""
  }

  /// Get the current transcript (finalized + current preview)
  func getPreviewTranscript() -> String {
    return (finalizedText + currentNonFinal).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Get only finalized text
  func getFinalizedTranscript() -> String {
    return finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func reset() {
    finalizedText = ""
    currentNonFinal = ""
  }
}

// MARK: - URLSession Delegate

private class SonioxSessionDelegate: NSObject, URLSessionWebSocketDelegate {
  // Simplified delegate - no manual continuation needed as we use optimistic connection
  
  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    AppLog.dictation.log("SonioxStreaming: WebSocket opened")
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
    AppLog.dictation.log("SonioxStreaming: WebSocket closed - code: \(closeCode.rawValue), reason: \(reasonStr)")
  }
  
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      AppLog.dictation.error("SonioxStreaming: Connection error: \(error.localizedDescription)")
    }
  }
}
