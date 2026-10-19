import Foundation
import os

/// A final word from Grok's live transcription. `speaker` is 1-based ("1", "2") so it reads
/// the same as Soniox labels.
struct XAIMeetingWord: Equatable, Sendable {
  let text: String
  let start: TimeInterval
  let end: TimeInterval
  let speaker: String?
}

enum XAIMeetingEvent: Equatable, Sendable {
  case created
  case partial(channel: Int, text: String, words: [XAIMeetingWord], isFinal: Bool)
  case done(channel: Int)
  case error(String)
  case other
}

/// Grok repeats a chunk's final words in the `speech_final` result that closes the utterance.
/// Keeps each word once per channel, in order.
struct XAIMeetingWordDeduplicator: Sendable {
  private var lastStarts: [Int: TimeInterval] = [:]

  mutating func newWords(channel: Int, words: [XAIMeetingWord]) -> [XAIMeetingWord] {
    var lastStart = lastStarts[channel] ?? -.infinity
    let fresh = words.filter { word in
      guard word.start > lastStart + 0.001 else { return false }
      lastStart = word.start
      return true
    }
    lastStarts[channel] = lastStart
    return fresh
  }
}

/// Grok Voice Transcribe 2.0 over one WebSocket for a whole meeting: interleaved two-channel
/// PCM16 in (channel 0 the microphone, channel 1 the call), words with per-channel speaker
/// labels out.
actor XAIMeetingStreamingProvider {
  typealias WordsHandler = @Sendable (_ channel: Int, _ words: [XAIMeetingWord]) async -> Void
  typealias PreviewHandler = @Sendable (_ channel: Int, _ text: String) async -> Void
  typealias ErrorHandler = @Sendable (_ message: String) async -> Void

  static let model = "grok-voice-transcribe-2.0"
  static let channelCount = 2
  private static let endpointingMs = 100
  private static let createdTimeoutSeconds: TimeInterval = 10
  private static let doneTimeoutSeconds: TimeInterval = 20

  private let apiKeyProvider: @Sendable () -> String?
  private let keyterms: [String]
  private let language: String?
  private nonisolated let audioChunks = XAIMeetingAudioChunkSource()

  private var onWords: WordsHandler = { _, _ in }
  private var onPreview: PreviewHandler = { _, _ in }
  private var onStreamError: ErrorHandler = { _ in }
  private var urlSession: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var isCreated = false
  private var isEnding = false
  private var isClosed = false
  private var failure: String?
  private var doneChannels: Set<Int> = []
  private var deduplicator = XAIMeetingWordDeduplicator()
  private var bytesSent = 0

  init(
    apiKeyProvider: @escaping @Sendable () -> String?,
    keyterms: [String],
    language: String?
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.keyterms = keyterms
    self.language = language
  }

  func setHandlers(
    onWords: @escaping WordsHandler,
    onPreview: @escaping PreviewHandler,
    onStreamError: @escaping ErrorHandler
  ) {
    self.onWords = onWords
    self.onPreview = onPreview
    self.onStreamError = onStreamError
  }

  /// Connects and waits for `transcript.created`, so audio sent afterwards is never dropped.
  func beginRealtime() async throws {
    guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty else {
      throw ProviderError.missingAPIKey
    }
    guard let url = Self.websocketURL(keyterms: keyterms, language: language) else {
      throw ProviderError.invalidURL
    }
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: configuration)
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = 16 * 1_024 * 1_024
    urlSession = session
    webSocketTask = task
    task.resume()
    receiveTask = Task { [weak self] in
      await self?.receiveMessages(from: task)
    }

    let deadline = Date().addingTimeInterval(Self.createdTimeoutSeconds)
    while !isCreated, failure == nil, !isClosed, Date() < deadline {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    guard isCreated else {
      let message = failure ?? "Grok did not accept the stream in time."
      cleanup()
      throw ProviderError.networkError(message)
    }

    let chunks = audioChunks.startSession()
    sendTask = Task { [weak self] in
      for await chunk in chunks {
        await self?.send(chunk, over: task)
      }
    }
    AppLog.dictation.log(
      "xAIMeeting: stream accepting audio keyterms=\(self.keyterms.count, privacy: .public)"
    )
  }

  nonisolated func enqueuePCM16(_ data: Data) {
    audioChunks.send(data)
  }

  /// Sends the remaining audio, then waits for both channels' `transcript.done`.
  func endRealtime() async throws {
    guard let task = webSocketTask else { return }
    isEnding = true
    audioChunks.finish()
    await sendTask?.value
    sendTask = nil
    if failure == nil, !isClosed {
      do {
        try await task.send(.string(#"{"type":"audio.done"}"#))
      } catch {
        failure = failure ?? error.localizedDescription
      }
    }
    let deadline = Date().addingTimeInterval(Self.doneTimeoutSeconds)
    while doneChannels.count < Self.channelCount, failure == nil, !isClosed, Date() < deadline {
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
    let complete = doneChannels.count >= Self.channelCount
    let message = failure
    AppLog.dictation.log(
      "xAIMeeting: ended bytes=\(self.bytesSent, privacy: .public) complete=\(complete, privacy: .public)"
    )
    cleanup()
    if let message {
      throw ProviderError.networkError(message)
    }
    if !complete {
      throw ProviderError.networkError("Grok did not finish the transcript in time.")
    }
  }

  func abort() {
    cleanup()
  }

  private func send(_ data: Data, over task: URLSessionWebSocketTask) async {
    guard failure == nil, !isClosed, webSocketTask === task else { return }
    do {
      try await task.send(.data(data))
      bytesSent += data.count
    } catch {
      await fail(error.localizedDescription)
    }
  }

  private func receiveMessages(from task: URLSessionWebSocketTask) async {
    while webSocketTask === task {
      do {
        let message = try await task.receive()
        let text: String? = switch message {
        case .string(let value): value
        case .data(let data): String(data: data, encoding: .utf8)
        @unknown default: nil
        }
        if let text {
          await handle(Self.event(from: text))
        }
      } catch {
        guard webSocketTask === task else { return }
        isClosed = true
        // The server closes the socket after the last `transcript.done`; only a close before
        // then loses words.
        if doneChannels.count < Self.channelCount {
          await fail(isEnding
            ? "Grok closed the stream before finishing the transcript."
            : "Grok stream closed: \(error.localizedDescription)")
        }
        return
      }
    }
  }

  private func handle(_ event: XAIMeetingEvent) async {
    switch event {
    case .created:
      isCreated = true
    case let .partial(channel, text, words, isFinal):
      if isFinal {
        let fresh = deduplicator.newWords(channel: channel, words: words)
        if !fresh.isEmpty {
          await onWords(channel, fresh)
        }
        await onPreview(channel, "")
      } else {
        await onPreview(channel, text)
      }
    case let .done(channel):
      doneChannels.insert(channel)
    case let .error(message):
      await fail(message)
    case .other:
      break
    }
  }

  private func fail(_ message: String) async {
    guard failure == nil else { return }
    failure = message
    AppLog.dictation.error("xAIMeeting: \(message, privacy: .public)")
    await onStreamError(message)
  }

  private func cleanup() {
    audioChunks.finish()
    sendTask?.cancel()
    sendTask = nil
    let task = webSocketTask
    webSocketTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    task?.cancel(with: .normalClosure, reason: nil)
    urlSession?.invalidateAndCancel()
    urlSession = nil
  }

  static func websocketURL(keyterms: [String], language: String?) -> URL? {
    var components = URLComponents(string: "wss://api.x.ai/v1/stt")
    var items = [
      URLQueryItem(name: "model", value: model),
      URLQueryItem(name: "sample_rate", value: String(MeetingStereoAligner.sampleRate)),
      URLQueryItem(name: "encoding", value: "pcm"),
      URLQueryItem(name: "channels", value: String(channelCount)),
      URLQueryItem(name: "multichannel", value: "true"),
      URLQueryItem(name: "diarize", value: "true"),
      URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "endpointing", value: String(endpointingMs)),
    ]
    let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedLanguage.isEmpty, trimmedLanguage.lowercased() != "auto" {
      items.append(URLQueryItem(name: "language", value: trimmedLanguage))
    }
    for term in keyterms.prefix(VoiceVocabularyKeyterms.maxTerms) {
      items.append(URLQueryItem(name: "keyterm", value: term))
    }
    components?.queryItems = items
    return components?.url
  }

  static func event(from text: String) -> XAIMeetingEvent {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return .other }
    let channel = (json["channel_index"] as? NSNumber)?.intValue ?? 0
    switch type {
    case "transcript.created":
      return .created
    case "transcript.partial":
      let words = (json["words"] as? [[String: Any]] ?? []).compactMap(word)
      return .partial(
        channel: channel,
        text: json["text"] as? String ?? "",
        words: words,
        isFinal: json["is_final"] as? Bool ?? false
      )
    case "transcript.done":
      return .done(channel: channel)
    case "error":
      if let message = json["message"] as? String { return .error(message) }
      if let error = json["error"] as? [String: Any],
         let message = error["message"] as? String {
        return .error(message)
      }
      return .error(json["error"] as? String ?? "Grok streaming error")
    default:
      return .other
    }
  }

  private static func word(_ json: [String: Any]) -> XAIMeetingWord? {
    guard let text = json["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let start = (json["start"] as? NSNumber)?.doubleValue else { return nil }
    let end = (json["end"] as? NSNumber)?.doubleValue ?? start
    let speaker: String?
    if let number = json["speaker"] as? NSNumber {
      speaker = String(number.intValue + 1)
    } else if let label = json["speaker"] as? String, !label.isEmpty {
      speaker = Int(label).map { String($0 + 1) } ?? label
    } else {
      speaker = nil
    }
    return XAIMeetingWord(text: text, start: start, end: max(start, end), speaker: speaker)
  }
}

private final class XAIMeetingAudioChunkSource: Sendable {
  private let continuation = OSAllocatedUnfairLock<AsyncStream<Data>.Continuation?>(
    initialState: nil
  )

  func startSession() -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    let previous = self.continuation.withLock { current in
      defer { current = continuation }
      return current
    }
    previous?.finish()
    return stream
  }

  func send(_ data: Data) {
    guard !data.isEmpty else { return }
    let continuation = self.continuation.withLock { $0 }
    continuation?.yield(data)
  }

  func finish() {
    let continuation = self.continuation.withLock { current in
      defer { current = nil }
      return current
    }
    continuation?.finish()
  }
}
