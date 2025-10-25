import Foundation
import AVFoundation
import OSLog

final class SonioxStreamingProvider: TranscriptionProvider {
  private let apiKeyProvider: () -> String?
  private let session: URLSession
  private var liveSession: SonioxLiveSession?
  private let sampleRate: Double = 48_000
  private let channelCount: Int = 1
  // Pre-handshake provider-level buffer so we can capture audio immediately
  // even if the WebSocket handshake is still in progress.
  private var prebuffer: [Data] = []
  private var prebufferBytes: Int = 0
  private let maxPrebufferBytes = 1_048_576 // 1 MB safeguard

  init(apiKeyProvider: @escaping () -> String?) {
    self.apiKeyProvider = apiKeyProvider
    let config = NetworkConfiguration.createConfiguration(timeout: 30, maxConnections: 5)
    config.timeoutIntervalForResource = 300 // Increased for longer sessions
    config.waitsForConnectivity = true // Wait for connectivity
    config.httpAdditionalHeaders = config.httpAdditionalHeaders ?? [:]
    config.httpAdditionalHeaders?["User-Agent"] = "WonderWhisper-Mac/soniox"
    self.session = URLSession(configuration: config)
  }

  // MARK: - TranscriptionProvider

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    let languageHints = Self.resolveLanguageHints()
    let endpointDetection = Self.endpointDetectionEnabled()
    let langID = Self.languageIdentificationEnabled()
    let diarization = Self.speakerDiarizationEnabled()
    let contextObject = Self.buildRequestContext(baseContext: settings.context)
    let contextString = contextObject != nil ? (try? String(data: JSONEncoder().encode(contextObject!), encoding: .utf8)) : nil
    let live = SonioxLiveSession(
      apiKeyProvider: apiKeyProvider,
      urlSession: session,
      settings: settings,
      languageHints: languageHints,
      enableEndpointDetection: endpointDetection,
      enableLanguageIdentification: langID,
      enableSpeakerDiarization: diarization,
      context: contextString,
      keepAliveEnabled: Self.keepAliveEnabled()
    )
    try await live.start()
    // Flush any audio captured before handshake (rare for file path flow)
    try await flushPrebufferInto(live)
    try await streamFile(at: fileURL, into: live)
    let timeout = Self.finalizationTimeout(for: settings.timeout)
    let text = try await live.finish(timeout: timeout)
    await live.close()
    return text
  }

  // MARK: - Live streaming interface

  func beginRealtime(settings: TranscriptionSettings) async throws {
    if let existing = liveSession {
      await existing.abort(immediate: true)
      liveSession = nil
    }
    let languageHints = Self.resolveLanguageHints()
    let endpointDetection = Self.endpointDetectionEnabled()
    let langID = Self.languageIdentificationEnabled()
    let diarization = Self.speakerDiarizationEnabled()
    let contextObject = Self.buildRequestContext(baseContext: settings.context)
    let contextString = contextObject != nil ? (try? String(data: JSONEncoder().encode(contextObject!), encoding: .utf8)) : nil
    let live = SonioxLiveSession(
      apiKeyProvider: apiKeyProvider,
      urlSession: session,
      settings: settings,
      languageHints: languageHints,
      enableEndpointDetection: endpointDetection,
      enableLanguageIdentification: langID,
      enableSpeakerDiarization: diarization,
      context: contextString,
      keepAliveEnabled: Self.keepAliveEnabled()
    )
    try await live.start()
    // If any PCM frames were fed before the session was ready, flush them now.
    try await flushPrebufferInto(live)
    liveSession = live
  }

  func feedPCM16(_ data: Data) async throws {
    // If the live session isn't ready yet, buffer at the provider level.
    if let live = liveSession {
      try await live.enqueueAudio(data)
    } else {
      prebuffer.append(data)
      prebufferBytes += data.count
      // Trim prebuffer if it grows too large
      while prebufferBytes > maxPrebufferBytes, !prebuffer.isEmpty {
        let removed = prebuffer.removeFirst()
        prebufferBytes -= removed.count
      }
    }
  }

  func endRealtime(trailingSilenceMs: Int? = nil) async throws -> String {
    guard let liveSession else { return "" }

    // OPTIMIZATION: Don't mark shutting down yet - let tokens finalize first
    // await liveSession.markShuttingDown()  // Moved to after trailing silence

    // Add trailing silence for better finalization accuracy
    // Reduced from 500ms to 100ms for faster response without sacrificing accuracy
    let silenceMs = trailingSilenceMs ?? 200 // Default 200ms of silence to allow finalization
    if silenceMs > 0 {
      try await liveSession.addTrailingSilence(ms: silenceMs)
    }

    // Wait briefly for tokens to finalize (critical for streaming transcript)
    try await Task.sleep(nanoseconds: 100_000_000) // 100ms for token finalization

    // NOW mark shutting down after tokens have arrived
    await liveSession.markShuttingDown()

    let sessionTimeout = await liveSession.currentTimeout()
    let timeout = Self.finalizationTimeout(for: sessionTimeout)
    let text = try await liveSession.finish(timeout: timeout)
    await liveSession.close()
    self.liveSession = nil
    return text
  }

  func abort() async {
    guard let liveSession else { return }
    await liveSession.abort(immediate: true)
    self.liveSession = nil
  }

  // MARK: - Helpers

  private func streamFile(at url: URL, into session: SonioxLiveSession) async throws {
    let target = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channelCount),
      interleaved: true
    )!
    let file = try AVAudioFile(forReading: url)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
      throw ProviderError.networkError("Failed to create audio converter for Soniox stream")
    }
    let framesPerChunk: AVAudioFrameCount = 800 // ~50 ms @16 kHz
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: framesPerChunk) else {
      throw ProviderError.networkError("Failed to allocate PCM buffer for Soniox streaming")
    }
    var reachedEOF = false
    while !reachedEOF {
      outputBuffer.frameLength = framesPerChunk
      let status = converter.convert(to: outputBuffer, error: nil) { _, statusPtr in
        do {
          let capacity = min(4096, Int(framesPerChunk))
          guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(capacity)
          ) else {
            statusPtr.pointee = .noDataNow
            return nil
          }
          try file.read(into: inBuffer)
          if inBuffer.frameLength == 0 {
            statusPtr.pointee = .endOfStream
            return nil
          }
          statusPtr.pointee = .haveData
          return inBuffer
        } catch {
          statusPtr.pointee = .endOfStream
          return nil
        }
      }
      switch status {
      case .haveData:
        if let channel = outputBuffer.int16ChannelData {
          let pointer = channel[0]
          let frameCount = Int(outputBuffer.frameLength)
          let byteCount = frameCount * MemoryLayout<Int16>.size
          let data = Data(bytes: pointer, count: byteCount)
          try await session.enqueueAudio(data)
        }
      case .endOfStream:
        reachedEOF = true
      default:
        reachedEOF = true
      }
    }
  }

  private static func resolveLanguageHints() -> [String] {
    let defaults = UserDefaults.standard
    // First check for enhanced language hints from the new UI
    if let enhancedHints = defaults.string(forKey: "soniox.languageHints"), !enhancedHints.isEmpty {
      return enhancedHints.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    // Fallback to legacy language override
    if let custom = defaults.string(forKey: "soniox.languageOverride"), !custom.isEmpty {
      return custom.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    let lang = defaults.string(forKey: "transcription.language") ?? "en"
    return [lang]
  }

  private static func endpointDetectionEnabled() -> Bool {
    let defaults = UserDefaults.standard
    // Default ON for lower latency finalization per Soniox docs
    if defaults.object(forKey: "soniox.endpointDetection") == nil { return true }
    return defaults.bool(forKey: "soniox.endpointDetection")
  }

  private static func languageIdentificationEnabled() -> Bool {
    let key = "soniox.languageIdentification.enabled"
    if UserDefaults.standard.object(forKey: key) == nil { return false }
    return UserDefaults.standard.bool(forKey: key)
  }

  private static func speakerDiarizationEnabled() -> Bool {
    let key = "soniox.speakerDiarization.enabled"
    // Default to FALSE for faster transcription (single speaker is common)
    if UserDefaults.standard.object(forKey: key) == nil { return false }
    return UserDefaults.standard.bool(forKey: key)
  }

  private static func keepAliveEnabled() -> Bool {
    let key = "soniox.keepalive.enabled"
    if UserDefaults.standard.object(forKey: key) == nil { return false }
    return UserDefaults.standard.bool(forKey: key)
  }

  private static func finalizationTimeout(for configured: TimeInterval) -> TimeInterval {
    let clamped = max(3, min(20, configured))
    return clamped
  }

  // Build Soniox v3 context object from our stored fields.
  private static func buildRequestContext(baseContext: String?) -> SonioxRequestContext? {
    var textParts: [String] = []
    let defaults = UserDefaults.standard

    if let base = baseContext, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      textParts.append(base.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let paragraph = defaults.string(forKey: "soniox.context.paragraph"),
       !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      textParts.append(paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let text = textParts.isEmpty ? nil : textParts.joined(separator: "\n")

    var terms: [String]? = nil
    if let keywords = defaults.string(forKey: "soniox.context.keywords"),
       !keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let split = keywords
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !split.isEmpty { terms = split }
    }

    if text == nil && terms == nil { return nil }
    return SonioxRequestContext(general: nil, text: text, terms: terms, translationTerms: nil)
  }

  private func flushPrebufferInto(_ live: SonioxLiveSession) async throws {
    guard !prebuffer.isEmpty else { return }
    for chunk in prebuffer { try await live.enqueueAudio(chunk) }
    prebuffer.removeAll(keepingCapacity: false)
    prebufferBytes = 0
  }
}

// MARK: - Live session actor (UPDATED WITH IMPROVED SESSION MANAGEMENT)

private actor SonioxLiveSession {
  private let apiKeyProvider: () -> String?
  private let urlSession: URLSession
  private let settings: TranscriptionSettings
  private let languageHints: [String]
  private let enableEndpointDetection: Bool
  private let enableLanguageIdentification: Bool
  private let enableSpeakerDiarization: Bool
  private let context: SonioxRequestContext?
  private let keepAliveEnabled: Bool
  private let logger = AppLog.dictation

  private var webSocket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var accumulator = SonioxTranscriptAccumulator()
  private var bufferedAudio: [Data] = []
  private var bufferedBytes: Int = 0
  private let maxBufferedBytes = 2_048_000 // Increased buffer for better reliability
  private var readyForAudio: Bool = false
  private var shuttingDown: Bool = false
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var lastAudioSent: Date = Date()
  private var pendingError: Error?
  private var retryCount: Int = 0
  private let maxRetries: Int = 3
  private var connectionStartTime: Date = Date()

  // NEW: Enhanced session management
  private var sessionStartTime: Date?
  private var maxSessionDuration: TimeInterval = 120.0 // 2 minutes
  private var sessionTimeoutTimer: Timer?
  private var audioChunksSent: Int = 0
  private var totalAudioBytes: Int = 0

  let timeoutSeconds: TimeInterval

  init(
    apiKeyProvider: @escaping () -> String?,
    urlSession: URLSession,
    settings: TranscriptionSettings,
    languageHints: [String],
    enableEndpointDetection: Bool,
    enableLanguageIdentification: Bool,
    enableSpeakerDiarization: Bool,
    context: String?,
    keepAliveEnabled: Bool
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.urlSession = urlSession
    self.settings = settings
    self.languageHints = languageHints
    self.enableEndpointDetection = enableEndpointDetection
    self.enableLanguageIdentification = enableLanguageIdentification
    self.enableSpeakerDiarization = enableSpeakerDiarization
    self.context = context != nil ? (try? JSONDecoder().decode(SonioxRequestContext.self, from: context!.data(using: .utf8)!)) : nil
    self.keepAliveEnabled = keepAliveEnabled
    self.timeoutSeconds = settings.timeout
  }

  func start() async throws {
    guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw ProviderError.missingAPIKey
    }

    // Validate API key format (Soniox keys are typically 32+ characters)
    if apiKey.count < 20 {
      logger.error("Soniox: API key appears too short (\(apiKey.count) characters)")
      throw ProviderError.missingAPIKey
    }

    let endpoint = settings.endpoint
    logger.log("Soniox: connecting to endpoint: \(endpoint.absoluteString)")

    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 30 // Increased timeout for better reliability
    // Remove custom Origin header that might cause connection issues
    let task = urlSession.webSocketTask(with: request)
    webSocket = task
    logger.log("Soniox: starting realtime session")
    task.resume()

    // Wait for WebSocket connection to be established before sending handshake
    try await waitForWebSocketConnection()

    let handshake = SonioxHandshake(
      apiKey: apiKey,
      model: settings.model,
      audioFormat: "pcm_s16le",
      sampleRate: Int(48_000),
      numChannels: 1,
      languageHints: languageHints.isEmpty ? nil : languageHints,
      context: context,
      // Force endpoint detection ON for low latency and reliable finalization
      enableEndpointDetection: true,
      enableLanguageIdentification: enableLanguageIdentification ? true : nil,
      enableSpeakerDiarization: enableSpeakerDiarization ? true : nil,
      clientReferenceId: UUID().uuidString
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let payload = try encoder.encode(handshake)
    guard let jsonString = String(data: payload, encoding: .utf8) else {
      throw ProviderError.networkError("Failed to encode Soniox handshake")
    }
    // Verify WebSocket is still connected before sending handshake
    guard let webSocket = webSocket, webSocket.state == .running else {
      throw ProviderError.networkError("WebSocket connection not established")
    }

    do {
      // Log the handshake for debugging
      logger.log("Soniox: sending handshake: \(jsonString, privacy: .public)")
      try await webSocket.send(.string(jsonString))
      connectionStartTime = Date()
      retryCount = 0 // Reset retry count on successful handshake
      logger.log("Soniox: handshake sent successfully (model: \(self.settings.model), endpoint detection: \(self.enableEndpointDetection))")

      // Small delay is unnecessary with Soniox; proceed immediately
    } catch {
      logger.error("Soniox: handshake send failed \(error.localizedDescription, privacy: .public)")
      if retryCount < maxRetries && self.shouldRetry(error: error) {
        retryCount += 1
        logger.log("Soniox: retrying handshake (attempt \(self.retryCount)/\(self.maxRetries))")
        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(self.retryCount)) * 1_000_000_000)) // Exponential backoff
        try await self.start()
        return
      }
      throw error
    }

    // NEW: Enhanced session management
    sessionStartTime = Date()
    readyForAudio = true
    startSessionTimeout()

    if !bufferedAudio.isEmpty {
      try await flushBufferedAudio()
    }
    receiveTask = Task { await self.receiveLoop() }
    if keepAliveEnabled {
      keepAliveTask = Task { await self.keepAliveLoop() }
    }
  }

  func enqueueAudio(_ data: Data) async throws {
    guard !data.isEmpty else { return }
    if shuttingDown {
      return
    }

    // Validate WebSocket state before attempting to send
    guard let task = webSocket, task.state == .running, readyForAudio else {
      bufferedAudio.append(data)
      bufferedBytes += data.count
      trimBufferIfNeeded()
      if bufferedBytes == data.count {
        logger.log("Soniox: buffering audio while awaiting handshake (state: \(self.webSocket?.state.rawValue ?? -1))")
      }
      return
    }

    do {
      try await task.send(.data(data))
      lastAudioSent = Date()

      // NEW: Enhanced session tracking
      audioChunksSent += 1
      totalAudioBytes += data.count

    } catch {
      logger.error("Soniox: failed to send audio chunk (\(data.count) bytes) \(error.localizedDescription, privacy: .public)")

      // Check if this is a recoverable error and we should retry
      if retryCount < maxRetries && self.shouldRetry(error: error) {
        logger.log("Soniox: audio send failed, attempting recovery")
        pendingError = error

        // Buffer the audio for retry
        bufferedAudio.append(data)
        bufferedBytes += data.count
        trimBufferIfNeeded()

        return // Don't throw, allow recovery
      }

      pendingError = error
      throw error
    }
  }

  func markShuttingDown() {
    shuttingDown = true
  }

  func currentTimeout() -> TimeInterval {
    timeoutSeconds
  }

  func finish(timeout: TimeInterval) async throws -> String {
    try await flushBufferedAudio()
    try await sendEnd()
    return try await waitForFinalTranscript(timeout: timeout)
  }

  func addTrailingSilence(ms: Int) async throws {
    guard let task = webSocket, readyForAudio else { return }

    // Generate silence PCM data (16-bit signed, 16kHz, mono)
    let silenceDuration = Double(ms) / 1000.0
    let sampleRate = 16000.0
    let frameCount = Int(silenceDuration * sampleRate)
    let silenceData = Data(count: frameCount * 2) // 2 bytes per 16-bit sample

    do {
      try await task.send(.data(silenceData))
      logger.log("Soniox: added \(ms)ms of trailing silence for better finalization")
    } catch {
      logger.error("Soniox: failed to send trailing silence \(error.localizedDescription, privacy: .public)")
    }
  }

  func close() async {
    logger.log("Soniox: closing session")
    receiveTask?.cancel()
    keepAliveTask?.cancel()
    sessionTimeoutTimer?.invalidate()
    sessionTimeoutTimer = nil
    webSocket?.cancel(with: .goingAway, reason: nil)
    bufferedAudio.removeAll(keepingCapacity: false)  // Release capacity to free memory
    bufferedBytes = 0
    readyForAudio = false
    shuttingDown = false
    sessionStartTime = nil
    audioChunksSent = 0
    totalAudioBytes = 0
    webSocket = nil
    receiveTask = nil
    keepAliveTask = nil
    pendingError = nil  // Clear pending error state
    retryCount = 0  // Reset retry count
    logger.log("Soniox: session closed")
  }

  func abort(immediate: Bool) async {
    if immediate {
      pendingError = ProviderError.networkError("Session aborted")
    }
    await close()
  }

  private func flushBufferedAudio() async throws {
    guard readyForAudio, let task = webSocket else { return }
    guard !bufferedAudio.isEmpty else { return }
    for chunk in bufferedAudio {
      try await task.send(.data(chunk))
    }
    logger.log("Soniox: flushed \(self.bufferedAudio.count) buffered chunks after handshake")
    bufferedAudio.removeAll()
    bufferedBytes = 0
  }

  private func sendEnd() async throws {
    guard let task = webSocket else { return }
    // Send empty binary frame to signal end-of-audio (per Soniox docs)
    do {
      try await task.send(.data(Data()))
    } catch {
      // Fallback to empty text frame
      try await task.send(.string(""))
    }
    readyForAudio = false
  }

  private func waitForFinalTranscript(timeout: TimeInterval) async throws -> String {
    // If server already indicated error but we have text, return it
    if let error = pendingError {
      let current = await accumulator.currentText()
      if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return current }
      throw error
    }
    if await accumulator.hasFinished() {
      return await accumulator.finalTranscript()
    }
    do {
      return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await self.awaitFinalTranscript() }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          throw ProviderError.networkError("Soniox realtime session timed out")
        }
        if let result = try await group.next() {
          group.cancelAll()
          return result
        }
        throw ProviderError.networkError("Soniox realtime session ended unexpectedly")
      }
    } catch {
      // On timeout or transport error, return any accumulated text rather than failing hard
      let current = await accumulator.currentText()
      if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return current }
      throw error
    }
  }

  private func awaitFinalTranscript() async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      finishContinuation = cont
    }
  }

  private func trimBufferIfNeeded() {
    guard bufferedBytes > maxBufferedBytes else { return }
    while bufferedBytes > maxBufferedBytes, !bufferedAudio.isEmpty {
      let removed = bufferedAudio.removeFirst()
      bufferedBytes -= removed.count
    }
    // If buffer is still too large after trimming, clear it entirely to prevent crash
    if bufferedBytes > maxBufferedBytes * 2 {
      logger.warning("Soniox: buffer overflow detected, clearing buffer to prevent crash")
      bufferedAudio.removeAll(keepingCapacity: false)
      bufferedBytes = 0
    }
  }

  private func receiveLoop() async {
    guard let task = webSocket else { return }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    logger.log("Soniox: receive loop started")

    while !Task.isCancelled && task.state == .running {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          guard let data = text.data(using: .utf8) else { continue }

          // Log all responses for debugging connection issues
          logger.log("Soniox: received response: \(text, privacy: .public)")

          let response = try decoder.decode(SonioxResponse.self, from: data)
          if let errorCode = response.errorCode {
            let message = response.errorMessage ?? "unknown"
            logger.error("Soniox: server error code \(errorCode) message \(message, privacy: .public)")
          }

          // Log successful responses
          if let tokens = response.tokens, !tokens.isEmpty {
            logger.log("Soniox: received \(tokens.count) tokens, finished: \(response.finished ?? false)")
          }
          if let signal = await accumulator.ingest(response: response) {
            switch signal {
            case .finished:
              await completeSession()
              return
            case .error(let error):
              logger.error("Soniox: ingest error \(error.localizedDescription, privacy: .public)")
              pendingError = error
              finishContinuation?.resume(throwing: error)
              finishContinuation = nil
              await close()
              return
            }
          }
        case .data:
          logger.log("Soniox: received unexpected binary frame")
          continue
        @unknown default:
          continue
        }
      } catch {
        // Check if this is a WebSocket connection error
        let isConnectionError = error.localizedDescription.contains("Socket is not connected") ||
                               error.localizedDescription.contains("connection") ||
                               error.localizedDescription.contains("network")

        // If server closed after EOS, prefer returning accumulated transcript
        if await accumulator.hasFinished() {
          await completeSession()
          return
        }

        // Enhanced error handling with retry logic
        if isConnectionError && retryCount < maxRetries && self.shouldRetry(error: error) {
          retryCount += 1
          logger.log("Soniox: connection error, attempting recovery (attempt \(self.retryCount)/\(self.maxRetries))")

          // Attempt to reconnect
          do {
            try await self.reconnect()
            return
          } catch {
            logger.error("Soniox: reconnection failed \(error.localizedDescription)")
          }
        }

        pendingError = error
        if let continuation = finishContinuation {
          finishContinuation = nil
          continuation.resume(throwing: error)
        }
        logger.error("Soniox: receive loop terminating \(error.localizedDescription, privacy: .public)")
        await close()
        return
      }
    }
  }

  private func completeSession() async {
    let finalText = await accumulator.finalTranscript()
    logger.log("Soniox: session finished with transcript length \(finalText.count)")
    if let continuation = finishContinuation {
      finishContinuation = nil
      continuation.resume(returning: finalText)
    }
    await close()
  }

  private func keepAliveLoop() async {
    // Disabled by default; retained for optional debugging
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard !Task.isCancelled, let task = webSocket, keepAliveEnabled else { break }
      let elapsed = Date().timeIntervalSince(lastAudioSent)
      if elapsed >= 9 {
        do {
          try await task.send(.string("keepalive"))
        } catch {
          // no-op
        }
      }
    }
  }

  // MARK: - Enhanced Error Handling

  func shouldRetry(error: Error) -> Bool {
    // Don't retry if we're shutting down
    if self.shuttingDown { return false }

    // Don't retry authentication errors
    if error.localizedDescription.contains("401") || error.localizedDescription.contains("authentication") {
      return false
    }

    // Retry network-related errors
    if error.localizedDescription.contains("network") ||
       error.localizedDescription.contains("connection") ||
       error.localizedDescription.contains("timeout") {
      return true
    }

    // Retry WebSocket errors
    if let urlError = error as? URLError {
      switch urlError.code {
      case .networkConnectionLost, .notConnectedToInternet, .timedOut:
        return true
      default:
        return false
      }
    }

    return false
  }

  func reconnect() async throws {
    logger.log("Soniox: attempting to reconnect...")

    // Close existing connection
    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    readyForAudio = false

    // Brief delay before reconnection
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

    // Restart the session
    try await start()

    // Flush any buffered audio after reconnection
    if !bufferedAudio.isEmpty {
      try await flushBufferedAudio()
    }

    logger.log("Soniox: reconnection successful")
  }

  // MARK: - Connection Health Monitoring (ENHANCED)

  func getConnectionHealth() -> (isHealthy: Bool, uptime: TimeInterval, bufferedAudioSize: Int, chunksSent: Int, totalBytes: Int) {
    let uptime = connectionStartTime.timeIntervalSinceNow * -1
    let isHealthy = webSocket?.state == .running && !shuttingDown && pendingError == nil
    return (isHealthy, uptime, bufferedBytes, audioChunksSent, totalAudioBytes)
  }

  // NEW: Session timeout management
  private func startSessionTimeout() {
    guard let startTime = sessionStartTime else { return }

    sessionTimeoutTimer?.invalidate()
    sessionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      Task { [weak self] in
        guard let self = self else { return }
        await self.checkSessionTimeout()
      }
    }
  }

  private func checkSessionTimeout() async {
    guard let startTime = sessionStartTime else { return }

    let elapsed = Date().timeIntervalSince(startTime)

    if elapsed > maxSessionDuration {
      logger.warning("⏰ Session timeout reached (\(elapsed.format(fractionDigits: 1))s) - consider restarting")
      // Note: We don't automatically end sessions to allow longer dictations
      // but we log this for monitoring
    }

    // Log session health periodically
    if audioChunksSent > 0 && audioChunksSent % 100 == 0 {
      let health = getConnectionHealth()
      logger.info("📊 Session health: chunks=\(health.chunksSent), bytes=\(health.totalBytes), uptime=\(health.uptime.format(fractionDigits: 1))s")
    }
  }

  // MARK: - Connection Management

  private func waitForWebSocketConnection() async throws {
    guard let webSocket = webSocket else {
      throw ProviderError.networkError("WebSocket not initialized")
    }

    // Wait up to 15 seconds for connection to establish
    let timeout = 15.0
    let startTime = Date()
    var lastState: URLSessionWebSocketTask.State = .suspended

    while Date().timeIntervalSince(startTime) < timeout {
      let currentState = webSocket.state

      // Log state changes for debugging
      if currentState != lastState {
        logger.log("Soniox: WebSocket state changed from \(String(describing: lastState)) to \(String(describing: currentState))")
        lastState = currentState
      }

      switch currentState {
      case .running:
        logger.log("Soniox: WebSocket connection established successfully")
        return
      case .completed:
        throw ProviderError.networkError("WebSocket connection failed immediately")
      case .suspended:
        // Connection not ready yet, continue waiting
        break
      case .canceling:
        throw ProviderError.networkError("WebSocket connection was cancelled")
      @unknown default:
        throw ProviderError.networkError("Unknown WebSocket state: \(String(describing: currentState))")
      }

      try await Task.sleep(nanoseconds: 200_000_000) // 200ms for less frequent polling
    }

    throw ProviderError.networkError("WebSocket connection timeout after \(timeout) seconds")
  }
}

// MARK: - Extensions
extension Double {
  func format(fractionDigits: Int) -> String {
    return String(format: "%.\(fractionDigits)f", self)
  }
}

// MARK: - Supporting models

private struct SonioxHandshake: Encodable {
  let apiKey: String
  let model: String
  let audioFormat: String
  let sampleRate: Int
  let numChannels: Int
  let languageHints: [String]?
  let context: SonioxRequestContext?
  let enableEndpointDetection: Bool
  let enableLanguageIdentification: Bool?
  let enableSpeakerDiarization: Bool?
  let clientReferenceId: String
}

// Minimal Soniox v3 request context we support
private struct SonioxRequestContext: Codable {
  struct KV: Codable { let key: String; let value: String }
  let general: [KV]?
  let text: String?
  let terms: [String]?
  let translationTerms: [KV]?
}

private struct SonioxResponse: Decodable {
  struct Token: Decodable {
    let text: String
    let isFinal: Bool
  }
  let tokens: [Token]?
  let finished: Bool?
  let errorCode: Int?
  let errorMessage: String?
}

private actor SonioxTranscriptAccumulator {
  enum Signal {
    case finished
    case error(Error)
  }

  private var finalTokens: [String] = []
  private var finalTokenCount: Int = 0
  private var interimText: String = ""
  private var finished: Bool = false

  func ingest(response: SonioxResponse) -> Signal? {
    if let code = response.errorCode {
      let message = response.errorMessage ?? "Unknown Soniox error"
      let error = ProviderError.http(status: code, body: message)
      return .error(error)
    }

    if let tokens = response.tokens {
      var finalPrefix = 0
      for token in tokens {
        if token.isFinal {
          finalPrefix += 1
        } else {
          break
        }
      }
      if finalPrefix > finalTokenCount {
        let newTokens = tokens.prefix(finalPrefix).dropFirst(finalTokenCount)
        for token in newTokens {
          guard token.text != "<end>", token.text != "<fin>" else { continue }
          finalTokens.append(token.text)
        }
        finalTokenCount = finalPrefix
      }
      let nonFinal = tokens.dropFirst(finalPrefix).filter { !$0.isFinal }
      interimText = nonFinal.map { $0.text }.joined()
    }

    if response.finished == true {
      finished = true
      return .finished
    }
    return nil
  }

  func hasFinished() -> Bool {
    finished
  }

  func finalTranscript() -> String {
    (finalTokens.joined() + interimText).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func currentText() -> String {
    (finalTokens.joined() + interimText)
  }
}
