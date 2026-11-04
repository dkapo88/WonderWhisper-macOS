import Foundation
import Network

/// A loopback server for wire tests: in WebSocket mode it records the upgrade request headers
/// and every frame a client sends; in HTTP mode it records each request and answers with a
/// fixed JSON body. Nothing leaves the machine.
final class LocalWireServer: @unchecked Sendable {
  enum Mode {
    case webSocket
    case http(responseBody: Data)
  }

  enum Frame: Equatable {
    case text(String)
    case binary(Int)
  }

  struct HTTPRequest {
    let head: String
    let body: Data
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "LocalWireServer")
  private let listener: NWListener
  private let mode: Mode
  private let headerSink: HeaderSink
  private var receivedFrames: [Frame] = []
  private var requests: [HTTPRequest] = []
  private var connections: [NWConnection] = []

  var headers: [[String: String]] { headerSink.values }
  var frames: [Frame] { lock.withLock { receivedFrames } }
  var httpRequests: [HTTPRequest] { lock.withLock { requests } }

  init(mode: Mode) throws {
    self.mode = mode
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    let headerSink = HeaderSink()
    if case .webSocket = mode {
      let options = NWProtocolWebSocket.Options()
      options.autoReplyPing = true
      options.setClientRequestHandler(queue) { _, additionalHeaders in
        var captured: [String: String] = [:]
        for (name, value) in additionalHeaders { captured[name.lowercased()] = value }
        headerSink.append(captured)
        return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
      }
      parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    }
    self.headerSink = headerSink
    listener = try NWListener(using: parameters, on: .any)
  }

  /// Starts listening on 127.0.0.1 and returns the port.
  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    return try await withCheckedThrowingContinuation { continuation in
      let resumed = NSLock()
      var done = false
      listener.stateUpdateHandler = { [listener] state in
        let finish: (Result<UInt16, Error>) -> Void = { result in
          let first = resumed.withLock { () -> Bool in
            defer { done = true }
            return !done
          }
          if first { continuation.resume(with: result) }
        }
        switch state {
        case .ready: finish(.success(listener.port?.rawValue ?? 0))
        case .failed(let error): finish(.failure(error))
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener.cancel()
    lock.withLock { connections }.forEach { $0.cancel() }
  }

  /// Waits until `condition` holds or `timeout` passes.
  func wait(timeout: TimeInterval = 5, until condition: (LocalWireServer) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition(self) { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition(self)
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { connections.append(connection) }
    connection.start(queue: queue)
    switch mode {
    case .webSocket: receiveFrame(on: connection)
    case .http(let body): receiveHTTP(on: connection, buffer: Data(), responseBody: body)
    }
  }

  private func receiveFrame(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self, error == nil else { return }
      if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        as? NWProtocolWebSocket.Metadata {
        switch metadata.opcode {
        case .text:
          let text = String(decoding: data ?? Data(), as: UTF8.self)
          lock.withLock { self.receivedFrames.append(.text(text)) }
        case .binary:
          lock.withLock { self.receivedFrames.append(.binary(data?.count ?? 0)) }
        default:
          break
        }
      }
      receiveFrame(on: connection)
    }
  }

  private func receiveHTTP(on connection: NWConnection, buffer: Data, responseBody: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = Self.completeRequest(in: buffer) {
        lock.withLock { self.requests.append(request) }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
          + "Content-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + responseBody, completion: .contentProcessed { _ in
          connection.cancel()
        })
        return
      }
      guard error == nil, !isComplete else { return }
      receiveHTTP(on: connection, buffer: buffer, responseBody: responseBody)
    }
  }

  private static func completeRequest(in buffer: Data) -> HTTPRequest? {
    guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
    let length = head.components(separatedBy: "\r\n")
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let body = buffer[separator.upperBound...]
    guard body.count >= length else { return nil }
    return HTTPRequest(head: head, body: Data(body.prefix(length)))
  }
}

private final class HeaderSink: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [[String: String]] = []
  var values: [[String: String]] { lock.withLock { stored } }
  func append(_ headers: [String: String]) { lock.withLock { stored.append(headers) } }
}
