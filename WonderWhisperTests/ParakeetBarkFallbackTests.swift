import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Bark Clean selected but not downloaded: dictation runs a downloaded local model (Unified, then
/// Ultra), says so once, and never waits on a download. Fake loads; no CoreML models.
struct ParakeetBarkFallbackTests {
  actor Recorder {
    private(set) var loads: [ParakeetModelKind] = []
    private(set) var notices: [String] = []

    func load(_ kind: ParakeetModelKind) -> ParakeetTranscriptionProvider.LoadedBackend {
      loads.append(kind)
      return kind == .unified ? .unified(UnifiedAsrManager()) : .tdt(AsrManager())
    }

    func notice(_ selected: ParakeetModelKind, _ used: ParakeetModelKind) {
      notices.append("\(selected.rawValue)->\(used.rawValue)")
    }
  }

  private func settings(_ model: String) -> TranscriptionSettings {
    TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: model, language: "en")
  }

  private func provider(
    _ recorder: Recorder,
    installed: Set<ParakeetModelKind>
  ) -> ParakeetTranscriptionProvider {
    ParakeetTranscriptionProvider(
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      isInstalled: { installed.contains($0) },
      backendLoader: { kind in await recorder.load(kind) }
    )
  }

  @Test func missingBarkCleanUsesDownloadedUnifiedThenUltra() async {
    let recorder = Recorder()
    let bark = settings("parakeet-bark-clean")
    #expect(await provider(recorder, installed: [.unified, .ultra]).effectiveKindForTesting(bark) == .unified)
    #expect(await provider(recorder, installed: [.ultra]).effectiveKindForTesting(bark) == .ultra)
    #expect(await provider(recorder, installed: [.barkClean, .unified]).effectiveKindForTesting(bark) == .barkClean)
    // Nothing downloaded: Bark Clean downloads on demand, as Unified used to on a fresh install.
    #expect(await provider(recorder, installed: []).effectiveKindForTesting(bark) == .barkClean)
  }

  @Test func otherSelectionsNeverFallBack() async {
    let recorder = Recorder()
    let none = provider(recorder, installed: [])
    #expect(await none.effectiveKindForTesting(settings("parakeet-unified")) == .unified)
    #expect(await none.effectiveKindForTesting(settings("parakeet-ultra")) == .ultra)
  }

  @Test func fallbackLoadsTheStandInAndNoticesOnce() async {
    let recorder = Recorder()
    let parakeet = provider(recorder, installed: [.unified])
    await parakeet.setOnModelFallback { selected, used in await recorder.notice(selected, used) }
    let missing = URL(fileURLWithPath: "/nonexistent/ww-bark-fallback.wav")
    for _ in 0..<2 {
      // The fake manager can't decode; only the model choice and the notice matter here.
      _ = try? await parakeet.transcribe(fileURL: missing, settings: settings("parakeet-bark-clean"))
    }
    #expect(await recorder.loads == [.unified])
    #expect(await recorder.notices == ["bark-clean->unified"])
    #expect(await parakeet.loadedKindForTesting == .unified)
  }

  @Test func switchingBetweenUltraAndBarkCleanReplacesTheTdtModel() async throws {
    let recorder = Recorder()
    let parakeet = provider(recorder, installed: [.barkClean, .ultra, .unified])
    try await parakeet.ensureModelsLoadedForTesting(.ultra)
    try await parakeet.ensureModelsLoadedForTesting(.barkClean)
    try await parakeet.ensureModelsLoadedForTesting(.barkClean)
    #expect(await recorder.loads == [.ultra, .barkClean])
    #expect(await parakeet.loadedKindForTesting == .barkClean)
    #expect(await parakeet.isResident(for: settings("parakeet-bark-clean")))
    #expect(!(await parakeet.isResident(for: settings("parakeet-ultra"))))
  }
}
