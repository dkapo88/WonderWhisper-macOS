import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation

struct CodexThreadSummary: Equatable {
  let id: String
  let name: String?
  let preview: String
  let cwd: String
  let createdAt: Date
  let updatedAt: Date

  var displayTitle: String {
    let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !named.isEmpty { return named }
    let preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
    return preview.isEmpty ? "Codex" : String(preview.prefix(80))
  }
}

struct CodexAgentMessage: Equatable {
  let id: String
  let text: String
  let phase: String?
}

struct CodexThreadSnapshot: Equatable {
  let thread: CodexThreadSummary
  let agentMessages: [CodexAgentMessage]
}

struct CodexTurnResult: Equatable {
  let threadID: String
  let turnID: String
  let message: CodexAgentMessage
}

enum CodexAppServerError: LocalizedError {
  case executableNotFound
  case invalidResponse
  case processExited(Int32)
  case server(String)
  case turnFailed(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .executableNotFound:
      return "Codex is not installed. Install the Codex desktop app or CLI."
    case .invalidResponse:
      return "Codex App Server returned an invalid response."
    case .processExited(let status):
      return "Codex App Server exited with status \(status)."
    case .server(let message):
      return "Codex App Server error: \(message)"
    case .turnFailed(let message):
      return "Codex task failed: \(message)"
    case .timedOut:
      return "Codex did not finish before the request timed out."
    }
  }
}

enum CodexDesktopIPCError: LocalizedError {
  case desktopUnavailable
  case noClientFound
  case invalidResponse
  case rolloutNotFound
  case server(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .desktopUnavailable:
      return "Codex Desktop is not running or its local bridge is unavailable."
    case .noClientFound:
      return "Codex Desktop did not load the task."
    case .invalidResponse:
      return "Codex Desktop returned an invalid response."
    case .rolloutNotFound:
      return "The Codex task history file could not be found."
    case .server(let message):
      return "Codex Desktop error: \(message)"
    case .timedOut:
      return "Codex Desktop did not finish before the request timed out."
    }
  }
}

enum CodexDesktopIPCFrame {
  static func encode(_ object: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: object)
    guard payload.count <= Int(UInt32.max) else {
      throw CodexDesktopIPCError.invalidResponse
    }
    var length = UInt32(payload.count).littleEndian
    var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    data.append(payload)
    return data
  }
}

actor CodexDesktopIPCClient {
  private var rolloutURLs: [String: URL] = [:]

  func send(text: String,
            to threadID: String,
            timeout: TimeInterval = 1_800) async throws -> CodexTurnResult {
    let rolloutURL = try rolloutURL(for: threadID)
    let offset = Self.fileSize(at: rolloutURL)
    let turnID: String

    do {
      turnID = try await startTurn(text: text, threadID: threadID)
    } catch CodexDesktopIPCError.desktopUnavailable {
      try await openTaskAndWait(threadID)
      turnID = try await startTurn(text: text, threadID: threadID)
    } catch CodexDesktopIPCError.noClientFound {
      try await openTaskAndWait(threadID)
      turnID = try await startTurn(text: text, threadID: threadID)
    }

    return try await Self.waitForCompletion(
      threadID: threadID,
      turnID: turnID,
      rolloutURL: rolloutURL,
      startingAt: offset,
      timeout: timeout
    )
  }

  private func startTurn(text: String, threadID: String) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      try Self.startTurnSync(text: text, threadID: threadID)
    }.value
  }

  @MainActor
  private func openTaskAndWait(_ threadID: String) async throws {
    let previousApp = NSWorkspace.shared.frontmostApplication
    guard let url = URL(string: "codex://threads/\(threadID)"),
          NSWorkspace.shared.open(url) else {
      throw CodexDesktopIPCError.desktopUnavailable
    }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    if previousApp?.bundleIdentifier != "com.openai.codex" {
      previousApp?.activate()
    }
  }

  private func rolloutURL(for threadID: String) throws -> URL {
    if let cached = rolloutURLs[threadID],
       FileManager.default.fileExists(atPath: cached.path) {
      return cached
    }

    let codexRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
    let roots = [
      codexRoot.appendingPathComponent("sessions", isDirectory: true),
      codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
    ]
    let suffix = "-\(threadID).jsonl"

    // ponytail: linear scan is enough for one active reply; index this only if lookup becomes slow.
    for root in roots {
      guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) else { continue }
      for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
        rolloutURLs[threadID] = url
        return url
      }
    }
    throw CodexDesktopIPCError.rolloutNotFound
  }

  private static func startTurnSync(text: String, threadID: String) throws -> String {
    let socketURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-ipc", isDirectory: true)
      .appendingPathComponent("ipc-\(getuid()).sock")
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CodexDesktopIPCError.desktopUnavailable }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketURL.path.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count <= pathCapacity else {
      throw CodexDesktopIPCError.desktopUnavailable
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
        for (index, byte) in path.enumerated() {
          destination[index] = byte
        }
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw CodexDesktopIPCError.desktopUnavailable }

    let initializeID = UUID().uuidString
    try writeFrame([
      "type": "request",
      "requestId": initializeID,
      "version": 0,
      "method": "initialize",
      "params": ["clientType": "wonderwhisper"]
    ], to: descriptor)
    let initialize = try response(
      for: initializeID,
      method: "initialize",
      from: descriptor
    )
    guard let result = initialize["result"] as? [String: Any],
          let clientID = result["clientId"] as? String else {
      throw CodexDesktopIPCError.invalidResponse
    }

    let requestID = UUID().uuidString
    try writeFrame([
      "type": "request",
      "requestId": requestID,
      "sourceClientId": clientID,
      "version": 1,
      "method": "thread-follower-start-turn",
      "params": [
        "conversationId": threadID,
        "turnStartParams": [
          "clientUserMessageId": UUID().uuidString,
          "input": [
            [
              "type": "text",
              "text": text,
              "text_elements": []
            ]
          ]
        ]
      ]
    ], to: descriptor)
    let response = try response(
      for: requestID,
      method: "thread-follower-start-turn",
      from: descriptor
    )
    guard let outerResult = response["result"] as? [String: Any],
          let innerResult = outerResult["result"] as? [String: Any],
          let turn = innerResult["turn"] as? [String: Any],
          let turnID = turn["id"] as? String else {
      throw CodexDesktopIPCError.invalidResponse
    }
    return turnID
  }

  private static func response(for requestID: String,
                               method: String,
                               from descriptor: Int32) throws -> [String: Any] {
    while true {
      let object = try readFrame(from: descriptor)
      guard object["type"] as? String == "response",
            object["requestId"] as? String == requestID,
            object["method"] as? String == method else {
        continue
      }
      let resultType = object["resultType"] as? String ?? ""
      guard resultType == "success" else {
        let serialized = String(
          data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(),
          encoding: .utf8
        ) ?? resultType
        if serialized.localizedCaseInsensitiveContains("no-client") {
          throw CodexDesktopIPCError.noClientFound
        }
        throw CodexDesktopIPCError.server(serialized)
      }
      return object
    }
  }

  private static func writeFrame(_ object: [String: Any], to descriptor: Int32) throws {
    let data = try CodexDesktopIPCFrame.encode(object)
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var written = 0
      while written < data.count {
        let count = Darwin.write(
          descriptor,
          base.advanced(by: written),
          data.count - written
        )
        guard count > 0 else { throw CodexDesktopIPCError.desktopUnavailable }
        written += count
      }
    }
  }

  private static func readFrame(from descriptor: Int32) throws -> [String: Any] {
    let header = try readExactly(4, from: descriptor)
    let length = header.enumerated().reduce(UInt32(0)) { value, element in
      value | (UInt32(element.element) << UInt32(element.offset * 8))
    }
    guard length > 0, length <= 64 * 1_024 * 1_024 else {
      throw CodexDesktopIPCError.invalidResponse
    }
    let payload = try readExactly(Int(length), from: descriptor)
    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      throw CodexDesktopIPCError.invalidResponse
    }
    return object
  }

  private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
      let amount = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(
          descriptor,
          buffer.baseAddress?.advanced(by: received),
          count - received
        )
      }
      guard amount > 0 else { throw CodexDesktopIPCError.desktopUnavailable }
      received += amount
    }
    return Data(bytes)
  }

  private static func waitForCompletion(threadID: String,
                                        turnID: String,
                                        rolloutURL: URL,
                                        startingAt offset: UInt64,
                                        timeout: TimeInterval) async throws -> CodexTurnResult {
    let deadline = Date().addingTimeInterval(timeout)
    var readOffset = offset
    var buffered = Data()
    var finalMessage: CodexAgentMessage?

    while Date() < deadline {
      let handle = try FileHandle(forReadingFrom: rolloutURL)
      try handle.seek(toOffset: readOffset)
      let data = try handle.readToEnd() ?? Data()
      try? handle.close()
      readOffset += UInt64(data.count)
      buffered.append(data)

      while let newline = buffered.firstRange(of: Data([0x0A])) {
        let line = buffered[..<newline.lowerBound]
        buffered.removeSubrange(...newline.lowerBound)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else {
          continue
        }

        if type == "response_item",
           payload["type"] as? String == "message",
           payload["role"] as? String == "assistant",
           let metadata = payload["internal_chat_message_metadata_passthrough"]
             as? [String: Any],
           metadata["turn_id"] as? String == turnID,
           let id = payload["id"] as? String {
          let content = payload["content"] as? [[String: Any]] ?? []
          let text = content.compactMap { $0["text"] as? String }.joined()
          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalMessage = CodexAgentMessage(
              id: id,
              text: text,
              phase: payload["phase"] as? String
            )
          }
        }

        if type == "event_msg",
           payload["type"] as? String == "task_complete",
           payload["turn_id"] as? String == turnID {
          let text = payload["last_agent_message"] as? String ?? finalMessage?.text ?? ""
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexDesktopIPCError.invalidResponse
          }
          return CodexTurnResult(
            threadID: threadID,
            turnID: turnID,
            message: CodexAgentMessage(
              id: finalMessage?.id ?? "desktop-\(turnID)",
              text: text,
              phase: finalMessage?.phase ?? "final_answer"
            )
          )
        }
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw CodexDesktopIPCError.timedOut
  }

  private static func fileSize(at url: URL) -> UInt64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return UInt64(values?.fileSize ?? 0)
  }
}

enum CodexTaskDirectory {
  static let defaultRoot = "~/Documents/Codex"

  static func expandedRoot(_ value: String) -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = trimmed.isEmpty ? defaultRoot : trimmed
    return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
  }

  static func create(root: String, prompt: String, date: Date = Date()) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"

    let dateFolder = expandedRoot(root)
      .appendingPathComponent(formatter.string(from: date), isDirectory: true)
    try FileManager.default.createDirectory(
      at: dateFolder,
      withIntermediateDirectories: true
    )

    let base = slug(prompt)
    var candidate = dateFolder.appendingPathComponent(base, isDirectory: true)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dateFolder.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
      suffix += 1
    }
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    return candidate
  }

  static func slug(_ value: String) -> String {
    let folded = value
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
    let words = folded
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .prefix(8)
    let slug = words.joined(separator: "-")
    return String((slug.isEmpty ? "voice-task" : slug).prefix(64))
  }
}

enum CodexDesktopState {
  static func projectlessThreadIDs() -> Set<String> {
    stringSet(for: "projectless-thread-ids")
  }

  static func pinnedThreadIDs() -> Set<String> {
    stringSet(for: "pinned-thread-ids")
  }

  private static func stringSet(for key: String) -> Set<String> {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/.codex-global-state.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let values = object[key] as? [String] else {
      return []
    }
    return Set(values)
  }
}

@MainActor
enum CodexTaskPinner {
  static func pin(threadID: String) async -> Bool {
    if CodexDesktopState.pinnedThreadIDs().contains(threadID) {
      return true
    }
    guard AXIsProcessTrusted(),
          let url = URL(string: "codex://threads/\(threadID)") else {
      return false
    }

    let previousApp = NSWorkspace.shared.frontmostApplication
    guard NSWorkspace.shared.open(url) else { return false }
    try? await Task.sleep(nanoseconds: 1_200_000_000)

    guard let codex = NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.openai.codex")
      .first else {
      return false
    }
    codex.activate(options: [.activateAllWindows])
    try? await Task.sleep(nanoseconds: 300_000_000)

    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(
      keyboardEventSource: source,
      virtualKey: CGKeyCode(kVK_ANSI_P),
      keyDown: true
    )
    let up = CGEvent(
      keyboardEventSource: source,
      virtualKey: CGKeyCode(kVK_ANSI_P),
      keyDown: false
    )
    down?.flags = [.maskCommand, .maskAlternate]
    up?.flags = [.maskCommand, .maskAlternate]
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)

    var pinned = false
    for _ in 0..<8 {
      try? await Task.sleep(nanoseconds: 250_000_000)
      if CodexDesktopState.pinnedThreadIDs().contains(threadID) {
        pinned = true
        break
      }
    }
    if previousApp?.bundleIdentifier != codex.bundleIdentifier {
      previousApp?.activate()
    }
    return pinned
  }
}

actor CodexAppServerClient {
  private var process: Process?
  private var input: FileHandle?
  private var outputBuffer = Data()
  private var nextRequestID = 1
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var initialized = false
  private var isInitializing = false

  func checkConnection() async throws {
    _ = try await listThreads()
  }

  func startThread(cwd: URL, title: String) async throws -> CodexThreadSummary {
    let response = try await request(
      method: "thread/start",
      params: [
        "cwd": cwd.path,
        "ephemeral": false,
        "threadSource": "wonderwhisper"
      ]
    )
    guard let thread = response["thread"] as? [String: Any],
          let summary = Self.threadSummary(from: thread) else {
      throw CodexAppServerError.invalidResponse
    }

    let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanedTitle.isEmpty {
      _ = try? await request(
        method: "thread/name/set",
        params: ["threadId": summary.id, "name": String(cleanedTitle.prefix(80))]
      )
    }
    return CodexThreadSummary(
      id: summary.id,
      name: cleanedTitle.isEmpty ? summary.name : String(cleanedTitle.prefix(80)),
      preview: summary.preview,
      cwd: summary.cwd,
      createdAt: summary.createdAt,
      updatedAt: summary.updatedAt
    )
  }

  func send(text: String,
            to threadID: String,
            timeout: TimeInterval = 1_800) async throws -> CodexTurnResult {
    _ = try await request(
      method: "thread/resume",
      params: ["threadId": threadID]
    )
    let response = try await request(
      method: "turn/start",
      params: [
        "threadId": threadID,
        "clientUserMessageId": UUID().uuidString,
        "input": [
          [
            "type": "text",
            "text": text,
            "text_elements": []
          ]
        ]
      ]
    )
    guard let turn = response["turn"] as? [String: Any],
          let turnID = turn["id"] as? String else {
      throw CodexAppServerError.invalidResponse
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let raw = try await readRawThread(threadID)
      guard let turns = raw["turns"] as? [[String: Any]],
            let matchingTurn = turns.first(where: { $0["id"] as? String == turnID }),
            let status = matchingTurn["status"] as? String else {
        try await Task.sleep(nanoseconds: 500_000_000)
        continue
      }

      switch status {
      case "completed":
        guard let message = Self.finalAgentMessage(in: matchingTurn) else {
          throw CodexAppServerError.turnFailed("Codex completed without a final response.")
        }
        return CodexTurnResult(threadID: threadID, turnID: turnID, message: message)
      case "failed":
        let message = Self.errorMessage(in: matchingTurn) ?? "Unknown failure"
        throw CodexAppServerError.turnFailed(message)
      case "interrupted":
        throw CodexAppServerError.turnFailed("The task was interrupted.")
      default:
        try await Task.sleep(nanoseconds: 750_000_000)
      }
    }
    throw CodexAppServerError.timedOut
  }

  func listThreads() async throws -> [CodexThreadSummary] {
    var cursor: String?
    var threads: [CodexThreadSummary] = []
    repeat {
      var params: [String: Any] = [
        "limit": 100,
        "sortKey": "updated_at",
        "sortDirection": "desc",
        "archived": false
      ]
      if let cursor { params["cursor"] = cursor }
      let response = try await request(method: "thread/list", params: params)
      let data = response["data"] as? [[String: Any]] ?? []
      threads.append(contentsOf: data.compactMap(Self.threadSummary(from:)))
      cursor = response["nextCursor"] as? String
    } while cursor != nil
    return threads
  }

  func readThread(_ threadID: String) async throws -> CodexThreadSnapshot {
    let thread = try await readRawThread(threadID)
    guard let summary = Self.threadSummary(from: thread) else {
      throw CodexAppServerError.invalidResponse
    }
    return CodexThreadSnapshot(
      thread: summary,
      agentMessages: Self.agentMessages(in: thread)
    )
  }

  func stop() {
    process?.terminationHandler = nil
    process?.terminate()
    process = nil
    input = nil
    outputBuffer.removeAll()
    nextRequestID = 1
    initialized = false
    isInitializing = false
    let continuations = pending.values
    pending.removeAll()
    continuations.forEach {
      $0.resume(throwing: CodexAppServerError.processExited(-1))
    }
  }

  private func readRawThread(_ threadID: String) async throws -> [String: Any] {
    let response = try await request(
      method: "thread/read",
      params: ["threadId": threadID, "includeTurns": true]
    )
    guard let thread = response["thread"] as? [String: Any] else {
      throw CodexAppServerError.invalidResponse
    }
    return thread
  }

  private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
    try await ensureStarted()
    return try await sendRequest(method: method, params: params)
  }

  private func ensureStarted() async throws {
    if initialized { return }
    if isInitializing {
      while isInitializing && !initialized {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      if initialized { return }
    }

    isInitializing = true
    defer { isInitializing = false }
    try launch()
    _ = try await sendRequest(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "wonderwhisper",
          "title": "WonderWhisper",
          "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        ]
      ]
    )
    try write(["method": "initialized", "params": [:]])
    initialized = true
  }

  private func launch() throws {
    if process?.isRunning == true { return }
    guard let executable = Self.codexExecutableURL() else {
      throw CodexAppServerError.executableNotFound
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server"]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { await self?.consume(data) }
    }
    process.terminationHandler = { [weak self] process in
      Task { await self?.didTerminate(status: process.terminationStatus) }
    }

    try process.run()
    self.process = process
    input = stdin.fileHandleForWriting
  }

  private func sendRequest(method: String,
                           params: [String: Any]) async throws -> [String: Any] {
    let id = nextRequestID
    nextRequestID += 1
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try write(["method": method, "id": id, "params": params])
      } catch {
        pending[id] = nil
        continuation.resume(throwing: error)
      }
    }
  }

  private func write(_ object: [String: Any]) throws {
    guard let input else { throw CodexAppServerError.processExited(-1) }
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try input.write(contentsOf: data)
  }

  private func consume(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
      let line = outputBuffer[..<newline.lowerBound]
      outputBuffer.removeSubrange(...newline.lowerBound)
      guard !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if let method = object["method"] as? String {
        if let id = (object["id"] as? NSNumber)?.intValue {
          try? write([
            "id": id,
            "error": [
              "code": -32601,
              "message": "WonderWhisper cannot answer Codex server request \(method)."
            ]
          ])
        }
        continue
      }
      guard let id = (object["id"] as? NSNumber)?.intValue,
            let continuation = pending.removeValue(forKey: id) else {
        continue
      }
      if let error = object["error"] as? [String: Any] {
        let message = error["message"] as? String ?? String(describing: error)
        continuation.resume(throwing: CodexAppServerError.server(message))
      } else if let result = object["result"] as? [String: Any] {
        continuation.resume(returning: result)
      } else {
        continuation.resume(throwing: CodexAppServerError.invalidResponse)
      }
    }
  }

  private func didTerminate(status: Int32) {
    process = nil
    input = nil
    initialized = false
    let continuations = pending.values
    pending.removeAll()
    continuations.forEach {
      $0.resume(throwing: CodexAppServerError.processExited(status))
    }
  }

  private static func codexExecutableURL() -> URL? {
    let candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/codex").path,
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex"
    ]
    return candidates
      .map { URL(fileURLWithPath: $0) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private static func threadSummary(from value: [String: Any]) -> CodexThreadSummary? {
    guard let id = value["id"] as? String,
          let preview = value["preview"] as? String,
          let cwd = value["cwd"] as? String,
          let createdAt = (value["createdAt"] as? NSNumber)?.doubleValue,
          let updatedAt = (value["updatedAt"] as? NSNumber)?.doubleValue else {
      return nil
    }
    return CodexThreadSummary(
      id: id,
      name: value["name"] as? String,
      preview: preview,
      cwd: cwd,
      createdAt: Date(timeIntervalSince1970: createdAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  private static func agentMessages(in thread: [String: Any]) -> [CodexAgentMessage] {
    let turns = thread["turns"] as? [[String: Any]] ?? []
    return turns.flatMap { turn -> [CodexAgentMessage] in
      let items = turn["items"] as? [[String: Any]] ?? []
      return items.compactMap(agentMessage(from:))
    }
  }

  private static func finalAgentMessage(in turn: [String: Any]) -> CodexAgentMessage? {
    let items = turn["items"] as? [[String: Any]] ?? []
    return items.compactMap(agentMessage(from:)).last {
      $0.phase == nil || $0.phase == "final_answer"
    }
  }

  private static func agentMessage(from item: [String: Any]) -> CodexAgentMessage? {
    guard item["type"] as? String == "agentMessage",
          let id = item["id"] as? String,
          let text = item["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return CodexAgentMessage(id: id, text: text, phase: item["phase"] as? String)
  }

  private static func errorMessage(in turn: [String: Any]) -> String? {
    guard let error = turn["error"] else { return nil }
    if let error = error as? [String: Any] {
      return error["message"] as? String ?? String(describing: error)
    }
    return String(describing: error)
  }
}
