import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Dictation residency: background load at selection, one coalesced prewarm, no late revival
/// after deselection or memory pressure, and key-down prewarm only after two idle minutes.
/// Fake loads and prewarms; no CoreML models.
struct ParakeetResidencyTests {
  actor Gate {
    private(set) var loads: [ParakeetModelKind] = []
    private(set) var prewarms: [ParakeetModelKind] = []
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() { held = true }
    func release() {
      held = false
      waiters.forEach { $0.resume() }
      waiters = []
    }

    func load(_ kind: ParakeetModelKind) async -> ParakeetTranscriptionProvider.LoadedBackend {
      loads.append(kind)
      if held { await withCheckedContinuation { waiters.append($0) } }
      switch kind {
      case .unified: return .unified(UnifiedAsrManager())
      case .ultra, .barkClean: return .tdt(AsrManager())
      }
    }

    func prewarm(_ kind: ParakeetModelKind) async {
      prewarms.append(kind)
      // Long enough that concurrent callers overlap and must coalesce.
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  private func makeProvider(_ gate: Gate) -> ParakeetTranscriptionProvider {
    ParakeetTranscriptionProvider(
      residency: .whileSelected,
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      isInstalled: { _ in true },
      // Independent of the shared scratch defaults other suites may be writing.
      selectedModel: { ParakeetModelKind.newInstallDefault },
      backendLoader: { kind in await gate.load(kind) },
      prewarmRunner: { kind in await gate.prewarm(kind) }
    )
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2_000 where !(await condition()) {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  @Test func selectingLoadsInTheBackgroundAndPrewarmsOnce() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    #expect(await gate.loads == [ParakeetModelKind.newInstallDefault])
    #expect(await gate.prewarms == [ParakeetModelKind.newInstallDefault])
    #expect(await provider.isResident())
    #expect(await provider.lastInferenceAt != nil)
  }

  @Test func coalescesConcurrentSelectionsWhileLoading() async {
    let gate = Gate()
    await gate.hold()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await waitUntil { await gate.loads.count == 1 }
    await provider.setSelected(true)
    async let warm: Void = provider.warmUp()
    try? await Task.sleep(nanoseconds: 10_000_000)
    await gate.release()
    await warm
    await provider.waitForBackgroundWorkForTesting()
    #expect(await gate.loads == [ParakeetModelKind.newInstallDefault])
    #expect(await gate.prewarms == [ParakeetModelKind.newInstallDefault])
  }

  @Test func aLateLoadNeverBringsBackADeselectedEngine() async {
    let gate = Gate()
    await gate.hold()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await waitUntil { await gate.loads.count == 1 }
    await provider.setSelected(false)
    await gate.release()
    await provider.waitForBackgroundWorkForTesting()
    #expect(await !provider.isResident())
    #expect(await provider.loadedKindForTesting == nil)
    #expect(await gate.prewarms.isEmpty)
  }

  @Test func memoryPressureUnloadsAndALateLoadStaysUnloaded() async {
    let gate = Gate()
    await gate.hold()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await waitUntil { await gate.loads.count == 1 }
    await provider.handleMemoryPressure()
    await gate.release()
    await provider.waitForBackgroundWorkForTesting()
    #expect(await !provider.isResident())
    #expect(await gate.prewarms.isEmpty)
    // Re-selecting under memory pressure does not reload; the next dictation does.
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    #expect(await gate.loads.count == 1)
    await provider.warmUp()
    #expect(await provider.isResident())
  }

  @Test func aKeyDownLoadAfterMemoryPressureStaysUnloadedWhenDeselectedMeanwhile() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    await provider.handleMemoryPressure()
    #expect(await !provider.isResident())

    await gate.hold()
    let warm = Task { await provider.warmUp() }
    await waitUntil { await gate.loads.count == 2 }
    await provider.setSelected(false)
    await gate.release()
    await warm.value
    await provider.waitForBackgroundWorkForTesting()
    #expect(await !provider.isResident())
    #expect(await gate.prewarms.count == 1, "only the launch prewarm")
  }

  @Test func aWarmUpQueuedAfterDeselectionDoesNotLoad() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    await provider.handleMemoryPressure()
    await provider.setSelected(false)
    await provider.warmUp()
    await provider.waitForBackgroundWorkForTesting()
    #expect(await !provider.isResident())
    #expect(await gate.loads.count == 1)
  }

  @Test func aWarmUpRequestedBeforeAMemoryPressureUnloadDoesNotReload() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    let requestedBeforeUnload = DictationClock.now()
    try? await Task.sleep(nanoseconds: 2_000_000)
    await provider.handleMemoryPressure()
    await provider.warmUp(requestedAt: requestedBeforeUnload)
    #expect(await !provider.isResident())
    #expect(await gate.loads.count == 1)
    // The next dictation after the unload loads it again.
    await provider.warmUp(requestedAt: DictationClock.now())
    #expect(await provider.isResident())
    #expect(await gate.loads.count == 2)
  }

  @Test func deselectingUnloads() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    #expect(await provider.isResident())
    await provider.setSelected(false)
    #expect(await !provider.isResident())
  }

  @Test func keyDownPrewarmsOnlyAfterTwoIdleMinutes() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    #expect(await gate.prewarms.count == 1)

    // Ran recently: key-down does not prewarm.
    await provider.setLastInferenceForTesting(DictationClock.now() - 119)
    await provider.warmUp()
    #expect(await gate.prewarms.count == 1)

    // Idle for more than two minutes: key-down prewarms alongside capture.
    await provider.setLastInferenceForTesting(DictationClock.now() - 121)
    await provider.warmUp()
    #expect(await gate.prewarms.count == 2)

    // Never ran: prewarm.
    await provider.setLastInferenceForTesting(nil)
    await provider.warmUp()
    #expect(await gate.prewarms.count == 3)
    #expect(await gate.loads == [ParakeetModelKind.newInstallDefault])
  }

  @Test func concurrentPrewarmsAreCoalesced() async {
    let gate = Gate()
    let provider = makeProvider(gate)
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    async let a: Void = provider.prewarmForTesting()
    async let b: Void = provider.prewarmForTesting()
    _ = await (a, b)
    #expect(await gate.prewarms.count == 2)
  }

  @Test func idleUnloadProvidersIgnoreSelection() async {
    let gate = Gate()
    let provider = ParakeetTranscriptionProvider(
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      isInstalled: { _ in true },
      // Independent of the shared scratch defaults other suites may be writing.
      selectedModel: { ParakeetModelKind.newInstallDefault },
      backendLoader: { kind in await gate.load(kind) },
      prewarmRunner: { kind in await gate.prewarm(kind) }
    )
    await provider.setSelected(true)
    await provider.waitForBackgroundWorkForTesting()
    #expect(await gate.loads.isEmpty)
  }
}
