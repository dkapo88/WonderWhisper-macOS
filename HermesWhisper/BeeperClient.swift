import Foundation

struct BeeperSettings: Equatable {
  var baseURLString: String
  var chatID: String
  var timeout: TimeInterval

  var normalizedBaseURLString: String {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppConfig.defaultBeeperBaseURLString : trimmed
  }

  var normalizedChatID: String {
    chatID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedTimeout: TimeInterval {
    max(5, min(60, timeout))
  }
}

struct BeeperSendResponse: Equatable {
  var chatID: String
  var pendingMessageID: String
}

struct BeeperMessagePage: Equatable {
  var items: [BeeperMessage]
  var newestCursor: String?
}

struct BeeperMessage: Equatable, Identifiable {
  var id: String
  var chatID: String
  var senderID: String?
  var senderName: String?
  var sortKey: String?
  var timestampString: String?
  var text: String?
  var type: String?
  var isSender: Bool?
  var isDeleted: Bool?
  var isHidden: Bool?

  var timestamp: Date? {
    guard let timestampString else { return nil }
    return Self.iso8601WithFractional.date(from: timestampString)
      ?? Self.iso8601.date(from: timestampString)
  }

  var displaySender: String {
    if let senderName = senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !senderName.isEmpty {
      return senderName
    }
    return senderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Beeper"
  }

  var displayText: String {
    BeeperMessageTextFormatter.displayText(from: text)
  }

  var isIncomingText: Bool {
    let messageType = type?.uppercased()
    return isSender != true
      && isDeleted != true
      && isHidden != true
      && !displayText.isEmpty
      && (messageType == nil || messageType == "TEXT" || messageType == "NOTICE")
  }

  private static let iso8601WithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

enum BeeperMessageTextFormatter {
  static func displayText(from rawValue: String?) -> String {
    guard let rawValue else { return "" }
    var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    text = replaceCodeTags(in: text)
    text = text.replacingOccurrences(
      of: #"(?i)<br\s*/?>"#,
      with: "\n",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?i)</p\s*>"#,
      with: "\n\n",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?i)<p\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?i)</div\s*>"#,
      with: "\n",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?i)<div\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?is)<[^>]+>"#,
      with: "",
      options: .regularExpression
    )
    text = decodeHTMLEntities(in: text)
    return normalizeLineBreaks(in: text)
  }

  private static func replaceCodeTags(in value: String) -> String {
    let pattern = #"<code\b[^>]*>(.*?)</code>"#
    guard let regex = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) else {
      return value
    }

    let source = value as NSString
    let matches = regex.matches(
      in: value,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return value }

    var result = ""
    var cursor = 0
    for match in matches {
      let fullRange = match.range
      if fullRange.location > cursor {
        result += source.substring(with: NSRange(
          location: cursor,
          length: fullRange.location - cursor
        ))
      }
      let innerRange = match.range(at: 1)
      if innerRange.location != NSNotFound {
        let inner = source.substring(with: innerRange)
          .replacingOccurrences(of: "`", with: "'")
        result += "`\(inner)`"
      }
      cursor = fullRange.location + fullRange.length
    }
    if cursor < source.length {
      result += source.substring(from: cursor)
    }
    return result
  }

  private static func decodeHTMLEntities(in value: String) -> String {
    var result = value
    let namedEntities = [
      "&nbsp;": " ",
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": "\"",
      "&#39;": "'",
      "&apos;": "'"
    ]
    for (entity, replacement) in namedEntities {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    result = decodeNumericEntities(in: result, pattern: #"&#(\d+);"#, radix: 10)
    result = decodeNumericEntities(in: result, pattern: #"&#x([0-9a-fA-F]+);"#, radix: 16)
    return result
  }

  private static func decodeNumericEntities(in value: String,
                                            pattern: String,
                                            radix: Int) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let source = value as NSString
    let matches = regex.matches(
      in: value,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return value }

    var result = value
    for match in matches.reversed() {
      let entityRange = match.range(at: 0)
      let numberRange = match.range(at: 1)
      guard numberRange.location != NSNotFound else { continue }
      let numberString = source.substring(with: numberRange)
      guard let scalarValue = UInt32(numberString, radix: radix),
            let scalar = UnicodeScalar(scalarValue) else {
        continue
      }
      let replacement = String(Character(scalar))
      if let range = Range(entityRange, in: result) {
        result.replaceSubrange(range, with: replacement)
      }
    }
    return result
  }

  private static func normalizeLineBreaks(in value: String) -> String {
    let lines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    var normalized: [String] = []
    var blankCount = 0
    for line in lines {
      if line.isEmpty {
        blankCount += 1
        if blankCount <= 1 {
          normalized.append("")
        }
      } else {
        blankCount = 0
        normalized.append(line)
      }
    }
    return normalized.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum BeeperClientError: LocalizedError {
  case invalidBaseURL(String)
  case missingAccessToken
  case missingChatID
  case emptyInput
  case invalidResponse
  case serverStatus(Int, String)
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "Beeper API URL is invalid: \(value)"
    case .missingAccessToken:
      return "Beeper access token is not saved."
    case .missingChatID:
      return "Beeper chat ID is not configured."
    case .emptyInput:
      return "No speech was detected for Beeper."
    case .invalidResponse:
      return "Beeper returned an invalid response."
    case .serverStatus(let status, let message):
      return "Beeper returned HTTP \(status): \(message)"
    case .emptyResponse:
      return "Beeper returned an empty send response."
    }
  }
}

final class BeeperAPIClient {
  private let session: URLSession
  private let accessTokenProvider: () -> String?

  init(session: URLSession = .shared, accessTokenProvider: @escaping () -> String?) {
    self.session = session
    self.accessTokenProvider = accessTokenProvider
  }

  func send(text: String,
            replyToMessageID: String? = nil,
            settings: BeeperSettings) async throws -> BeeperSendResponse {
    let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedText.isEmpty else { throw BeeperClientError.emptyInput }
    guard !settings.normalizedChatID.isEmpty else { throw BeeperClientError.missingChatID }

    var request = URLRequest(url: try v1Endpoint(
      pathComponents: ["chats", settings.normalizedChatID, "messages"],
      settings: settings
    ))
    request.httpMethod = "POST"
    request.timeoutInterval = settings.normalizedTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try applyAuthorization(to: &request)
    request.httpBody = try JSONEncoder().encode(
      SendRequest(text: cleanedText, replyToMessageID: replyToMessageID)
    )

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data)
    let decoded = try JSONDecoder().decode(SendResponse.self, from: data)
    let chatID = decoded.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    let pendingMessageID = decoded.pendingMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatID.isEmpty, !pendingMessageID.isEmpty else {
      throw BeeperClientError.emptyResponse
    }
    return BeeperSendResponse(chatID: chatID, pendingMessageID: pendingMessageID)
  }

  func checkConnection(settings: BeeperSettings) async throws {
    var request = URLRequest(url: try v1Endpoint(pathComponents: ["info"], settings: settings))
    request.httpMethod = "GET"
    request.timeoutInterval = min(settings.normalizedTimeout, 10)
    try applyAuthorization(to: &request)

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data)
  }

  func listMessages(settings: BeeperSettings,
                    cursor: String? = nil,
                    direction: MessageListDirection? = nil) async throws -> BeeperMessagePage {
    guard !settings.normalizedChatID.isEmpty else { throw BeeperClientError.missingChatID }

    let endpoint = try v1Endpoint(
      pathComponents: ["chats", settings.normalizedChatID, "messages"],
      settings: settings,
      queryItems: [
        cursor.map { URLQueryItem(name: "cursor", value: $0) },
        direction.map { URLQueryItem(name: "direction", value: $0.rawValue) }
      ].compactMap { $0 }
    )
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = settings.normalizedTimeout
    try applyAuthorization(to: &request)

    let (data, response) = try await session.data(for: request)
    try validateHTTPResponse(response, data: data)
    let decoded = try JSONDecoder().decode(ListMessagesResponse.self, from: data)
    return BeeperMessagePage(
      items: decoded.items.map(\.message),
      newestCursor: decoded.newestCursor
    )
  }

  private func applyAuthorization(to request: inout URLRequest) throws {
    guard let token = accessTokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
      throw BeeperClientError.missingAccessToken
    }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }

  enum MessageListDirection: String {
    case after
    case before
  }

  private func v1Endpoint(pathComponents: [String],
                          settings: BeeperSettings,
                          queryItems: [URLQueryItem] = []) throws -> URL {
    guard var url = URL(string: Self.trimmingTrailingSlashes(settings.normalizedBaseURLString)) else {
      throw BeeperClientError.invalidBaseURL(settings.baseURLString)
    }
    if url.pathComponents.last != "v1" {
      url.appendPathComponent("v1")
    }
    for component in pathComponents {
      url.appendPathComponent(component)
    }
    guard !queryItems.isEmpty else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw BeeperClientError.invalidBaseURL(settings.baseURLString)
    }
    components.queryItems = queryItems
    guard let queriedURL = components.url else {
      throw BeeperClientError.invalidBaseURL(settings.baseURLString)
    }
    return queriedURL
  }

  private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw BeeperClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
        ?? String(data: data, encoding: .utf8)
        ?? "Unknown error"
      throw BeeperClientError.serverStatus(http.statusCode, message)
    }
  }

  private struct SendRequest: Encodable {
    var text: String
    var replyToMessageID: String?  // omitted from JSON when nil
  }

  private struct SendResponse: Decodable {
    var chatID: String
    var pendingMessageID: String
  }

  private struct ListMessagesResponse: Decodable {
    var items: [MessageResponse]
    var newestCursor: String?
  }

  private struct MessageResponse: Decodable {
    var id: String
    var chatID: String
    var senderID: String?
    var senderName: String?
    var sortKey: String?
    var timestamp: String?
    var text: String?
    var type: String?
    var isSender: Bool?
    var isDeleted: Bool?
    var isHidden: Bool?

    var message: BeeperMessage {
      BeeperMessage(
        id: id,
        chatID: chatID,
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

  private struct ErrorResponse: Decodable {
    var error: String
  }

  private static func trimmingTrailingSlashes(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") {
      result.removeLast()
    }
    return result
  }
}
