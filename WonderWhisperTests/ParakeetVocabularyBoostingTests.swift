import Foundation
import FluidAudio
import Testing
@testable import WonderWhisper

struct ParakeetVocabularyBoostingTests {
  @Test func ctcFolderKeepsCoremlSuffixAndMatchesFluidAudio() {
    #expect(ParakeetVocabularyBoosting.ctcFolderName == "parakeet-ctc-110m-coreml")
    #expect(ParakeetVocabularyBoosting.ctcFolderName == CtcModelVariant.ctc110m.repo.folderName)
    // VocabularyBoostingSession loads the CTC tokenizer from FluidAudio's
    // default cache directory, so ours must be the same folder.
    #expect(
      ParakeetVocabularyBoosting.ctcModelDirectory.standardizedFileURL
        == CtcModels.defaultCacheDirectory(for: .ctc110m).standardizedFileURL
    )
  }

  @Test func ctcRequiredFilesIncludeModelsVocabAndTokenizer() {
    #expect(
      Set(ParakeetVocabularyBoosting.ctcRequiredFiles)
        == ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "vocab.json", "tokenizer.json"]
    )
  }

  @Test func boostingIsOnByDefaultWhenVocabularyHasTerms() throws {
    let defaults = try #require(UserDefaults(suiteName: "ww-test-\(UUID().uuidString)"))
    #expect(ParakeetVocabularyBoosting.isEnabled(defaults: defaults))
    #expect(ParakeetVocabularyBoosting.currentTermsToBoost(defaults: defaults).isEmpty)

    defaults.set("Hapana, Niamh\nEzypay", forKey: "vocab.custom")
    defaults.set("jaron -> Jarron", forKey: "vocab.spelling")
    #expect(
      ParakeetVocabularyBoosting.currentTermsToBoost(defaults: defaults)
        == ["Hapana", "Niamh", "Ezypay", "Jarron"]
    )

    defaults.set(false, forKey: ParakeetVocabularyBoosting.enabledKey)
    #expect(!ParakeetVocabularyBoosting.isEnabled(defaults: defaults))
    #expect(ParakeetVocabularyBoosting.currentTermsToBoost(defaults: defaults).isEmpty)
  }

  @Test func boostingDecisionNeedsToggleAndUsableTerms() {
    #expect(ParakeetVocabularyBoosting.shouldBoost(enabled: true, terms: ["Hapana"]))
    #expect(!ParakeetVocabularyBoosting.shouldBoost(enabled: false, terms: ["Hapana"]))
    #expect(!ParakeetVocabularyBoosting.shouldBoost(enabled: true, terms: []))
    #expect(!ParakeetVocabularyBoosting.shouldBoost(enabled: true, terms: ["  ", "\n"]))
    #expect(ParakeetVocabularyBoosting.termsToBoost(enabled: true, terms: [" Biso ", ""]) == ["Biso"])
  }

  @Test func boostingUsesANewDefaultsKey() {
    let existingKeys = ["parakeet.version", "parakeet.raw.mode", "vocab.custom", "vocab.spelling",
                        "qwen.injectVocabulary"]
    #expect(ParakeetVocabularyBoosting.enabledKey == "parakeet.vocabularyBoosting.enabled")
    #expect(!existingKeys.contains(ParakeetVocabularyBoosting.enabledKey))
  }
}
