import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// The dictation provider publishes what it is downloading, loading, holding and failing, per
/// model, so Settings never guesses from files on disk.
struct ParakeetRuntimeSnapshotTests {
  final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ParakeetRuntimeSnapshot] = []
    func append(_ snapshot: ParakeetRuntimeSnapshot) { lock.withLock { all.append(snapshot) } }
    var values: [ParakeetRuntimeSnapshot] { lock.withLock { all } }
  }

  struct LoadFailed: LocalizedError {
    var errorDescription: String? { "model failed to compile" }
  }

  @Test func aLoadThatFetchesMissingFilesReportsDownloadingThenResident() async throws {
    let snapshots = Snapshots()
    let gate = ParakeetResidencyTests.Gate()
    let provider = ParakeetTranscriptionProvider(
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      isInstalled: { _ in false },
      selectedModel: { .barkClean },
      backendLoader: { kind in await gate.load(kind) }
    )
    await provider.setRuntimeObserver { snapshots.append($0) }
    await gate.hold()
    let load = Task { try await provider.ensureModelsLoadedForTesting(.barkClean) }
    for _ in 0..<200 where !snapshots.values.contains(where: { $0.downloading == .barkClean }) {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let during = try #require(snapshots.values.last)
    #expect(during.downloading == .barkClean)
    #expect(during.loading == .barkClean)
    #expect(during.resident == nil)
    await gate.release()
    try await load.value

    let final = try #require(snapshots.values.last)
    #expect(final.downloading == nil)
    #expect(final.loading == nil)
    #expect(final.resident == .barkClean)
    let sequences = snapshots.values.map(\.sequence)
    #expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count)
  }

  @Test func aFailedLoadIsReportedForThatModelAndClearedByItsNextLoad() async throws {
    let snapshots = Snapshots()
    let attempts = ParakeetLoadCoalescingAttempts()
    let provider = ParakeetTranscriptionProvider(
      boostingEnabled: { false },
      vocabularyTerms: { [] },
      isInstalled: { _ in true },
      backendLoader: { kind in
        if attempts.next() == 1 { throw LoadFailed() }
        return kind == .unified ? .unified(UnifiedAsrManager()) : .tdt(AsrManager())
      }
    )
    await provider.setRuntimeObserver { snapshots.append($0) }
    await #expect(throws: LoadFailed.self) { try await provider.ensureModelsLoadedForTesting(.ultra) }
    var last = try #require(snapshots.values.last)
    #expect(last.failures == [.ultra: "model failed to compile"])
    #expect(last.resident == nil)

    try await provider.ensureModelsLoadedForTesting(.ultra)
    last = try #require(snapshots.values.last)
    #expect(last.failures.isEmpty)
    #expect(last.resident == .ultra)
  }
}

/// Counts load attempts across a provider's loads.
final class ParakeetLoadCoalescingAttempts: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int { lock.withLock { count += 1; return count } }
}
