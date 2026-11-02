import Foundation
import Testing
@testable import WonderWhisper

/// The single transcription picker: a presentation of `simple.voice.engine` plus
/// `parakeet.version`, with no engine identity of its own.
struct TranscriptionChoiceTests {
  private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "ww-transcription-choice-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  @Test func localModelsComeFirstByNameAndEveryCloudEngineStays() {
    let choices = TranscriptionChoice.available
    #expect(Array(choices.prefix(3)) == [.parakeet(.barkClean), .parakeet(.unified), .parakeet(.ultra)])
    #expect(!choices.contains(.engine(.parakeetLocal)))
    let cloud: [SimpleVoiceEngine] = [
      .groqStreaming, .sonioxStreaming, .openRouterTranscription, .xaiSpeechToText,
      .xaiStreamingSpeechToText,
    ]
    for engine in cloud { #expect(choices.contains(.engine(engine))) }
    #expect(choices.contains(.engine(.qwenLocal)) == QwenASRManager.isRuntimeAvailable)
    if let qwen = choices.firstIndex(of: .engine(.qwenLocal)) {
      #expect(qwen == 3, "Qwen sits with the on-device models")
    }
    #expect(choices.filter { $0.localModel != nil }.count == (QwenASRManager.isRuntimeAvailable ? 4 : 3))
  }

  @Test func currentChoiceResolvesStoredValuesWithoutWriting() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    // New install: unset means Bark Clean.
    #expect(TranscriptionChoice.current(engine: .parakeetLocal, storedParakeetVersion: nil, defaults: defaults)
      == .parakeet(.barkClean))
    // Existing install pinned to its old default.
    defaults.set("unified", forKey: ParakeetModelDefaults.pinnedDefaultKey)
    #expect(TranscriptionChoice.current(engine: .parakeetLocal, storedParakeetVersion: nil, defaults: defaults)
      == .parakeet(.unified))
    // Legacy and unknown stored values keep their meaning.
    #expect(TranscriptionChoice.current(engine: .parakeetLocal, storedParakeetVersion: "v3", defaults: defaults)
      == .parakeet(.ultra))
    #expect(TranscriptionChoice.current(engine: .parakeetLocal, storedParakeetVersion: "v2", defaults: defaults)
      == .parakeet(.unified))
    #expect(TranscriptionChoice.current(engine: .parakeetLocal, storedParakeetVersion: "bark-clean", defaults: defaults)
      == .parakeet(.barkClean))
    // Other engines ignore the Parakeet model.
    #expect(TranscriptionChoice.current(engine: .groqStreaming, storedParakeetVersion: "ultra", defaults: defaults)
      == .engine(.groqStreaming))
    #expect(TranscriptionChoice.current(engine: .qwenLocal, storedParakeetVersion: nil, defaults: defaults)
      == .engine(.qwenLocal))
    // Reading never materialises the unset value or the pin into the synced key.
    #expect(defaults.string(forKey: ParakeetModelKind.defaultsKey) == nil)
  }

  @Test func choiceMapsToExistingEngineAndModelValues() {
    #expect(TranscriptionChoice.parakeet(.barkClean).engine == .parakeetLocal)
    #expect(TranscriptionChoice.parakeet(.ultra).parakeetModel == .ultra)
    #expect(TranscriptionChoice.engine(.groqStreaming).parakeetModel == nil)
    #expect(TranscriptionChoice.engine(.qwenLocal).localModel == .qwen)
    #expect(TranscriptionChoice.engine(.sonioxStreaming).localModel == nil)
    #expect(TranscriptionChoice.parakeet(.unified).localModel == .parakeet(.unified))
  }

  @Test func identifiersRoundTripAndRejectTheBareParakeetEngine() {
    for choice in TranscriptionChoice.available {
      #expect(TranscriptionChoice(id: choice.id) == choice)
    }
    #expect(TranscriptionChoice(id: "engine:parakeetLocal") == nil)
    #expect(TranscriptionChoice(id: "parakeet:v9") == nil)
    #expect(TranscriptionChoice(id: "nonsense") == nil)
  }

  @Test func sessionModelIdentifierNamesTheSelectedModelButKeepsExplicitOnes() {
    #expect(ParakeetModelKind.sessionModelIdentifier(for: "parakeet-local", selected: .barkClean)
      == "parakeet-bark-clean")
    #expect(ParakeetModelKind.sessionModelIdentifier(for: "parakeet-local", selected: .ultra)
      == "parakeet-ultra")
    #expect(ParakeetModelKind.sessionModelIdentifier(for: "parakeet-unified", selected: .barkClean)
      == "parakeet-unified")
    #expect(ParakeetModelKind.sessionModelIdentifier(for: "parakeet-v3", selected: .barkClean)
      == "parakeet-v3")
    for kind in ParakeetModelKind.allCases {
      #expect(ParakeetModelKind(modelIdentifier: kind.transcriptionModelIdentifier) == kind)
    }
  }

  @Test func effectiveModelMatchesTheProviderFallbackRule() {
    func effective(_ requested: ParakeetModelKind, installed: Set<ParakeetModelKind>, resident: Bool = false)
      -> ParakeetModelKind {
      ParakeetModelKind.effective(requested: requested, barkCleanResident: resident, isInstalled: installed.contains)
    }
    #expect(effective(.barkClean, installed: [.unified, .ultra]) == .unified)
    #expect(effective(.barkClean, installed: [.ultra]) == .ultra)
    #expect(effective(.barkClean, installed: []) == .barkClean)
    #expect(effective(.barkClean, installed: [.barkClean, .unified]) == .barkClean)
    #expect(effective(.barkClean, installed: [.unified], resident: true) == .barkClean)
    #expect(effective(.unified, installed: []) == .unified)
    #expect(effective(.ultra, installed: [.unified]) == .ultra)
  }
}
