import Foundation
import Testing
@testable import WonderWhisper

/// `DictationViewModel.selectTranscriptionChoice` and the sync paths keep `simple.voice.engine`
/// and `parakeet.version` coherent. Mostly synchronous, so no other main-actor test can
/// interleave with the shared scratch defaults mid-test.
@Suite(.serialized)
@MainActor
struct TranscriptionChoiceSelectionTests {
  static let engineKey = "simple.voice.engine"
  static let modelKey = ParakeetModelKind.defaultsKey
  static let keys = [
    engineKey, modelKey, ParakeetModelDefaults.pinnedDefaultKey,
    ParakeetModelDefaults.recommendationPendingKey, "transcription.model",
  ]

  private func makeViewModel(engine: SimpleVoiceEngine, model: String?) -> DictationViewModel {
    let defaults = AppConfig.defaults
    Self.keys.forEach { defaults.removeObject(forKey: $0) }
    defaults.set(engine.rawValue, forKey: Self.engineKey)
    if let model { defaults.set(model, forKey: Self.modelKey) }
    return DictationViewModel()
  }

  private func clean() { Self.keys.forEach { AppConfig.defaults.removeObject(forKey: $0) } }

  @Test func pickingAParakeetModelFromACloudEngineStoresBothAtOnce() {
    defer { clean() }
    let vm = makeViewModel(engine: .groqStreaming, model: nil)
    #expect(vm.transcriptionChoice == .engine(.groqStreaming))
    vm.selectTranscriptionChoice(.parakeet(.ultra))
    // Both values are stored and applied before anything can yield.
    #expect(AppConfig.defaults.string(forKey: Self.engineKey) == SimpleVoiceEngine.parakeetLocal.rawValue)
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == "ultra")
    #expect(vm.simpleVoiceEngine == .parakeetLocal)
    #expect(vm.transcriptionModel == "parakeet-local")
    #expect(vm.transcriptionChoice == .parakeet(.ultra))
    #expect(vm.sessionVoiceModel(for: nil).model == "parakeet-ultra")
  }

  @Test func pickingAnotherEngineKeepsTheParakeetModel() {
    defer { clean() }
    let vm = makeViewModel(engine: .parakeetLocal, model: "unified")
    vm.selectTranscriptionChoice(.engine(.sonioxStreaming))
    #expect(vm.simpleVoiceEngine == .sonioxStreaming)
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == "unified")
    #expect(vm.sessionVoiceModel(for: nil).model == "soniox-streaming")
    vm.selectTranscriptionChoice(.parakeet(.unified))
    #expect(vm.transcriptionChoice == .parakeet(.unified))
  }

  @Test func pickingTheCurrentChoiceWritesNothing() {
    defer { clean() }
    let vm = makeViewModel(engine: .parakeetLocal, model: nil)
    #expect(vm.transcriptionChoice == .parakeet(.barkClean))
    vm.selectTranscriptionChoice(.parakeet(.barkClean))
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == nil, "the unset default stays unset")
  }

  @Test func existingInstallPinIsShownButNeverMaterialised() {
    defer { clean() }
    let vm = makeViewModel(engine: .parakeetLocal, model: nil)
    AppConfig.defaults.set("unified", forKey: ParakeetModelDefaults.pinnedDefaultKey)
    #expect(vm.transcriptionChoice == .parakeet(.unified))
    #expect(vm.sessionVoiceModel(for: nil).model == "parakeet-unified")
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == nil)
  }

  @Test func useBarkCleanSelectsItEvenFromACloudEngine() {
    defer { clean() }
    let vm = makeViewModel(engine: .xaiSpeechToText, model: "unified")
    AppConfig.defaults.set(true, forKey: ParakeetModelDefaults.recommendationPendingKey)
    vm.selectTranscriptionChoice(.parakeet(.barkClean))
    #expect(vm.simpleVoiceEngine == .parakeetLocal)
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == "bark-clean")
    #expect(!ParakeetModelDefaults.isRecommendationPending())
  }

  @Test func dismissingTheRecommendationKeepsTheChoice() {
    defer { clean() }
    let vm = makeViewModel(engine: .groqStreaming, model: "unified")
    AppConfig.defaults.set(true, forKey: ParakeetModelDefaults.recommendationPendingKey)
    ParakeetModelDefaults.dismissRecommendation()
    #expect(vm.transcriptionChoice == .engine(.groqStreaming))
    #expect(AppConfig.defaults.string(forKey: Self.modelKey) == "unified")
  }

  @Test func explicitPromptVoiceOverrideKeepsItsOwnModel() throws {
    defer { clean() }
    let vm = makeViewModel(engine: .parakeetLocal, model: "bark-clean")
    var prompt = try #require(vm.prompts.first)
    prompt.voiceModelOverride = "parakeet-unified"
    let session = vm.sessionVoiceModel(for: prompt)
    #expect(session.model == "parakeet-unified")
    #expect(session.selectedParakeet == nil)
    // A cloud override stays cloud while the global choice is Parakeet.
    prompt.voiceModelOverride = "groq-streaming"
    #expect(vm.sessionVoiceModel(for: prompt).model == "groq-streaming")
    #expect(vm.sessionVoiceModel(for: nil).model == "parakeet-bark-clean")
  }

  @Test func remoteEngineOnlyModelOnlyAndResetUpdatesApplySeparately() {
    defer { clean() }
    let defaults = AppConfig.defaults
    let vm = makeViewModel(engine: .parakeetLocal, model: "unified")

    // Engine only.
    defaults.set(SimpleVoiceEngine.xaiSpeechToText.rawValue, forKey: Self.engineKey)
    vm.applySyncedSettings(changedKeys: [Self.engineKey])
    #expect(vm.simpleVoiceEngine == .xaiSpeechToText)
    #expect(defaults.string(forKey: Self.modelKey) == "unified")

    // Model only, while another engine is chosen: remembered for when Parakeet is picked.
    defaults.set("ultra", forKey: Self.modelKey)
    vm.applySyncedSettings(changedKeys: [Self.modelKey])
    #expect(vm.transcriptionChoice == .engine(.xaiSpeechToText))
    defaults.set(SimpleVoiceEngine.parakeetLocal.rawValue, forKey: Self.engineKey)
    vm.applySyncedSettings(changedKeys: [Self.engineKey])
    #expect(vm.transcriptionChoice == .parakeet(.ultra))

    // A received reset of the model: back to the default, still unset.
    defaults.removeObject(forKey: Self.modelKey)
    vm.applySyncedSettings(changedKeys: [Self.modelKey])
    #expect(vm.transcriptionChoice == .parakeet(.barkClean))
    #expect(defaults.string(forKey: Self.modelKey) == nil)
  }

  @Test func deferredHopsNeitherUndoAChoiceNorStampRemoteValuesAsEdits() async throws {
    defer { clean() }
    let defaults = AppConfig.defaults
    let vm = makeViewModel(engine: .groqStreaming, model: nil)
    vm.selectTranscriptionChoice(.parakeet(.ultra))
    // The engine didSet's deferred hop runs now and must find the work done.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(defaults.string(forKey: Self.engineKey) == SimpleVoiceEngine.parakeetLocal.rawValue)
    #expect(defaults.string(forKey: Self.modelKey) == "ultra")
    #expect(vm.transcriptionModel == "parakeet-local")

    // A received engine change: its deferred hop runs with remote provenance and writes nothing
    // back, so the Parakeet model it doesn't mention is untouched.
    defaults.set(SimpleVoiceEngine.groqStreaming.rawValue, forKey: Self.engineKey)
    vm.applySyncedSettings(changedKeys: [Self.engineKey])
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(vm.simpleVoiceEngine == .groqStreaming)
    #expect(defaults.string(forKey: Self.engineKey) == SimpleVoiceEngine.groqStreaming.rawValue)
    #expect(defaults.string(forKey: Self.modelKey) == "ultra")

    // A genuine edit right afterwards is stored at once.
    vm.selectTranscriptionChoice(.parakeet(.barkClean))
    #expect(defaults.string(forKey: Self.engineKey) == SimpleVoiceEngine.parakeetLocal.rawValue)
    #expect(defaults.string(forKey: Self.modelKey) == "bark-clean")
  }
}
