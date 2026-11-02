import Foundation
import Testing
@testable import WonderWhisper

/// A configuration (engine, model, prompt) that arrives while a dictation is in progress applies
/// to the next dictation, never to the one finishing.
@Suite(.serialized)
struct DictationControllerConfigurationTests {
  typealias Session = DictationControllerSessionTests

  actor NamedTranscriber: TranscriptionProvider {
    let text: String
    private(set) var models: [String] = []
    init(_ text: String) { self.text = text }
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
      models.append(settings.model)
      return text
    }
  }

  private func settings(_ model: String) -> TranscriptionSettings {
    TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: model)
  }

  private func configuration(_ transcriber: NamedTranscriber, model: String) -> DictationConfiguration {
    DictationConfiguration(
      transcriber: transcriber,
      transcriberSettings: settings(model),
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
  }

  private func makeController(
    recorder: Session.FakeRecorder, transcriber: NamedTranscriber, inserter: Session.FakeInserter
  ) async -> DictationController {
    let controller = DictationController(
      recorder: recorder,
      transcriber: transcriber,
      transcriberSettings: settings("parakeet-bark-clean"),
      llm: OpenRouterLLMProvider(client: OpenRouterHTTPClient(apiKeyProvider: { nil })),
      llmSettings: LLMSettings(endpoint: AppConfig.openrouterChatCompletions, model: "test"),
      inserter: inserter,
      releaseTail: 0
    )
    await controller.updateLLMEnabled(false)
    await controller.updateScreenContextEnabled(false)
    await controller.updateClipboardContextEnabled(false)
    await controller.updateSelectedTextEnabled(false)
    await controller.updateActiveTextFieldEnabled(false)
    return controller
  }

  private func speech() -> [Float] { DictationAudioFixtures.sine(seconds: 0.5, rmsDBFS: -25) }

  @Test func aChangeDuringRecordingAppliesToTheNextDictation() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let bark = NamedTranscriber("from bark")
    let unified = NamedTranscriber("from unified")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: bark, inserter: inserter)

    await controller.toggle(userPrompt: "", configuration: configuration(bark, model: "parakeet-bark-clean"))
    #expect(await controller.currentState() == .recording)
    // The picker changes mid-recording.
    await controller.apply(configuration(unified, model: "parakeet-unified"))
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["from bark "])
    #expect(await bark.models == ["parakeet-bark-clean"])
    #expect(await unified.models.isEmpty)

    // Back to idle, the deferred change is what the next dictation uses.
    for _ in 0..<50 where await controller.currentState() != .idle {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    await controller.toggle(userPrompt: "")
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["from bark ", "from unified "])
    #expect(await unified.models == ["parakeet-unified"])
  }

  @Test func aStartConfigurationSupersedesADeferredOne() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let first = NamedTranscriber("first")
    let stale = NamedTranscriber("stale")
    let fresh = NamedTranscriber("fresh")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: first, inserter: inserter)

    await controller.toggle(userPrompt: "")
    await controller.apply(configuration(stale, model: "parakeet-ultra"))
    await controller.finish(userPrompt: "")
    await controller.toggle(userPrompt: "", configuration: configuration(fresh, model: "parakeet-unified"))
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["first ", "fresh "])
    #expect(await stale.models.isEmpty)
  }

  @Test func aSessionPromptOverrideAppliesNowButKeepsTheSessionTranscriber() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let bark = NamedTranscriber("from bark")
    let other = NamedTranscriber("from other")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: bark, inserter: inserter)
    await controller.toggle(userPrompt: "", configuration: configuration(bark, model: "parakeet-bark-clean"))
    // A selected-text prompt chosen at stop, built after the picker moved to another model.
    var override = configuration(other, model: "parakeet-unified")
    override.screenImageEnabled = true
    await controller.applySessionOverride(override, replacingTranscriber: false)
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["from bark "])
    #expect(await bark.models == ["parakeet-bark-clean"])
    #expect(await other.models.isEmpty)
  }

  @Test func aSessionPromptWithItsOwnVoiceModelReplacesTheTranscriber() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let bark = NamedTranscriber("from bark")
    let groq = NamedTranscriber("from groq")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: bark, inserter: inserter)
    await controller.toggle(userPrompt: "", configuration: configuration(bark, model: "parakeet-bark-clean"))
    await controller.applySessionOverride(configuration(groq, model: "groq-streaming"), replacingTranscriber: true)
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["from groq "])
    #expect(await groq.models == ["groq-streaming"])
  }

  @Test func aSessionPromptOverrideKeepsTheSessionAutoMuteState() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let bark = NamedTranscriber("from bark")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: bark, inserter: inserter)
    var start = configuration(bark, model: "parakeet-bark-clean")
    start.autoMuteEnabled = true
    await controller.toggle(userPrompt: "", configuration: start)
    // Settings turned auto-mute off mid-recording; the override built from them must not stop
    // this session restoring what it muted.
    await controller.applySessionOverride(configuration(bark, model: "parakeet-bark-clean"), replacingTranscriber: false)
    #expect(await controller.autoMuteEnabledForTesting)
    await controller.cancel()
  }

  @Test func aSessionPromptNamingAStreamingEngineKeepsTheSessionTranscriber() async {
    let recorder = Session.FakeRecorder(samples: speech())
    let bark = NamedTranscriber("from bark")
    let inserter = Session.FakeInserter()
    let controller = await makeController(recorder: recorder, transcriber: bark, inserter: inserter)
    await controller.toggle(userPrompt: "", configuration: configuration(bark, model: "parakeet-bark-clean"))
    var override = configuration(bark, model: "soniox-streaming")
    override.transcriber = SonioxStreamingProvider(apiKeyProvider: { nil })
    await controller.applySessionOverride(override, replacingTranscriber: true)
    await controller.finish(userPrompt: "")
    #expect(inserter.inserted == ["from bark "])
    #expect(await bark.models == ["parakeet-bark-clean"])
  }
}
