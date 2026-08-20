import Foundation

/// Hidden CLI: `WonderWhisper --qwen-self-test /path/to.wav`
///
/// Runs the same Qwen provider as dictation, then exits. Used to verify the
/// notarized binary, which XCTest cannot represent (it injects get-task-allow).
enum QwenSelfTest {
  static func runIfRequested() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--qwen-self-test") else { return }
    guard args.indices.contains(index + 1) else {
      fputs("usage: WonderWhisper --qwen-self-test <wav>\n", stderr)
      exit(2)
    }
    let url = URL(fileURLWithPath: args[index + 1])
    let box = SelfTestBox()
    let lock = DispatchSemaphore(value: 0)
    Task.detached {
      defer { lock.signal() }
      do {
        let text = try await QwenASRTranscriptionProvider().transcribe(
          fileURL: url,
          settings: TranscriptionSettings(
            endpoint: URL(string: "https://localhost")!,
            model: "qwen-local",
            language: "en"
          )
        )
        box.text = text
      } catch {
        box.error = error
      }
    }
    _ = lock.wait(timeout: .now() + 60)
    if let error = box.error {
      fputs("QWEN_SELF_TEST_ERROR=\(error.localizedDescription)\n", stderr)
      exit(1)
    }
    let text = box.text ?? ""
    fputs("QWEN_SELF_TEST=\(text)\n", stdout)
    fflush(stdout)
    let bangs = text.filter { $0 == "!" }.count
    exit(bangs > 20 || text.count > 400 ? 3 : 0)
  }
}

private final class SelfTestBox: @unchecked Sendable {
  var text: String?
  var error: Error?
}
