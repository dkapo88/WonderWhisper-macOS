import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Fallback selection

private final class StubProvider: TranscriptionProvider {
  let name: String
  init(name: String) { self.name = name }
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String { name }
}

/// The multilingual Parakeet model (v3, Ultra since the FluidAudio 0.17 bump).
private let multilingual = ParakeetModelKind.ultra

struct QwenFallbackTests {
  private let qwenSettings = TranscriptionSettings(
    endpoint: URL(string: "https://localhost")!,
    model: "qwen-local",
    timeout: 10,
    language: "en",
    vocabularyTerms: ["Hapana"],
    context: "hotkey"
  )

  @Test func prefersSelectedParakeetWhenDownloaded() {
    let choice = QwenASRFallback.choice(language: "en", selectedParakeet: .unified) { _ in true }
    #expect(choice == .parakeet(.unified))
  }

  @Test func usesAnyDownloadedParakeetWhenSelectedIsMissing() {
    let choice = QwenASRFallback.choice(language: "en", selectedParakeet: .unified) { $0 == multilingual }
    #expect(choice == .parakeet(multilingual))
  }

  @Test func fallsBackToGroqWithoutParakeet() {
    #expect(QwenASRFallback.choice(language: "en", selectedParakeet: .unified) { _ in false } == .groq)
  }

  /// Review finding 1: French with Unified selected and both models downloaded
  /// used to pick English-only Unified.
  @Test func nonEnglishSkipsEnglishOnlyParakeet() {
    for language in ["fr", "fr-FR", "de_DE", "pt-BR", "uk"] {
      let both = QwenASRFallback.choice(language: language, selectedParakeet: .unified) { _ in true }
      #expect(both == .parakeet(multilingual), "language \(language)")
      let onlyUnified = QwenASRFallback.choice(
        language: language, selectedParakeet: .unified
      ) { $0 == .unified }
      #expect(onlyUnified == .groq, "language \(language)")
    }
  }

  /// Bark Clean is English-only: non-English recovery skips it like Unified.
  @Test func nonEnglishSkipsBarkClean() {
    for language in ["fr", "de-DE", "es"] {
      let all = QwenASRFallback.choice(language: language, selectedParakeet: .barkClean) { _ in true }
      #expect(all == .parakeet(.ultra), "language \(language)")
      let onlyBark = QwenASRFallback.choice(
        language: language, selectedParakeet: .barkClean
      ) { $0 == .barkClean }
      #expect(onlyBark == .groq, "language \(language)")
    }
    let english = QwenASRFallback.choice(language: "en", selectedParakeet: .barkClean) { _ in true }
    #expect(english == .parakeet(.barkClean))
  }

  @Test func barkCleanRecoverySettingsNameTheModelTheProviderRuns() {
    let settings = QwenASRFallback.settings(for: .parakeet(.barkClean), from: qwenSettings)
    #expect(settings.model == "parakeet-bark-clean")
    #expect(ParakeetModelKind(modelIdentifier: settings.model) == .barkClean)
  }

  @Test func englishAndAutoKeepTheSelectedModel() {
    for language in ["en", "en-US", "auto", nil] as [String?] {
      let choice = QwenASRFallback.choice(language: language, selectedParakeet: .unified) { _ in true }
      #expect(choice == .parakeet(.unified), "language \(language ?? "nil")")
    }
  }

  @Test func englishOnlyCapabilityIsKindAgnostic() {
    #expect(ParakeetModelKind.unified.isEnglishOnly)
    #expect(ParakeetModelKind.barkClean.isEnglishOnly)
    #expect(ParakeetModelKind.allCases.filter(\.isEnglishOnly) == [.barkClean, .unified])
    #expect(ParakeetModelKind.barkClean.qwenFallbackLanguages == ["en"])
    #expect(!multilingual.qwenFallbackSupports(language: "ja"))
    #expect(!ParakeetModelKind.unified.qwenFallbackSupports(language: "ja"))
  }

  @Test func unsupportedLanguagesNeverChooseParakeet() {
    #expect(multilingual.qwenFallbackLanguages.count == 25)
    #expect(ParakeetModelKind.unified.qwenFallbackLanguages == ["en"])
    for language in ["zh", "zh-Hans", "ar", "ja", "th", "ko", "hi"] {
      for selected in ParakeetModelKind.allCases {
        #expect(QwenASRFallback.choice(language: language, selectedParakeet: selected) {
          _ in true
        } == .groq, "language \(language), selected \(selected)")
      }
    }
    for language in multilingual.qwenFallbackLanguages {
      #expect(multilingual.qwenFallbackSupports(language: language))
    }
  }

  @Test func autoUsesSelectedModelAndOnlySwitchesWhenMissing() {
    for language in ["auto", " AUTO ", "", nil] as [String?] {
      for selected in ParakeetModelKind.allCases {
        #expect(QwenASRFallback.choice(language: language, selectedParakeet: selected) {
          _ in true
        } == .parakeet(selected))
        let other = ParakeetModelKind.allCases.first { $0 != selected } ?? selected
        #expect(QwenASRFallback.choice(language: language, selectedParakeet: selected) {
          $0 == other
        } == .parakeet(other))
      }
    }
  }

  @Test func groqLanguageUsesISO6391AndAutoStaysAuto() {
    for (input, expected) in [("pt-BR", "pt"), ("zh-Hans", "zh"), ("de_DE", "de"),
                              ("auto", "auto"), ("", "auto")] {
      let settings = TranscriptionSettings(
        endpoint: qwenSettings.endpoint, model: "qwen-local", language: input
      )
      #expect(QwenASRFallback.settings(for: .groq, from: settings).language == expected)
    }
  }

  @Test func missingGroqKeyAndNoCompatibleModelThrowsWithoutReturningText() async {
    let choice = QwenASRFallback.choice(language: "zh-Hans", selectedParakeet: .unified) {
      _ in true
    }
    let noKey = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { nil }))
    let emptyKey = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { "  " }))
    for groq in [nil, MissingKeyProvider(), noKey, emptyKey] as [TranscriptionProvider?] {
      await #expect(throws: QwenFallbackError.unavailable) {
        _ = try await QwenASRFallback.transcribe(
          fileURL: URL(fileURLWithPath: "/dev/null"), choice: choice,
          settings: qwenSettings, groq: groq
        )
      }
    }
    let message = QwenFallbackError.unavailable.localizedDescription
    #expect(message.contains("Groq API key"))
    #expect(message.contains("Nothing was pasted"))
  }

  @Test func providerAndSettingsMatchChoice() async throws {
    let groq = StubProvider(name: "groq")
    let parakeet = StubProvider(name: "parakeet")
    let file = URL(fileURLWithPath: "/dev/null")

    let groqProvider = QwenASRFallback.provider(for: .groq, groq: groq) { parakeet }
    #expect(try await groqProvider?.transcribe(fileURL: file, settings: qwenSettings) == "groq")
    let groqSettings = QwenASRFallback.settings(for: .groq, from: qwenSettings)
    #expect(groqSettings.endpoint == AppConfig.groqAudioTranscriptions)
    #expect(groqSettings.model == AppConfig.defaultTranscriptionModel)
    #expect(groqSettings.language == "en")
    #expect(groqSettings.vocabularyTerms == ["Hapana"])

    let pkProvider = QwenASRFallback.provider(for: .parakeet(multilingual), groq: groq) { parakeet }
    #expect(try await pkProvider?.transcribe(fileURL: file, settings: qwenSettings) == "parakeet")
    let pkSettings = QwenASRFallback.settings(for: .parakeet(multilingual), from: qwenSettings)
    #expect(pkSettings.model == "parakeet-\(multilingual.rawValue)")
    #expect(pkSettings.language == "en")

    #expect(QwenASRFallback.provider(for: .groq, groq: nil) { parakeet } == nil)
  }

  @Test func onlyUnhealthyAndGarbageErrorsFallBack() {
    #expect(QwenASRError.unhealthy("x").shouldFallBack)
    #expect(QwenASRError.degenerateTranscript("x").shouldFallBack)
    #expect(!QwenASRError.modelNotDownloaded.shouldFallBack)
    #expect(!QwenASRError.emptyAudio.shouldFallBack)
  }
}

private final class MissingKeyProvider: TranscriptionProvider {
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    throw ProviderError.missingAPIKey
  }
}
