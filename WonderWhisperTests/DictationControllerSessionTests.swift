import Foundation
import Testing
@testable import WonderWhisper

/// Drives the real `DictationController` stop path with a fake recorder, transcriber and
/// inserter: release tail, cancel during the tail, repeated stops and the silence gate.
@Suite(.serialized)
struct DictationControllerSessionTests {
  final class FakeRecorder: DictationAudioCapturing, @unchecked Sendable {
    var captureProfile: AudioRecorder.CaptureProfile = .standard16k
    private let lock = NSLock()
    private var samples: [Float]
    private var url: URL?
    private(set) var stopRequestedAt: TimeInterval?
    private(set) var stopCount = 0

    init(samples: [Float]) { self.samples = samples }

    var recordingURL: URL? { lock.withLock { url } }

    func startRecording() throws -> URL {
      let next = DictationAudioFixtures.temporaryURL()
      lock.withLock { url = next }
      return next
    }

    func stopRecording() -> URL? {
      lock.withLock {
        stopCount += 1
        stopRequestedAt = DictationClock.now()
        defer { url = nil }
        return url
      }
    }

    func stopRecordingAndWaitForFinish() async -> DictationCaptureStop {
      let target: URL? = lock.withLock {
        stopCount += 1
        stopRequestedAt = DictationClock.now()
        return url
      }
      guard let target else { return DictationCaptureStop(url: nil, finishedSuccessfully: false) }
      _ = try? DictationAudioFixtures.writeWAV(samples, to: target)
      return DictationCaptureStop(url: target, finishedSuccessfully: true)
    }

    func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {}
    func stopStreamingPCM16() {}
  }

  actor FakeTranscriber: TranscriptionProvider {
    private(set) var calls = 0
    private let delay: UInt64
    init(delayNanoseconds: UInt64 = 0) { delay = delayNanoseconds }
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
      calls += 1
      if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
      return "hello world"
    }
  }

  final class FakeInserter: DictationTextInserting, @unchecked Sendable {
    var useAXInsertion = false
    private let lock = NSLock()
    private var texts: [String] = []
    var inserted: [String] { lock.withLock { texts } }
    func insert(_ text: String, targetProcessIdentifier: pid_t?) {
      lock.withLock { texts.append(text) }
    }
  }

  private func makeController(
    recorder: FakeRecorder,
    transcriber: FakeTranscriber,
    inserter: FakeInserter,
    tail: TimeInterval = DictationController.defaultReleaseTail
  ) async -> DictationController {
    let settings = TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: "parakeet-local")
    let controller = DictationController(
      recorder: recorder,
      transcriber: transcriber,
      transcriberSettings: settings,
      llm: OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { nil })),
      llmSettings: LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: "test"),
      inserter: inserter,
      releaseTail: tail
    )
    // No LLM, no screen, clipboard or accessibility context in tests.
    await controller.updateLLMEnabled(false)
    await controller.updateScreenContextEnabled(false)
    await controller.updateClipboardContextEnabled(false)
    await controller.updateSelectedTextEnabled(false)
    await controller.updateActiveTextFieldEnabled(false)
    return controller
  }

  private func speech() -> [Float] { DictationAudioFixtures.sine(seconds: 0.5, rmsDBFS: -25) }

  @Test func recordingContinuesForTheReleaseTailThenProcessesOnce() async {
    let recorder = FakeRecorder(samples: speech())
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: transcriber, inserter: inserter)
    await controller.toggle(userPrompt: "")
    #expect(await controller.currentState() == .recording)

    let releasedAt = DictationClock.now()
    await controller.finish(userPrompt: "", trigger: DictationTriggerTimes(keyEvent: releasedAt, callback: releasedAt))

    let stopAt = try? #require(recorder.stopRequestedAt)
    #expect((stopAt ?? 0) - releasedAt >= DictationController.defaultReleaseTail - 0.005)
    #expect(await transcriber.calls == 1)
    #expect(inserter.inserted == ["hello world "])
    #expect(await controller.currentState() == .idle)
    if let url = recorder.recordingURL { try? FileManager.default.removeItem(at: url) }
  }

  @Test func cancelDuringTheTailStopsAtOnceAndInsertsNothing() async {
    let recorder = FakeRecorder(samples: speech())
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let controller = await makeController(
      recorder: recorder, transcriber: transcriber, inserter: inserter, tail: 1.0
    )
    await controller.toggle(userPrompt: "")
    let started = DictationClock.now()
    let stop = Task { await controller.finish(userPrompt: "") }
    try? await Task.sleep(nanoseconds: 100_000_000)
    await controller.cancel()
    await stop.value

    #expect(DictationClock.now() - started < 0.8, "cancel must not wait out the tail")
    #expect(await transcriber.calls == 0)
    #expect(inserter.inserted.isEmpty)
    #expect(await controller.currentState() == .idle)
    // The cancelled recording is discarded.
    #expect(recorder.stopCount == 1)
  }

  @Test func repeatedStopsFinaliseOnce() async {
    let recorder = FakeRecorder(samples: speech())
    let transcriber = FakeTranscriber(delayNanoseconds: 50_000_000)
    let inserter = FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: transcriber, inserter: inserter)
    await controller.toggle(userPrompt: "")

    async let first: Void = controller.finish(userPrompt: "")
    async let second: Void = controller.toggle(userPrompt: "")
    async let third: Void = controller.finish(userPrompt: "")
    _ = await (first, second, third)

    #expect(await transcriber.calls == 1)
    #expect(inserter.inserted.count == 1)
    #expect(recorder.stopCount == 1)
    if let url = recorder.recordingURL { try? FileManager.default.removeItem(at: url) }
  }

  @Test func silentClipIsNeitherTranscribedNorInserted() async {
    let recorder = FakeRecorder(samples: DictationAudioFixtures.silence(seconds: 1))
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: transcriber, inserter: inserter, tail: 0)
    await controller.toggle(userPrompt: "")
    await controller.finish(userPrompt: "")

    #expect(await transcriber.calls == 0)
    #expect(inserter.inserted.isEmpty)
    #expect(await controller.currentState() == .idle)
    // The backup recording is kept for recovery.
    let url = try? #require(recorder.recordingURL)
    #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    if let url { try? FileManager.default.removeItem(at: url) }
  }

  @Test func quietSpeechPassesTheSilenceGate() async {
    let recorder = FakeRecorder(samples: DictationAudioFixtures.sine(seconds: 1, rmsDBFS: -45))
    let transcriber = FakeTranscriber()
    let inserter = FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: transcriber, inserter: inserter, tail: 0)
    await controller.toggle(userPrompt: "")
    await controller.finish(userPrompt: "")
    #expect(await transcriber.calls == 1)
    #expect(inserter.inserted.count == 1)
    if let url = recorder.recordingURL { try? FileManager.default.removeItem(at: url) }
  }

  @Test func sessionConfigurationIsAppliedBeforeRecordingStarts() async {
    let recorder = FakeRecorder(samples: speech())
    let first = FakeTranscriber()
    let second = FakeTranscriber()
    let inserter = FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: first, inserter: inserter, tail: 0)
    let configuration = DictationConfiguration(
      transcriber: second,
      transcriberSettings: TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: "other"),
      llm: OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { nil })),
      llmSettings: LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: "test"),
      llmEnabled: false,
      screenContextEnabled: false,
      screenContextCaptureMode: .text,
      clipboardContextEnabled: false,
      selectedTextEnabled: false,
      activeTextFieldEnabled: false,
      screenImageEnabled: false,
      autoMuteEnabled: false
    )
    await controller.toggle(userPrompt: "", configuration: configuration)
    await controller.finish(userPrompt: "")
    #expect(await first.calls == 0)
    #expect(await second.calls == 1)
    if let url = recorder.recordingURL { try? FileManager.default.removeItem(at: url) }
  }
}
