import Foundation
import AppKit

#if canImport(Qwen3ASR)

/// JSON line protocol between the GUI process and `--qwen-helper`.
///
/// The GUI process cannot run MLX: SwiftUI/overlay Metal poisons greedy
/// decode into 448 `!` tokens and in-process reload does not recover.
/// A child of the same binary transcribes the same wav as English.
struct QwenHelperRequest: Codable {
  var path: String
  var language: String?
  var context: String?
}

struct QwenHelperResponse: Codable {
  var text: String?
  var error: String?
}

enum QwenTranscribeHelper {
  static let readyLine = "QWEN_HELPER_READY"
  static let flag = "--qwen-helper"

  static func runIfRequested() {
    guard CommandLine.arguments.contains(flag) else { return }
    setenv("QWEN_IN_HELPER", "1", 1)
    NSApplication.shared.setActivationPolicy(.prohibited)

    let loaded = DispatchSemaphore(value: 0)
    let loadBox = QwenHelperBox()
    Task.detached {
      defer { loaded.signal() }
      do {
        try await QwenASRRuntime.shared.warmUp()
      } catch {
        loadBox.error = error
      }
    }
    if loaded.wait(timeout: .now() + 45) == .timedOut {
      fputs("QWEN_HELPER_ERROR=model load timed out\n", stdout)
      fflush(stdout)
      exit(1)
    }
    if let loadError = loadBox.error {
      fputs("QWEN_HELPER_ERROR=\(loadError.localizedDescription)\n", stdout)
      fflush(stdout)
      exit(1)
    }
    fputs(readyLine + "\n", stdout)
    fflush(stdout)

    while let line = readLine(strippingNewline: true) {
      let box = QwenHelperBox()
      let lock = DispatchSemaphore(value: 0)
      Task.detached {
        defer { lock.signal() }
        do {
          let req = try JSONDecoder().decode(
            QwenHelperRequest.self,
            from: Data(line.utf8)
          )
          let url = URL(fileURLWithPath: req.path)
          let text = try await QwenASRRuntime.shared.transcribe(
            fileURL: url,
            language: req.language,
            context: req.context
          )
          box.text = text
        } catch {
          box.error = error
        }
      }
      _ = lock.wait(timeout: .now() + 60)
      let response: QwenHelperResponse
      if let error = box.error {
        response = QwenHelperResponse(text: nil, error: error.localizedDescription)
      } else {
        response = QwenHelperResponse(text: box.text ?? "", error: nil)
      }
      let data = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
      if let payload = String(data: data, encoding: .utf8) {
        fputs(payload + "\n", stdout)
        fflush(stdout)
      }
    }
    exit(0)
  }
}

private final class QwenHelperBox: @unchecked Sendable {
  var text: String?
  var error: Error?
}

#else
enum QwenTranscribeHelper {
  static func runIfRequested() {}
}
#endif
