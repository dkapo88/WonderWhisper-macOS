import Foundation
import OSLog

actor XAIStreamingTranscriptionProvider: TranscriptionProvider {
  private static let defaultEndpointingMs = 800
  private static let maxCreatedWaitMs = 2_500
  private static let maxFinalizeWaitMs = 10_000
  private static let previewUpdateInterval: TimeInterval = 0.05
  private static let maxPendingAudioBytes = 2_000_000

  private let apiKeyProvider: () -> String?
  private let fallbackProvider: XAITranscriptionProvider
  private nonisolated let audioChunkSource = XAIStreamingAudioChunkSource()

  private var webSocketTask: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var activeSessionID: UUID?
  private var isStreaming = false
  private var isServerDone = false
  private var isCreated = false
  private var finalTranscript = ""
  private var lockedUtteranceBuffer = ""
  private var committedSegments: [String] = []
  private var previewTranscript = ""
  private var lastPreviewUpdateTime: Date = .distantPast
  private var totalBytesSent = 0
  private var firstAudioSent = false
  private var pendingAudioBuffer: [Data] = []
  private var pendingAudioBytes = 0
  private var receiveTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var onPreviewUpdate: ((String) -> Void)?

  init(apiKeyProvider: @escaping () -> String?) {
    self.apiKeyProvider = apiKeyProvider
    self.fallbackProvider = XAITranscriptionProvider(client: XAIHTTPClient(apiKeyProvider: apiKeyProvider))
  }

  nonisolated func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    try await fallbackProvider.transcribe(fileURL: fileURL, settings: settings)
  }

  func setOnPreviewUpdate(_ callback: @escaping (String) -> Void) {
    onPreviewUpdate = callback
  }

  func beginRealtime(settings: TranscriptionSettings) async throws {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw ProviderError.missingAPIKey
    }

    if isStreaming {
      await abort()
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    guard let url = Self.websocketURL(for: settings) else {
      throw ProviderError.invalidURL
    }

    AppLog.dictation.log(
      "xAIStreaming: Connecting language=\(Self.language(for: settings) ?? "auto", privacy: .public) keyterms=\(settings.vocabularyTerms.count, privacy: .public)"
    )

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = max(30, settings.timeout)
    config.timeoutIntervalForResource = max(30, settings.timeout + 30)
    let session = URLSession(configuration: config)

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let task = session.webSocketTask(with: request)
    let sessionID = UUID()
    urlSession = session
    webSocketTask = task
    activeSessionID = sessionID
    isStreaming = true
    isServerDone = false
    isCreated = false
    finalTranscript = ""
    lockedUtteranceBuffer = ""
    committedSegments.removeAll(keepingCapacity: true)
    previewTranscript = ""
    lastPreviewUpdateTime = .distantPast
    totalBytesSent = 0
    firstAudioSent = false
    pendingAudioBuffer.removeAll(keepingCapacity: true)
    pendingAudioBytes = 0
    onPreviewUpdate?("")

    task.resume()
    let chunkStream = audioChunkSource.startSession()
    sendTask = Task { [weak self] in
      guard let self else { return }
      for await chunk in chunkStream {
        await self.sendQueuedPCM16(chunk)
      }
    }
    receiveTask = Task { [weak self] in
      guard let self else { return }
      await self.receiveMessages(from: task, sessionID: sessionID)
    }
  }

  nonisolated func enqueuePCM16(_ data: Data) {
    audioChunkSource.send(data)
  }

  func feedPCM16(_ data: Data) async throws {
    await sendQueuedPCM16(data)
  }

  func endRealtime() async throws -> String {
    guard isStreaming else { return "" }

    audioChunkSource.finish()
    await sendTask?.value
    sendTask = nil

    if !isCreated && pendingAudioBytes > 0 {
      await waitForTranscriptCreated()
    }

    if let task = webSocketTask, let sessionID = activeSessionID, isCreated {
      await flushPendingAudio(to: task, sessionID: sessionID)
    }

    AppLog.dictation.log("xAIStreaming: Ending stream bytes=\(self.totalBytesSent, privacy: .public)")

    if let task = webSocketTask {
      let payload = ["type": "audio.done"]
      let data = try JSONSerialization.data(withJSONObject: payload)
      if let jsonString = String(data: data, encoding: .utf8) {
        try await task.send(.string(jsonString))
      }
    }

    let start = Date()
    while isStreaming && !isServerDone {
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      if elapsedMs >= Self.maxFinalizeWaitMs {
        AppLog.dictation.log("xAIStreaming: Timeout waiting for transcript.done after \(elapsedMs, privacy: .public)ms")
        break
      }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }

    let result = currentTranscript()
    cleanup()
    AppLog.dictation.log("xAIStreaming: Session ended transcriptLength=\(result.count, privacy: .public)")
    return result
  }

  func abort() async {
    cleanup()
  }

  private func sendQueuedPCM16(_ data: Data) async {
    guard isStreaming, !data.isEmpty else { return }
    guard let task = webSocketTask else { return }

    guard isCreated else {
      bufferPendingAudio(data)
      return
    }

    do {
      try await task.send(.data(data))
      totalBytesSent += data.count
      if !firstAudioSent {
        firstAudioSent = true
        AppLog.dictation.log("xAIStreaming: First audio chunk sent (\(data.count, privacy: .public) bytes)")
      }
    } catch {
      AppLog.dictation.error("xAIStreaming: Failed to send audio: \(error.localizedDescription, privacy: .public)")
      isServerDone = true
    }
  }

  private func receiveMessages(from task: URLSessionWebSocketTask, sessionID: UUID) async {
    while isActiveSession(sessionID, task: task) {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          await handleTextMessage(text, sessionID: sessionID, task: task)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            await handleTextMessage(text, sessionID: sessionID, task: task)
          }
        @unknown default:
          break
        }
      } catch {
        if isActiveSession(sessionID, task: task) {
          AppLog.dictation.error("xAIStreaming: Receive error: \(error.localizedDescription, privacy: .public)")
        }
        break
      }
    }
  }

  private func handleTextMessage(_ text: String,
                                 sessionID: UUID,
                                 task: URLSessionWebSocketTask) async {
    guard isActiveSession(sessionID, task: task) else { return }
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
      return
    }

    switch type {
    case "transcript.created":
      isCreated = true
      AppLog.dictation.log("xAIStreaming: Received transcript.created")
      await flushPendingAudio(to: task, sessionID: sessionID)

    case "transcript.partial":
      guard let text = json["text"] as? String else { return }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }

      let isFinal = json["is_final"] as? Bool ?? false
      let speechFinal = json["speech_final"] as? Bool ?? false

      if speechFinal {
        appendCommittedSegment(trimmed)
        lockedUtteranceBuffer = ""
        previewTranscript = committedSegments.joined(separator: " ")
        finalTranscript = previewTranscript
      } else if isFinal {
        lockedUtteranceBuffer = Self.joinSegments(lockedUtteranceBuffer, trimmed)
        previewTranscript = Self.joinSegments(committedSegments.joined(separator: " "), lockedUtteranceBuffer)
      } else {
        let currentUtterance = Self.joinSegments(lockedUtteranceBuffer, trimmed)
        previewTranscript = Self.joinSegments(committedSegments.joined(separator: " "), currentUtterance)
      }

      let now = Date()
      if now.timeIntervalSince(lastPreviewUpdateTime) >= Self.previewUpdateInterval {
        lastPreviewUpdateTime = now
        onPreviewUpdate?(currentTranscript())
      }

    case "transcript.done":
      let text = (json["text"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !text.isEmpty {
        appendCommittedSegment(text)
        finalTranscript = committedSegments.joined(separator: " ")
      } else if finalTranscript.isEmpty {
        finalTranscript = currentTranscript()
      }
      lockedUtteranceBuffer = ""
      previewTranscript = ""
      isServerDone = true
      onPreviewUpdate?(currentTranscript())
      AppLog.dictation.log("xAIStreaming: Received transcript.done")

    case "error":
      let message = Self.errorMessage(from: json)
      AppLog.dictation.error("xAIStreaming: Server error: \(message, privacy: .public)")
      onPreviewUpdate?("[Error: \(message)]")
      isServerDone = true

    default:
      break
    }
  }

  private func currentTranscript() -> String {
    if !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !previewTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return previewTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let committed = committedSegments.joined(separator: " ")
    if !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return committed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lockedUtteranceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isActiveSession(_ sessionID: UUID, task: URLSessionWebSocketTask) -> Bool {
    isStreaming && activeSessionID == sessionID && webSocketTask === task
  }

  private func cleanup() {
    isStreaming = false
    activeSessionID = nil
    audioChunkSource.finish()
    sendTask?.cancel()
    sendTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    isCreated = false
    isServerDone = false
    totalBytesSent = 0
    firstAudioSent = false
    pendingAudioBuffer.removeAll(keepingCapacity: false)
    pendingAudioBytes = 0
    finalTranscript = ""
    lockedUtteranceBuffer = ""
    committedSegments.removeAll(keepingCapacity: false)
    previewTranscript = ""
    onPreviewUpdate?("")
  }

  private func bufferPendingAudio(_ data: Data) {
    guard pendingAudioBytes < Self.maxPendingAudioBytes else {
      AppLog.dictation.error("xAIStreaming: Pending audio buffer full before transcript.created")
      return
    }

    pendingAudioBuffer.append(data)
    pendingAudioBytes += data.count
    if pendingAudioBuffer.count == 1 {
      AppLog.dictation.log("xAIStreaming: Buffering audio until transcript.created")
    }
  }

  private func flushPendingAudio(to task: URLSessionWebSocketTask, sessionID: UUID) async {
    guard !pendingAudioBuffer.isEmpty else { return }
    let chunks = pendingAudioBuffer
    pendingAudioBuffer.removeAll(keepingCapacity: true)
    pendingAudioBytes = 0

    AppLog.dictation.log("xAIStreaming: Flushing \(chunks.count, privacy: .public) buffered audio chunks")
    for chunk in chunks {
      guard isActiveSession(sessionID, task: task) else { return }
      do {
        try await task.send(.data(chunk))
        totalBytesSent += chunk.count
        if !firstAudioSent {
          firstAudioSent = true
          AppLog.dictation.log("xAIStreaming: First audio chunk sent (\(chunk.count, privacy: .public) bytes)")
        }
      } catch {
        AppLog.dictation.error("xAIStreaming: Failed to flush buffered audio: \(error.localizedDescription, privacy: .public)")
        return
      }
    }
  }

  private func waitForTranscriptCreated() async {
    let start = Date()
    while isStreaming && !isCreated {
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      if elapsedMs >= Self.maxCreatedWaitMs {
        AppLog.dictation.log("xAIStreaming: Timeout waiting for transcript.created after \(elapsedMs, privacy: .public)ms")
        return
      }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  private static func joinSegments(_ first: String, _ second: String) -> String {
    let lhs = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhs = second.trimmingCharacters(in: .whitespacesAndNewlines)
    if lhs.isEmpty { return rhs }
    if rhs.isEmpty { return lhs }
    if rhs.hasPrefix(lhs) { return rhs }
    if lhs.hasSuffix(rhs) { return lhs }
    return "\(lhs) \(rhs)"
  }

  private func appendCommittedSegment(_ segment: String) {
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let current = committedSegments.joined(separator: " ")
    if current == trimmed || current.hasSuffix(trimmed) {
      return
    }
    if trimmed.hasPrefix(current), !current.isEmpty {
      committedSegments = [trimmed]
      return
    }
    committedSegments.append(trimmed)
  }

  private static func websocketURL(for settings: TranscriptionSettings) -> URL? {
    var components = URLComponents(string: "wss://api.x.ai/v1/stt")
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "sample_rate", value: "16000"),
      URLQueryItem(name: "encoding", value: "pcm"),
      URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "endpointing", value: String(defaultEndpointingMs)),
      URLQueryItem(name: "filler_words", value: "false")
    ]

    if let language = language(for: settings) {
      queryItems.append(URLQueryItem(name: "language", value: language))
    }

    for term in settings.vocabularyTerms.prefix(VoiceVocabularyKeyterms.maxTerms) {
      queryItems.append(URLQueryItem(name: "keyterm", value: term))
    }

    components?.queryItems = queryItems
    return components?.url
  }

  private static func language(for settings: TranscriptionSettings) -> String? {
    let candidate = settings.language ?? UserDefaults.standard.string(forKey: "transcription.language")
    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty || trimmed.lowercased() == "auto" {
      return nil
    }
    return trimmed
  }

  private static func errorMessage(from json: [String: Any]) -> String {
    if let message = json["message"] as? String {
      return message
    }
    if let error = json["error"] as? String {
      return error
    }
    if let error = json["error"] as? [String: Any],
       let message = error["message"] as? String {
      return message
    }
    return "xAI streaming error"
  }
}

private final class XAIStreamingAudioChunkSource: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<Data>.Continuation?

  func startSession() -> AsyncStream<Data> {
    lock.lock()
    continuation?.finish()
    continuation = nil
    lock.unlock()

    return AsyncStream(bufferingPolicy: .unbounded) { [weak self] continuation in
      self?.lock.lock()
      self?.continuation = continuation
      self?.lock.unlock()
    }
  }

  func send(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    let continuation = continuation
    lock.unlock()
    continuation?.yield(data)
  }

  func finish() {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.finish()
  }
}
