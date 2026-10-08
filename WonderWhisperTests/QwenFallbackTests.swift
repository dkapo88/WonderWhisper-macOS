import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Fallback selection

private final class StubProvider: TranscriptionProvider {
  let name: String
  init(name: String) { self.name = name }
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String { name }
}

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
    let choice = QwenASRFallback.choice(selectedParakeet: .unified) { _ in true }
    #expect(choice == .parakeet(.unified))
  }

  @Test func usesAnyDownloadedParakeetWhenSelectedIsMissing() {
    let choice = QwenASRFallback.choice(selectedParakeet: .unified) { $0 == .v3 }
    #expect(choice == .parakeet(.v3))
  }

  @Test func fallsBackToGroqWithoutParakeet() {
    #expect(QwenASRFallback.choice(selectedParakeet: .unified) { _ in false } == .groq)
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

    let pkProvider = QwenASRFallback.provider(for: .parakeet(.v3), groq: groq) { parakeet }
    #expect(try await pkProvider?.transcribe(fileURL: file, settings: qwenSettings) == "parakeet")
    let pkSettings = QwenASRFallback.settings(for: .parakeet(.v3), from: qwenSettings)
    #expect(pkSettings.model == "parakeet-v3")
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
