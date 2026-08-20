import Foundation
import OSLog

#if canImport(Qwen3ASR)

/// Owns the `--qwen-helper` child. All MLX work stays in that process.
final class QwenASRHelperClient: @unchecked Sendable {
  static let shared = QwenASRHelperClient()

  private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "QwenASR")
  private var process: Process?
  private var stdin: FileHandle?
  private var stdout: FileHandle?
  private var remainder = Data()
  private let jobTimeout: TimeInterval = 60
  private let readyTimeout: TimeInterval = 45

  func prepare() throws {
    try ensureReady()
  }

  func transcribe(fileURL: URL, language: String?, context: String?) throws -> String {
    try ensureReady()
    let request = QwenHelperRequest(
      path: fileURL.path,
      language: language,
      context: context
    )
    let payload = try JSONEncoder().encode(request) + Data([0x0A])
    guard let stdin else { throw QwenASRError.helperFailed("helper stdin closed") }
    try stdin.write(contentsOf: payload)
    let deadline = Date().addingTimeInterval(jobTimeout)
    while Date() < deadline {
      let line = try readLine(timeout: deadline.timeIntervalSinceNow)
      guard let data = line.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(QwenHelperResponse.self, from: data)
      else {
        continue
      }
      if let error = decoded.error, !error.isEmpty {
        throw QwenASRError.helperFailed(error)
      }
      return decoded.text ?? ""
    }
    throw QwenASRError.helperFailed("helper timed out")
  }

  func terminate() {
    process?.terminate()
    process = nil
    stdin = nil
    stdout = nil
    remainder = Data()
  }

  func restart() throws {
    terminate()
    try ensureReady()
  }

  private func ensureReady() throws {
    if process?.isRunning == true, stdin != nil, stdout != nil { return }
    terminate()
    guard let exe = Bundle.main.executableURL else {
      throw QwenASRError.helperFailed("missing executable")
    }
    let inPipe = Pipe()
    let outPipe = Pipe()
    let errPipe = Pipe()
    let child = Process()
    child.executableURL = exe
    child.arguments = [QwenTranscribeHelper.flag]
    var env = ProcessInfo.processInfo.environment
    env["QWEN_IN_HELPER"] = "1"
    child.environment = env
    child.standardInput = inPipe
    child.standardOutput = outPipe
    child.standardError = errPipe
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      AppLog.dictation.log("[QwenHelper] \(trimmed)")
    }
    AppLog.dictation.log("[QwenASR] starting out-of-process helper")
    try child.run()
    process = child
    stdin = inPipe.fileHandleForWriting
    stdout = outPipe.fileHandleForReading
    remainder = Data()
    let deadline = Date().addingTimeInterval(readyTimeout)
    while Date() < deadline {
      let line = try readLine(timeout: deadline.timeIntervalSinceNow)
      if line == QwenTranscribeHelper.readyLine { return }
      if line.hasPrefix("QWEN_HELPER_ERROR=") {
        let message = String(line.dropFirst("QWEN_HELPER_ERROR=".count))
        terminate()
        throw QwenASRError.helperFailed(message)
      }
    }
    terminate()
    throw QwenASRError.helperFailed("helper did not become ready")
  }

  private func readLine(timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(max(0.1, timeout))
    while Date() < deadline {
      if let line = popLine() { return line }
      guard let stdout else { throw QwenASRError.helperFailed("helper stdout closed") }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      let chunk = try stdout.read(upToCount: 4096)
      if chunk == nil || chunk?.isEmpty == true {
        throw QwenASRError.helperFailed("helper exited")
      }
      remainder.append(chunk!)
    }
    throw QwenASRError.helperFailed("helper timed out")
  }

  private func popLine() -> String? {
    guard let idx = remainder.firstIndex(of: 0x0A) else { return nil }
    let data = remainder.subdata(in: remainder.startIndex..<idx)
    let next = remainder.index(after: idx)
    remainder = remainder.subdata(in: next..<remainder.endIndex)
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
  }
}

#endif
