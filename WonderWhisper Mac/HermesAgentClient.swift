import Foundation
import Network

struct HermesAgentSettings: Equatable {
  var baseURLString: String
  var model: String
  var conversationName: String
  var timeout: TimeInterval

  var normalizedBaseURLString: String {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppConfig.defaultHermesBaseURLString : trimmed
  }

  var normalizedModel: String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppConfig.defaultHermesModel : trimmed
  }

  var normalizedConversationName: String {
    let trimmed = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppConfig.defaultHermesConversationName : trimmed
  }
}

struct HermesAgentResponse: Equatable {
  var id: String
  var text: String
  var model: String
  var sessionID: String?
}

struct HermesAgentImageAttachment: Equatable {
  var data: Data
  var mimeType: String
  var width: Int
  var height: Int
  var method: ScreenCaptureSnapshot.Method
  var suggestedFilename: String

  init(data: Data,
       mimeType: String,
       width: Int,
       height: Int,
       method: ScreenCaptureSnapshot.Method,
       suggestedFilename: String) {
    self.data = data
    self.mimeType = mimeType
    self.width = width
    self.height = height
    self.method = method
    self.suggestedFilename = suggestedFilename
  }

  init(snapshot: ScreenCaptureSnapshot) {
    self.init(
      data: snapshot.data,
      mimeType: snapshot.mimeType,
      width: snapshot.width,
      height: snapshot.height,
      method: snapshot.method,
      suggestedFilename: snapshot.suggestedFilename
    )
  }

  var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }
}

enum HermesAgentClientError: LocalizedError {
  case invalidBaseURL(String)
  case missingAPIKey
  case emptyInput
  case invalidResponse
  case serverStatus(Int, String)
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "Hermes base URL is invalid: \(value)"
    case .missingAPIKey:
      return "Hermes API server key is not saved."
    case .emptyInput:
      return "No speech was detected for Hermes."
    case .invalidResponse:
      return "Hermes returned an invalid response."
    case .serverStatus(let status, let message):
      return "Hermes returned HTTP \(status): \(message)"
    case .emptyResponse:
      return "Hermes returned an empty response."
    }
  }
}

final class HermesAgentAPIClient {
  private let session: URLSession
  private let apiKeyProvider: () -> String?

  init(session: URLSession = .shared, apiKeyProvider: @escaping () -> String?) {
    self.session = session
    self.apiKeyProvider = apiKeyProvider
  }

  func send(input: String,
            settings: HermesAgentSettings,
            imageAttachment: HermesAgentImageAttachment? = nil,
            clipboardText: String? = nil) async throws -> HermesAgentResponse {
    let cleanedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedInput.isEmpty else { throw HermesAgentClientError.emptyInput }
    let url = try v1Endpoint(path: "responses", settings: settings)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = settings.timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuthorization(to: &request)
    request.httpBody = try Self.requestBodyData(
      input: cleanedInput,
      settings: settings,
      imageAttachment: imageAttachment,
      clipboardText: clipboardText
    )

    let response = try await perform(request)
    try validateHTTPResponse(response)

    let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: response.data)
    let text = envelope.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw HermesAgentClientError.emptyResponse }

    let sessionID = response.headers["x-hermes-session-id"]
    return HermesAgentResponse(
      id: envelope.id,
      text: text,
      model: envelope.model,
      sessionID: sessionID
    )
  }

  func checkHealth(settings: HermesAgentSettings) async throws {
    guard hasAPIKey else { throw HermesAgentClientError.missingAPIKey }

    let url = try healthEndpoint(settings: settings)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = min(settings.timeout, 10)
    applyAuthorization(to: &request)

    let response = try await perform(request)
    try validateHTTPResponse(response)

    var authProbe = URLRequest(url: try v1Endpoint(path: "models", settings: settings))
    authProbe.httpMethod = "GET"
    authProbe.timeoutInterval = min(settings.timeout, 10)
    applyAuthorization(to: &authProbe)

    let probeResponse = try await perform(authProbe)
    try validateHTTPResponse(probeResponse)
  }

  private var hasAPIKey: Bool {
    guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    return !key.isEmpty
  }

  private func healthEndpoint(settings: HermesAgentSettings) throws -> URL {
    let url = try baseURL(settings: settings)
    if url.pathComponents.last == "v1" {
      return url.deletingLastPathComponent().appendingPathComponent("health")
    }
    return url.appendingPathComponent("health")
  }

  private func v1Endpoint(path: String, settings: HermesAgentSettings) throws -> URL {
    try Self.endpointURL(path: path, baseURLString: settings.normalizedBaseURLString)
  }

  private func baseURL(settings: HermesAgentSettings) throws -> URL {
    let base = settings.normalizedBaseURLString.trimmingTrailingSlashes()
    guard let url = URL(string: base) else {
      throw HermesAgentClientError.invalidBaseURL(settings.baseURLString)
    }
    return url
  }

  private func applyAuthorization(to request: inout URLRequest) {
    guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else { return }
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
  }

  private func perform(_ request: URLRequest) async throws -> HermesHTTPResponse {
    guard request.url?.scheme?.lowercased() == "http" else {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw HermesAgentClientError.invalidResponse
      }
      return HermesHTTPResponse(
        statusCode: http.statusCode,
        headers: http.allHeaderFields.reduce(into: [:]) { result, item in
          if let key = item.key as? String, let value = item.value as? String {
            result[key.lowercased()] = value
          }
        },
        data: data
      )
    }

    return try await HermesPlainHTTPTransport.perform(request)
  }

  private func validateHTTPResponse(_ response: HermesHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.data)
      let message = payload?.error.message
        ?? String(data: response.data, encoding: .utf8)
        ?? "Unknown error"
      throw HermesAgentClientError.serverStatus(response.statusCode, message)
    }
  }
}

private struct HermesHTTPResponse {
  let statusCode: Int
  let headers: [String: String]
  let data: Data
}

private enum HermesPlainHTTPTransport {
  static func perform(_ request: URLRequest) async throws -> HermesHTTPResponse {
    guard let url = request.url,
          let host = url.host,
          let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
      throw HermesAgentClientError.invalidResponse
    }

    return try await withCheckedThrowingContinuation { continuation in
      let state = TransportState(continuation: continuation)
      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: port,
        using: .tcp
      )
      state.connection = connection

      connection.stateUpdateHandler = { newState in
        switch newState {
        case .ready:
          do {
            let payload = try requestData(for: request)
            connection.send(content: payload, completion: .contentProcessed { error in
              if let error {
                state.finish(.failure(error))
                return
              }
              receive(on: connection, state: state, buffer: Data())
            })
          } catch {
            state.finish(.failure(error))
          }
        case .failed(let error):
          state.finish(.failure(error))
        case .cancelled:
          break
        default:
          break
        }
      }

      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + max(1, request.timeoutInterval)
      ) {
        state.finish(.failure(URLError(.timedOut)))
      }

      connection.start(queue: .global(qos: .userInitiated))
    }
  }

  private static func requestData(for request: URLRequest) throws -> Data {
    guard let url = request.url, let host = url.host else {
      throw HermesAgentClientError.invalidResponse
    }

    let path = url.path.isEmpty ? "/" : url.path
    let target = url.query.map { "\(path)?\($0)" } ?? path
    let method = request.httpMethod ?? "GET"
    let body = request.httpBody ?? Data()
    let hostHeader = url.port.map { "\(host):\($0)" } ?? host

    var headers = request.allHTTPHeaderFields ?? [:]
    headers["Host"] = headers["Host"] ?? hostHeader
    headers["Connection"] = "close"
    headers["Accept"] = headers["Accept"] ?? "application/json"
    if !body.isEmpty {
      headers["Content-Length"] = "\(body.count)"
    }

    var head = "\(method) \(target) HTTP/1.1\r\n"
    for (key, value) in headers {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"

    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  private static func receive(
    on connection: NWConnection,
    state: TransportState,
    buffer: Data
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      data,
      _,
      isComplete,
      error in
      if let error {
        state.finish(.failure(error))
        return
      }

      var nextBuffer = buffer
      if let data {
        nextBuffer.append(data)
      }

      if isComplete {
        do {
          state.finish(.success(try parseResponse(nextBuffer)))
        } catch {
          state.finish(.failure(error))
        }
        return
      }

      receive(on: connection, state: state, buffer: nextBuffer)
    }
  }

  private static func parseResponse(_ data: Data) throws -> HermesHTTPResponse {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator),
          let headerText = String(
            data: data.subdata(in: data.startIndex..<headerRange.lowerBound),
            encoding: .utf8
          ) else {
      throw HermesAgentClientError.invalidResponse
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
      throw HermesAgentClientError.invalidResponse
    }
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
      throw HermesAgentClientError.invalidResponse
    }

    let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
      guard let separator = line.firstIndex(of: ":") else { return }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      result[key.lowercased()] = value
    }

    var body = data.subdata(in: headerRange.upperBound..<data.endIndex)
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      body = try decodeChunkedBody(body)
    }

    return HermesHTTPResponse(statusCode: statusCode, headers: headers, data: body)
  }

  private static func decodeChunkedBody(_ data: Data) throws -> Data {
    let newline = Data("\r\n".utf8)
    var offset = data.startIndex
    var output = Data()

    while offset < data.endIndex {
      guard let sizeRange = data[offset...].range(of: newline),
            let sizeText = String(data: data[offset..<sizeRange.lowerBound], encoding: .utf8),
            let chunkSize = Int(sizeText.split(separator: ";")[0], radix: 16) else {
        throw HermesAgentClientError.invalidResponse
      }
      offset = sizeRange.upperBound
      if chunkSize == 0 { break }

      let chunkEnd = offset + chunkSize
      guard chunkEnd <= data.endIndex else {
        throw HermesAgentClientError.invalidResponse
      }
      output.append(data[offset..<chunkEnd])
      offset = min(chunkEnd + newline.count, data.endIndex)
    }

    return output
  }
}

private final class TransportState: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  var connection: NWConnection?

  private let continuation: CheckedContinuation<HermesHTTPResponse, Error>

  init(continuation: CheckedContinuation<HermesHTTPResponse, Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<HermesHTTPResponse, Error>) {
    lock.lock()
    if completed {
      lock.unlock()
      return
    }
    completed = true
    let connection = connection
    lock.unlock()

    connection?.cancel()

    switch result {
    case .success(let response):
      continuation.resume(returning: response)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}

extension HermesAgentAPIClient {
  static let screenshotFootnote =
    "Screenshot attached for active context of what I'm currently viewing or working on."
  static let clipboardContextHeader = "Last copied text attached as clipboard context:"
  static let clipboardContextCharacterLimit = 12_000

  static func extractOutputText(from data: Data) throws -> String {
    try JSONDecoder().decode(ResponsesEnvelope.self, from: data).extractedText
  }

  static func requestBodyData(
    input: String,
    settings: HermesAgentSettings,
    imageAttachment: HermesAgentImageAttachment?,
    clipboardText: String?
  ) throws -> Data {
    let body = ResponsesRequest(
      model: settings.normalizedModel,
      input: .from(text: input, imageAttachment: imageAttachment, clipboardText: clipboardText),
      conversation: settings.normalizedConversationName,
      store: true
    )
    return try JSONEncoder().encode(body)
  }

  static func enrichedInputText(
    input: String,
    imageAttachment: HermesAgentImageAttachment?,
    clipboardText: String?
  ) -> String {
    var sections = [input]
    if let clipboardContext = normalizedClipboardText(clipboardText) {
      sections.append("\(clipboardContextHeader)\n\(clipboardContext)")
    }
    if imageAttachment != nil {
      sections.append("Footnote: \(screenshotFootnote)")
    }
    return sections.joined(separator: "\n\n")
  }

  static func normalizedClipboardText(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > clipboardContextCharacterLimit else { return trimmed }

    let limitIndex = trimmed.index(
      trimmed.startIndex,
      offsetBy: clipboardContextCharacterLimit
    )
    return String(trimmed[..<limitIndex])
      + "\n[Clipboard text truncated to \(clipboardContextCharacterLimit) characters.]"
  }

  static func endpointURL(path: String, baseURLString: String) throws -> URL {
    let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingTrailingSlashes()
    guard let url = URL(string: base) else {
      throw HermesAgentClientError.invalidBaseURL(baseURLString)
    }
    if url.pathComponents.last == "v1" {
      return url.appendingPathComponent(path)
    }
    return url
      .appendingPathComponent("v1")
      .appendingPathComponent(path)
  }
}

private struct ResponsesRequest: Encodable {
  let model: String
  let input: ResponsesInput
  let conversation: String
  let store: Bool
}

private enum ResponsesInput: Encodable {
  case text(String)
  case multimodal([ResponsesInputMessage])

  static func from(
    text: String,
    imageAttachment: HermesAgentImageAttachment?,
    clipboardText: String?
  ) -> ResponsesInput {
    let enrichedText = HermesAgentAPIClient.enrichedInputText(
      input: text,
      imageAttachment: imageAttachment,
      clipboardText: clipboardText
    )
    guard let imageAttachment else { return .text(enrichedText) }
    return .multimodal([
      ResponsesInputMessage(
        role: "user",
        content: [
          .text(enrichedText),
          .image(imageAttachment)
        ]
      )
    ])
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .text(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .multimodal(let messages):
      var container = encoder.singleValueContainer()
      try container.encode(messages)
    }
  }
}

private struct ResponsesInputMessage: Encodable {
  let role: String
  let content: [ResponsesContentPart]
}

private enum ResponsesContentPart: Encodable {
  case text(String)
  case image(HermesAgentImageAttachment)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
    case detail
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try container.encode("input_text", forKey: .type)
      try container.encode(value, forKey: .text)
    case .image(let attachment):
      try container.encode("input_image", forKey: .type)
      try container.encode(attachment.dataURL, forKey: .imageURL)
      try container.encode("auto", forKey: .detail)
    }
  }
}

private struct ResponsesEnvelope: Decodable {
  let id: String
  let model: String
  let output: [OutputItem]
  let outputText: String?

  enum CodingKeys: String, CodingKey {
    case id
    case model
    case output
    case outputText = "output_text"
  }

  var extractedText: String {
    if let outputText, !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return outputText
    }

    let assistantMessages = output.filter { $0.type == "message" && $0.role == "assistant" }
    let messageText = assistantMessages
      .flatMap { $0.content ?? [] }
      .compactMap { part -> String? in
        guard part.type == "output_text" || part.type == "text" else { return nil }
        return part.text
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !messageText.isEmpty { return messageText }

    return output
      .flatMap { $0.content ?? [] }
      .compactMap(\.text)
      .joined(separator: "\n")
  }
}

private struct OutputItem: Decodable {
  let type: String
  let role: String?
  let content: [OutputContent]?
}

private struct OutputContent: Decodable {
  let type: String
  let text: String?
}

private struct ErrorEnvelope: Decodable {
  let error: ErrorPayload
}

private struct ErrorPayload: Decodable {
  let message: String
}

private extension String {
  func trimmingTrailingSlashes() -> String {
    var value = self
    while value.last == "/" {
      value.removeLast()
    }
    return value
  }
}
