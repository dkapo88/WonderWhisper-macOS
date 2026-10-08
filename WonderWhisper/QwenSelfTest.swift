import Foundation

/// Hidden CLI: `WonderWhisper --qwen-self-test /path/to.wav [--qwen-model-dir DIR]`
///
/// Runs the same Qwen provider as dictation (verified load: integrity, eval,
/// canary), then exits. Used to verify the notarized binary, which XCTest
/// cannot represent (it injects get-task-allow). `--qwen-model-dir` points the
/// runtime at a scratch model copy instead of the user's cache.
///
/// Exit codes: 0 ok, 1 error (including a failed load check), 2 usage,
/// 3 garbage returned (should be impossible now; the runtime throws instead).
enum QwenSelfTest {
  static func runIfRequested() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--qwen-self-test") else { return }
    guard args.indices.contains(index + 1) else {
      fputs("usage: WonderWhisper --qwen-self-test <wav> [--qwen-model-dir <dir>]\n", stderr)
      exit(2)
    }
    let url = URL(fileURLWithPath: args[index + 1])
    let runtime: QwenASRRuntime
    if let dirIndex = args.firstIndex(of: "--qwen-model-dir"), args.indices.contains(dirIndex + 1) {
      let dir = URL(fileURLWithPath: args[dirIndex + 1], isDirectory: true)
      runtime = QwenASRRuntime(modelDirectory: { dir })
    } else {
      runtime = .shared
    }
    let box = SelfTestBox()
    let lock = DispatchSemaphore(value: 0)
    Task.detached {
      defer { lock.signal() }
      do {
        let text = try await QwenASRTranscriptionProvider(runtime: runtime).transcribe(
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
    _ = lock.wait(timeout: .now() + 120)
    if let error = box.error {
      fputs("QWEN_SELF_TEST_ERROR=\(error.localizedDescription)\n", stderr)
      exit(1)
    }
    let text = box.text ?? ""
    fputs("QWEN_SELF_TEST=\(text)\n", stdout)
    fflush(stdout)
    exit(QwenASRManager.looksLikeDegenerateTranscript(text, sampleCount: 0) ? 3 : 0)
  }
}

private final class SelfTestBox: @unchecked Sendable {
  var text: String?
  var error: Error?
}
