import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Regression for review round 2, finding 2: the background unboosted
/// replacement must never reinstall Unified after a backend switch, and must
/// recheck identity, backend and preferences at the moment it commits.
/// `UnifiedAsrManager()` without `loadModels` is cheap, so no models load here.
struct ParakeetReplacementSwapTests {
  private func provider(enabled: Bool = false, terms: [String] = []) -> ParakeetTranscriptionProvider {
    ParakeetTranscriptionProvider(boostingEnabled: { enabled }, vocabularyTerms: { terms })
  }

  @Test func swapAfterSwitchingToUltraDoesNotReinstallUnified() async {
    let provider = provider()
    let old = UnifiedAsrManager()
    await provider.installUnifiedForTesting(old)

    // The user switches to Ultra while the replacement is still loading.
    await provider.simulateSwitchToUltraForTesting()
    let swapped = await provider.commitReplacement(old: old, fresh: UnifiedAsrManager(), oldIsNeutral: true)

    #expect(!swapped)
    #expect(await provider.residentUnifiedManagerForTesting == nil)
  }

  @Test func swapCommitsWhenStillUnifiedNeutralAndOff() async {
    let provider = provider()
    let old = UnifiedAsrManager()
    let fresh = UnifiedAsrManager()
    await provider.installUnifiedForTesting(old)

    #expect(await provider.commitReplacement(old: old, fresh: fresh, oldIsNeutral: true))
    #expect(await provider.residentUnifiedManagerForTesting === fresh)
  }

  @Test func swapIsRefusedWhenAnythingChanged() async {
    let old = UnifiedAsrManager()

    // Boosting turned back on with a non-empty Vocabulary.
    let reenabled = provider(enabled: true, terms: ["Hapana"])
    await reenabled.installUnifiedForTesting(old)
    #expect(!(await reenabled.commitReplacement(old: old, fresh: UnifiedAsrManager(), oldIsNeutral: true)))
    #expect(await reenabled.residentUnifiedManagerForTesting === old)

    // A different Unified manager is resident now.
    let replaced = provider()
    let other = UnifiedAsrManager()
    await replaced.installUnifiedForTesting(other)
    #expect(!(await replaced.commitReplacement(old: old, fresh: UnifiedAsrManager(), oldIsNeutral: true)))
    #expect(await replaced.residentUnifiedManagerForTesting === other)

    // The old manager was re-boosted (no longer neutral).
    let reboosted = provider()
    await reboosted.installUnifiedForTesting(old)
    #expect(!(await reboosted.commitReplacement(old: old, fresh: UnifiedAsrManager(), oldIsNeutral: false)))
    #expect(await reboosted.residentUnifiedManagerForTesting === old)
  }
}
