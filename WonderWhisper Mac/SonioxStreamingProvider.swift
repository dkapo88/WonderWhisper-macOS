import Foundation
import AVFoundation
import OSLog

final class SonioxStreamingProvider: TranscriptionProvider {
  private let apiKeyProvider: () -> String?
  private let session: URLSession
  private var liveSession: SonioxLiveSession?
  private let sampleRate: Double = 16_000
  private let channelCount: Int = 1

  init(apiKeyProvider: @escaping () -> String?) {
    self.apiKeyProvider = apiKeyProvider
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 180
    config.waitsForConnectivity = false
    config.httpAdditionalHeaders = [
      "User-Agent": "WonderWhisper-Mac/soniox"
    ]
    self.session = URLSession(configuration: config)
  }

  // MARK: - TranscriptionProvider

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    let languageHints = Self.resolveLanguageHints()
    let endpointDetection = Self.endpointDetectionEnabled()
    let langID = Self.languageIdentificationEnabled()
    let diarization = Self.speakerDiarizationEnabled()
    let live = SonioxLiveSession(
      apiKeyProvider: apiKeyProvider,
      urlSession: session,
      settings: settings,
      languageHints: languageHints,
      enableEndpointDetection: endpointDetection,
      enableLanguageIdentification: langID,
      enableSpeakerDiarization: diarization,
      context: settings.context,
      keepAliveEnabled: Self.keepAliveEnabled()
    )
    try await live.start()
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
    let live = SonioxLiveSession(
      apiKeyProvider: apiKeyProvider,
      urlSession: session,
      settings: settings,
      languageHints: languageHints,
      enableEndpointDetection: endpointDetection,
      enableLanguageIdentification: langID,
      enableSpeakerDiarization: diarization,
      context: settings.context,
      keepAliveEnabled: Self.keepAliveEnabled()
    )
    try await live.start()
    liveSession = live
  }

  func feedPCM16(_ data: Data) async throws {
    guard let liveSession else { return }
    try await liveSession.enqueueAudio(data)
  }

  func endRealtime(trailingSilenceMs: Int? = nil) async throws -> String {
    guard let liveSession else { return "" }
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
    if let custom = defaults.string(forKey: "soniox.languageOverride"), !custom.isEmpty {
      return custom.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    let lang = defaults.string(forKey: "transcription.language") ?? "en"
    return [lang]
  }

  private static func endpointDetectionEnabled() -> Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "soniox.endpointDetection") == nil {
      // Default off to avoid premature cutoffs; match compare implementation defaults
      return false
    }
    return defaults.bool(forKey: "soniox.endpointDetection")
  }

  private static func languageIdentificationEnabled() -> Bool {
    let key = "soniox.languageIdentification.enabled"
    if UserDefaults.standard.object(forKey: key) == nil { return false }
    return UserDefaults.standard.bool(forKey: key)
  }

  private static func speakerDiarizationEnabled() -> Bool {
    let key = "soniox.speakerDiarization.enabled"
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
}

// MARK: - Live session actor

private actor SonioxLiveSession {
  private let apiKeyProvider: () -> String?
  private let urlSession: URLSession
  private let settings: TranscriptionSettings
  private let languageHints: [String]
  private let enableEndpointDetection: Bool
  private let enableLanguageIdentification: Bool
  private let enableSpeakerDiarization: Bool
  private let context: String?
  private let keepAliveEnabled: Bool
  private let logger = AppLog.dictation

  private var webSocket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var accumulator = SonioxTranscriptAccumulator()
  private var bufferedAudio: [Data] = []
  private var bufferedBytes: Int = 0
  private let maxBufferedBytes = 1_024_000
  private var readyForAudio: Bool = false
  private var shuttingDown: Bool = false
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var lastAudioSent: Date = Date()
  private var pendingError: Error?

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
    self.context = context
    self.keepAliveEnabled = keepAliveEnabled
    self.timeoutSeconds = settings.timeout
  }

  func start() async throws {
    guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
      throw ProviderError.missingAPIKey
    }
    let endpoint = settings.endpoint
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 8
    request.setValue("https://wonderwhisper.app", forHTTPHeaderField: "Origin")
    let task = urlSession.webSocketTask(with: request)
    webSocket = task
    logger.log("Soniox: starting realtime session")
    task.resume()

    let handshake = SonioxHandshake(
      apiKey: apiKey,
      model: settings.model,
      audioFormat: "pcm_s16le",
      sampleRate: Int(16_000),
      numChannels: 1,
      languageHints: languageHints.isEmpty ? nil : languageHints,
      context: context,
      enableEndpointDetection: enableEndpointDetection,
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
    do {
      try await task.send(.string(jsonString))
      logger.log("Soniox: handshake sent (model: \(self.settings.model), endpoint detection: \(self.enableEndpointDetection))")
    } catch {
      logger.error("Soniox: handshake send failed \(error.localizedDescription, privacy: .public)")
      throw error
    }
    readyForAudio = true
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
    guard let task = webSocket, readyForAudio else {
      bufferedAudio.append(data)
      bufferedBytes += data.count
      trimBufferIfNeeded()
      if bufferedBytes == data.count {
        logger.log("Soniox: buffering audio while awaiting handshake")
      }
      return
    }
    do {
      try await task.send(.data(data))
      lastAudioSent = Date()
    } catch {
      logger.error("Soniox: failed to send audio chunk (\(data.count) bytes) \(error.localizedDescription, privacy: .public)")
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

  func close() async {
    receiveTask?.cancel()
    keepAliveTask?.cancel()
    webSocket?.cancel(with: .goingAway, reason: nil)
    bufferedAudio.removeAll()
    bufferedBytes = 0
    readyForAudio = false
    shuttingDown = false
    webSocket = nil
    receiveTask = nil
    keepAliveTask = nil
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
    try await task.send(.string(""))
    readyForAudio = false
  }

  private func waitForFinalTranscript(timeout: TimeInterval) async throws -> String {
    if let error = pendingError {
      throw error
    }
    if await accumulator.hasFinished() {
      return await accumulator.finalTranscript()
    }
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await self.awaitFinalTranscript() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw ProviderError.networkError("Soniox realtime session timed out")
      }
      do {
        if let result = try await group.next() {
          group.cancelAll()
          return result
        }
        throw ProviderError.networkError("Soniox realtime session ended unexpectedly")
      } catch {
        group.cancelAll()
        throw error
      }
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
  }

  private func receiveLoop() async {
    guard let task = webSocket else { return }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    while !Task.isCancelled {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          guard let data = text.data(using: .utf8) else { continue }
          let response = try decoder.decode(SonioxResponse.self, from: data)
          if let errorCode = response.errorCode {
            let message = response.errorMessage ?? "unknown"
            logger.error("Soniox: server error code \(errorCode) message \(message, privacy: .public)")
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
        // If server closed after EOS, prefer returning accumulated transcript
        if await accumulator.hasFinished() {
          await completeSession()
          return
        }
        pendingError = error
        if let continuation = finishContinuation {
          finishContinuation = nil
          continuation.resume(throwing: error)
        }
        logger.error("Soniox: receive loop terminating \(error.localizedDescription)")
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
}

// MARK: - Supporting models

private struct SonioxHandshake: Encodable {
  let apiKey: String
  let model: String
  let audioFormat: String
  let sampleRate: Int
  let numChannels: Int
  let languageHints: [String]?
  let context: String?
  let enableEndpointDetection: Bool
  let enableLanguageIdentification: Bool?
  let enableSpeakerDiarization: Bool?
  let clientReferenceId: String
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
}
