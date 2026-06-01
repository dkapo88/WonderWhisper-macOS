import Foundation

enum BeeperWebSocketError: LocalizedError {
  case invalidBaseURL(String)
  case missingAccessToken
  case missingChatID
  case timedOut
  case serverError(String)
  case unsupportedMessage

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "Beeper WebSocket URL is invalid: \(value)"
    case .missingAccessToken:
      return "Beeper access token is not saved."
    case .missingChatID:
      return "Beeper chat ID is not configured."
    case .timedOut:
      return "Beeper WebSocket did not receive a response in time."
    case .serverError(let message):
      return "Beeper WebSocket error: \(message)"
    case .unsupportedMessage:
      return "Beeper WebSocket returned an unsupported message."
    }
  }
}

final class BeeperWebSocketClient {
  private let session: URLSession
  private let accessTokenProvider: () -> String?

  init(session: URLSession = .shared, accessTokenProvider: @escaping () -> String?) {
    self.session = session
    self.accessTokenProvider = accessTokenProvider
  }

  func waitForIncomingMessage(settings: BeeperSettings,
                              sentPendingMessageID: String,
                              sentAt: Date,
                              timeout: TimeInterval) async throws -> BeeperMessage {
    guard !settings.normalizedChatID.isEmpty else { throw BeeperWebSocketError.missingChatID }
    guard let token = accessTokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
      throw BeeperWebSocketError.missingAccessToken
    }

    var request = URLRequest(url: try webSocketEndpoint(settings: settings))
    request.timeoutInterval = min(settings.normalizedTimeout, 10)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let task = session.webSocketTask(with: request)
    task.resume()
    defer { task.cancel(with: .normalClosure, reason: nil) }

    try await sendSubscription(task: task, chatID: settings.normalizedChatID)
    return try await receiveFirstIncomingMessage(
      task: task,
      chatID: settings.normalizedChatID,
      sentPendingMessageID: sentPendingMessageID,
      sentAt: sentAt,
      timeout: timeout
    )
  }

  private func sendSubscription(task: URLSessionWebSocketTask, chatID: String) async throws {
    let request = SubscriptionRequest(
      requestID: "hermeswhisper-beeper-\(UUID().uuidString)",
      chatIDs: [chatID]
    )
    let data = try JSONEncoder().encode(request)
    let payload = String(decoding: data, as: UTF8.self)
    try await task.send(.string(payload))
  }

  private func receiveFirstIncomingMessage(task: URLSessionWebSocketTask,
                                           chatID: String,
                                           sentPendingMessageID: String,
                                           sentAt: Date,
                                           timeout: TimeInterval) async throws -> BeeperMessage {
    let deadline = Date().addingTimeInterval(timeout)
    var seenMessageIDs: Set<String> = [sentPendingMessageID]

    while Date() < deadline {
      let remaining = max(0.5, deadline.timeIntervalSinceNow)
      let socketMessage = try await receive(task: task, timeout: remaining)
      let event = try decodeEvent(socketMessage)

      if event.type == "error" {
        throw BeeperWebSocketError.serverError(event.message ?? event.code ?? "Unknown error")
      }

      guard event.type == "message.upserted",
            event.chatID == chatID,
            let entries = event.entries else {
        continue
      }

      let candidates = entries
        .map { $0.message(eventChatID: event.chatID ?? chatID) }
        .filter { !seenMessageIDs.contains($0.id) }
        .filter { message in
          guard let timestamp = message.timestamp else { return true }
          return timestamp >= sentAt
        }
        .filter(\.isIncomingText)
        .sorted(by: sortMessagesAscending)

      entries.forEach { seenMessageIDs.insert($0.id) }

      if let message = candidates.first {
        return message
      }
    }

    throw BeeperWebSocketError.timedOut
  }

  private func receive(task: URLSessionWebSocketTask,
                       timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
    try await withCheckedThrowingContinuation { continuation in
      let lock = NSLock()
      var didResume = false

      func resume(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
      }

      task.receive { result in
        resume(result)
      }

      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        task.cancel(with: .goingAway, reason: nil)
        resume(.failure(BeeperWebSocketError.timedOut))
      }
    }
  }

  private func decodeEvent(_ message: URLSessionWebSocketTask.Message) throws -> EventMessage {
    switch message {
    case .string(let value):
      return try JSONDecoder().decode(EventMessage.self, from: Data(value.utf8))
    case .data(let data):
      return try JSONDecoder().decode(EventMessage.self, from: data)
    @unknown default:
      throw BeeperWebSocketError.unsupportedMessage
    }
  }

  private func webSocketEndpoint(settings: BeeperSettings) throws -> URL {
    guard var components = URLComponents(string: trimmingTrailingSlashes(settings.normalizedBaseURLString)) else {
      throw BeeperWebSocketError.invalidBaseURL(settings.baseURLString)
    }
    switch components.scheme?.lowercased() {
    case "http":
      components.scheme = "ws"
    case "https":
      components.scheme = "wss"
    case "ws", "wss":
      break
    default:
      throw BeeperWebSocketError.invalidBaseURL(settings.baseURLString)
    }

    var path = components.path
    if path.hasSuffix("/") {
      path.removeLast()
    }
    if !path.hasSuffix("/v1") {
      path += "/v1"
    }
    path += "/ws"
    components.path = path
    components.query = nil

    guard let url = components.url else {
      throw BeeperWebSocketError.invalidBaseURL(settings.baseURLString)
    }
    return url
  }

  private func sortMessagesAscending(_ lhs: BeeperMessage, _ rhs: BeeperMessage) -> Bool {
    if let leftDate = lhs.timestamp, let rightDate = rhs.timestamp, leftDate != rightDate {
      return leftDate < rightDate
    }
    if let leftSort = lhs.sortKey, let rightSort = rhs.sortKey, leftSort != rightSort {
      return leftSort < rightSort
    }
    return lhs.id < rhs.id
  }

  private func trimmingTrailingSlashes(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") {
      result.removeLast()
    }
    return result
  }

  private struct SubscriptionRequest: Encodable {
    var type = "subscriptions.set"
    var requestID: String
    var chatIDs: [String]
  }

  private struct EventMessage: Decodable {
    var type: String
    var chatID: String?
    var code: String?
    var message: String?
    var entries: [MessageEntry]?
  }

  private struct MessageEntry: Decodable {
    var id: String
    var chatID: String?
    var senderID: String?
    var senderName: String?
    var sortKey: String?
    var timestamp: String?
    var text: String?
    var type: String?
    var isSender: Bool?
    var isDeleted: Bool?
    var isHidden: Bool?

    func message(eventChatID: String) -> BeeperMessage {
      BeeperMessage(
        id: id,
        chatID: chatID ?? eventChatID,
        senderID: senderID,
        senderName: senderName,
        sortKey: sortKey,
        timestampString: timestamp,
        text: text,
        type: type,
        isSender: isSender,
        isDeleted: isDeleted,
        isHidden: isHidden
      )
    }
  }
}
