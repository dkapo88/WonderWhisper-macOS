import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Regression for review round 3: an older load caller resuming late must not
/// clear a newer registered load, or the next request starts a duplicate,
/// concurrent backend load. Exercises the real `ensureModelsLoaded`
/// interleaving with gated fake loads (no CoreML models).
struct ParakeetLoadCoalescingTests {
  actor LoadGate {
    private(set) var started: [ParakeetModelKind] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private var held: [ParakeetModelKind: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<ParakeetModelKind> = []

    func load(_ kind: ParakeetModelKind) async -> ParakeetTranscriptionProvider.LoadedBackend {
      started.append(kind)
      inFlight += 1
      maxInFlight = max(maxInFlight, inFlight)
      if !released.contains(kind) {
        await withCheckedContinuation { held[kind, default: []].append($0) }
      }
      inFlight -= 1
      switch kind {
      case .unified: return .unified(UnifiedAsrManager())
      case .ultra: return .ultra(AsrManager())
      }
    }

    func release(_ kind: ParakeetModelKind) {
      released.insert(kind)
      held.removeValue(forKey: kind)?.forEach { $0.resume() }
    }
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<1_000 where !(await condition()) {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  @Test func overlappingUnifiedAndUltraRequestsNeverDuplicateOrOverlapLoads() async throws {
    for _ in 0..<30 {
      let gate = LoadGate()
      let provider = ParakeetTranscriptionProvider(
        boostingEnabled: { false },
        vocabularyTerms: { [] },
        backendLoader: { kind in await gate.load(kind) }
      )

      // 1. A Unified warm-up is loading.
      let warmUp = Task { try await provider.ensureModelsLoadedForTesting(.unified) }
      await waitUntil { await gate.started.count == 1 }

      // 2. The user switches to Ultra (e.g. reprocessing history) mid-load.
      let reprocess = Task { try await provider.ensureModelsLoadedForTesting(.ultra) }
      try await Task.sleep(nanoseconds: 5_000_000)

      // 3/4. Unified finishes; the Ultra waiter registers its load and the
      // original Unified caller resumes. It must not erase the Ultra load.
      await gate.release(.unified)
      try await warmUp.value
      await waitUntil { await gate.started.count == 2 }

      // 5. The next Ultra request must await the in-flight load.
      let next = Task { try await provider.ensureModelsLoadedForTesting(.ultra) }
      try await Task.sleep(nanoseconds: 5_000_000)
      #expect(await gate.started == [.unified, .ultra], "duplicate load started")

      await gate.release(.ultra)
      try await reprocess.value
      try await next.value

      #expect(await gate.started == [.unified, .ultra])
      #expect(await gate.maxInFlight == 1)
      #expect(await provider.loadedKindForTesting == .ultra)
    }
  }

  @Test func aFailedLoadOfTheOtherKindDoesNotFailTheWaiter() async throws {
    struct LoadFailed: Error {}
    final class Attempts: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      func next() -> Int { lock.withLock { count += 1; return count } }
    }
    let attempts = Attempts()
    let provider = ParakeetTranscriptionProvider(
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      backendLoader: { kind in
        // First (Unified) load fails after a beat; the Ultra load succeeds.
        if attempts.next() == 1 {
          try await Task.sleep(nanoseconds: 20_000_000)
          throw LoadFailed()
        }
        return kind == .unified ? .unified(UnifiedAsrManager()) : .ultra(AsrManager())
      }
    )
    let unified = Task { try await provider.ensureModelsLoadedForTesting(.unified) }
    try await Task.sleep(nanoseconds: 5_000_000)
    try await provider.ensureModelsLoadedForTesting(.ultra)
    #expect(await provider.loadedKindForTesting == .ultra)
    await #expect(throws: LoadFailed.self) { try await unified.value }
  }
}
