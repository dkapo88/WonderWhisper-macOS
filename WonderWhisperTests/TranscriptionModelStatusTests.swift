import Foundation
import Testing
@testable import WonderWhisper

/// Settings' model status comes from runtime state per model and per operation, never from
/// files on disk alone. Uses a fake downloader and fake file presence, so nothing real loads.
@MainActor
@Suite(.serialized)
struct TranscriptionModelStatusTests {
  /// Holds each fake download open until the test finishes it.
  final class DownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [LocalTranscriptionModel: CheckedContinuation<Void, Error>] = [:]
    private var progress: [LocalTranscriptionModel: @Sendable (Double) -> Void] = [:]
    private(set) var forced: [LocalTranscriptionModel: Bool] = [:]

    func run(
      _ model: LocalTranscriptionModel, force: Bool, report: @escaping @Sendable (Double) -> Void
    ) async throws {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          waiting[model] = continuation
          progress[model] = report
          forced[model] = force
        }
      }
    }

    func isWaiting(_ model: LocalTranscriptionModel) -> Bool { lock.withLock { waiting[model] != nil } }
    func report(_ model: LocalTranscriptionModel, _ fraction: Double) {
      let handler = lock.withLock { progress[model] }
      handler?(fraction)
    }
    func finish(_ model: LocalTranscriptionModel, error: Error? = nil) {
      let continuation = lock.withLock { waiting.removeValue(forKey: model) }
      if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
  }

  final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var present: Set<LocalTranscriptionModel> = []
    func set(_ model: LocalTranscriptionModel, _ isPresent: Bool) {
      lock.withLock { if isPresent { present.insert(model) } else { present.remove(model) } }
    }
    func contains(_ model: LocalTranscriptionModel) -> Bool { lock.withLock { present.contains(model) } }
  }

  struct DownloadError: LocalizedError {
    var errorDescription: String? { "network down" }
  }

  private func makeCenter(gate: DownloadGate, disk: Disk) -> TranscriptionModelStatusCenter {
    TranscriptionModelStatusCenter(
      downloader: { model, force, report in
        try await gate.run(model, force: force, report: report)
        disk.set(model, true)
      },
      filesPresent: { disk.contains($0) }
    )
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private let bark = LocalTranscriptionModel.parakeet(.barkClean)
  private let unified = LocalTranscriptionModel.parakeet(.unified)
  private let ultra = LocalTranscriptionModel.parakeet(.ultra)

  @Test func missingModelOffersDownloadAndDownloadingIsReportedWithProgress() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    #expect(center.status(for: bark) == .notDownloaded)
    #expect(center.status(for: bark).offersDownload)

    var finished: [LocalTranscriptionModel] = []
    center.onDownloadFinished = { finished.append($0) }
    center.download(bark)
    #expect(center.status(for: bark) == .downloading(progress: nil))
    #expect(!center.status(for: bark).offersDownload)
    await waitUntil { gate.isWaiting(bark) }
    gate.report(bark, 0.4)
    await waitUntil { center.status(for: bark) == .downloading(progress: 0.4) }
    #expect(center.status(for: bark) == .downloading(progress: 0.4))

    gate.finish(bark)
    await waitUntil { center.status(for: bark) == .downloaded }
    // Files present but not loaded is "downloaded", never "ready".
    #expect(center.status(for: bark) == .downloaded)
    #expect(finished == [bark])
  }

  @Test func switchingModelsDuringADownloadNeverRelabelsAnotherModel() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    center.download(bark)
    await waitUntil { gate.isWaiting(bark) }
    // The user switches to Unified: its own state shows, not Bark's download.
    #expect(center.status(for: unified) == .notDownloaded)
    center.download(unified)
    await waitUntil { gate.isWaiting(unified) }
    gate.report(unified, 0.9)
    gate.finish(bark)
    await waitUntil { center.status(for: bark) == .downloaded }
    #expect(center.status(for: unified) == .downloading(progress: 0.9))
    // A late progress report for the finished Bark operation changes nothing.
    gate.report(bark, 0.1)
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(center.status(for: bark) == .downloaded)
    gate.finish(unified)
    await waitUntil { center.status(for: unified) == .downloaded }
    #expect(center.status(for: ultra) == .notDownloaded)
  }

  @Test func failedDownloadOffersRetryAndRetryClearsTheFailure() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    center.download(ultra)
    await waitUntil { gate.isWaiting(ultra) }
    gate.finish(ultra, error: DownloadError())
    await waitUntil { center.status(for: ultra) == .downloadFailed("network down") }
    #expect(center.status(for: ultra).isRetry)
    center.download(ultra)
    #expect(center.status(for: ultra) == .downloading(progress: nil))
    #expect(gate.forced[ultra] == false, "a download failure re-runs a normal download")
    await waitUntil { gate.isWaiting(ultra) }
    gate.finish(ultra)
    await waitUntil { center.status(for: ultra) == .downloaded }
  }

  @Test func runtimeSnapshotsDriveLoadingReadyAndLoadFailurePerModel() {
    let center = makeCenter(gate: DownloadGate(), disk: Disk())
    center.apply(ParakeetRuntimeSnapshot(sequence: 1, loading: .barkClean))
    #expect(center.status(for: bark) == .loading)
    #expect(center.status(for: unified) == .notDownloaded)
    center.apply(ParakeetRuntimeSnapshot(sequence: 2, resident: .barkClean))
    #expect(center.status(for: bark) == .ready)
    // A late, older delivery never overwrites newer state.
    center.apply(ParakeetRuntimeSnapshot(sequence: 1, loading: .barkClean))
    #expect(center.status(for: bark) == .ready)
    center.apply(ParakeetRuntimeSnapshot(sequence: 3, failures: [.unified: "bad model"]))
    #expect(center.status(for: unified) == .loadFailed("bad model"))
    #expect(center.status(for: bark) == .notDownloaded)
  }

  @Test func corruptPresentFilesShowTheLoadFailureAndRetryForcesARefetch() async {
    let gate = DownloadGate(), disk = Disk()
    disk.set(bark, true)
    let center = makeCenter(gate: gate, disk: disk)
    #expect(center.status(for: bark) == .downloaded)
    center.apply(ParakeetRuntimeSnapshot(sequence: 4, failures: [.barkClean: "corrupt weights"]))
    #expect(center.status(for: bark) == .loadFailed("corrupt weights"))
    #expect(center.status(for: bark).isRetry)

    center.download(bark)
    await waitUntil { gate.isWaiting(bark) }
    #expect(gate.forced[bark] == true)
    gate.finish(bark)
    // Fresh files hide the old failure until the provider reports again.
    await waitUntil { center.status(for: bark) == .downloaded }
    #expect(center.status(for: bark) == .downloaded)
    center.apply(ParakeetRuntimeSnapshot(sequence: 5, loading: .barkClean))
    #expect(center.status(for: bark) == .loading)
    center.apply(ParakeetRuntimeSnapshot(sequence: 6, failures: [.barkClean: "still corrupt"]))
    #expect(center.status(for: bark) == .loadFailed("still corrupt"))
  }

  @Test func missingBarkCleanNamesItsFallbackOrNone() {
    let disk = Disk()
    let center = makeCenter(gate: DownloadGate(), disk: disk)
    #expect(center.fallback(for: .barkClean) == nil, "nothing downloaded: Bark downloads on first use")
    disk.set(ultra, true)
    #expect(center.fallback(for: .barkClean) == .ultra)
    disk.set(unified, true)
    #expect(center.fallback(for: .barkClean) == .unified)
    #expect(center.fallback(for: .unified) == nil)
    #expect(center.fallback(for: .ultra) == nil)
    // Resident from an earlier load (files since removed): Bark itself runs.
    center.apply(ParakeetRuntimeSnapshot(sequence: 1, resident: .barkClean))
    #expect(center.fallback(for: .barkClean) == nil)
    disk.set(bark, true)
    center.apply(ParakeetRuntimeSnapshot(sequence: 2))
    #expect(center.fallback(for: .barkClean) == nil)
  }

  @Test func aDictationThatDownloadsTheModelShowsDownloadingThenLoading() {
    let center = makeCenter(gate: DownloadGate(), disk: Disk())
    center.apply(ParakeetRuntimeSnapshot(sequence: 1, downloading: .barkClean, loading: .barkClean))
    #expect(center.status(for: bark) == .downloading(progress: nil))
    center.apply(ParakeetRuntimeSnapshot(sequence: 2, downloading: .barkClean, downloadProgress: 0.5,
                                         loading: .barkClean))
    #expect(center.status(for: bark) == .downloading(progress: 0.5))
    #expect(center.status(for: unified) == .notDownloaded)
    center.apply(ParakeetRuntimeSnapshot(sequence: 3, loading: .barkClean))
    #expect(center.status(for: bark) == .loading)
  }

  @Test func aLaterSuccessfulLoadSupersedesAnOldDownloadFailure() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    center.download(bark)
    await waitUntil { gate.isWaiting(bark) }
    gate.finish(bark, error: DownloadError())
    await waitUntil { center.status(for: bark) == .downloadFailed("network down") }
    // Connectivity returns; a dictation downloads and loads Bark Clean itself.
    center.apply(ParakeetRuntimeSnapshot(sequence: 1, downloading: .barkClean, loading: .barkClean))
    #expect(center.status(for: bark) == .downloading(progress: nil))
    disk.set(bark, true)
    center.apply(ParakeetRuntimeSnapshot(sequence: 2, resident: .barkClean))
    #expect(center.status(for: bark) == .ready)
    // Unloaded later (memory pressure): downloaded, not the stale failure.
    center.apply(ParakeetRuntimeSnapshot(sequence: 3))
    #expect(center.status(for: bark) == .downloaded)
  }

  @Test func qwenStateComesFromItsRuntimeWithGenerationAwareFailures() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    guard TranscriptionModelStatusCenter.isLinked(.qwen),
          TranscriptionModelStatusCenter.unsupportedReason(.qwen) == nil else { return }
    #expect(center.status(for: .qwen) == .notDownloaded)
    disk.set(.qwen, true)
    #expect(center.status(for: .qwen) == .downloaded)
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .verifying, loadsStarted: 1))
    #expect(center.status(for: .qwen) == .loading)
    center.apply(QwenRuntimeSnapshot(loaded: true, health: .healthy, loadsStarted: 1))
    #expect(center.status(for: .qwen) == .ready)
    // A Parakeet snapshot never touches Qwen.
    center.apply(ParakeetRuntimeSnapshot(sequence: 9, loading: .unified))
    #expect(center.status(for: .qwen) == .ready)

    // Corrupt weights: verification fails and the engine unloads.
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .unhealthy("canary mismatch"), loadsStarted: 2))
    #expect(center.status(for: .qwen) == .loadFailed("canary mismatch"))
    center.download(.qwen)
    await waitUntil { gate.isWaiting(.qwen) }
    #expect(gate.forced[.qwen] == true, "Retry after a failed load refetches the weights")
    gate.finish(.qwen)
    // Fresh weights hide the failure from the old load generation.
    await waitUntil { center.status(for: .qwen) == .downloaded }
    #expect(center.status(for: .qwen) == .downloaded)
    // The reload verifies them; a new failure (newer generation) shows again.
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .unhealthy("still bad"), loadsStarted: 3))
    #expect(center.status(for: .qwen) == .loadFailed("still bad"))
  }

  @Test func qwenDownloadFailureClearsOnceItLoads() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    guard TranscriptionModelStatusCenter.isLinked(.qwen),
          TranscriptionModelStatusCenter.unsupportedReason(.qwen) == nil else { return }
    center.download(.qwen)
    await waitUntil { gate.isWaiting(.qwen) }
    gate.finish(.qwen, error: DownloadError())
    await waitUntil { center.status(for: .qwen) == .downloadFailed("network down") }
    disk.set(.qwen, true)
    center.apply(QwenRuntimeSnapshot(loaded: true, health: .healthy, loadsStarted: 1))
    #expect(center.status(for: .qwen) == .ready)
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .healthy, loadsStarted: 1))
    #expect(center.status(for: .qwen) == .downloaded)
  }

  @Test func aHealthyQwenLoadSupersedesADownloadFailureEvenAfterItUnloads() async {
    let gate = DownloadGate(), disk = Disk()
    let center = makeCenter(gate: gate, disk: disk)
    guard TranscriptionModelStatusCenter.isLinked(.qwen),
          TranscriptionModelStatusCenter.unsupportedReason(.qwen) == nil else { return }
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .unknown, loadsStarted: 2))
    center.download(.qwen)
    await waitUntil { gate.isWaiting(.qwen) }
    gate.finish(.qwen, error: DownloadError())
    await waitUntil { center.status(for: .qwen) == .downloadFailed("network down") }
    // The same generation still healthy from before: not a newer load.
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .healthy, loadsStarted: 2))
    #expect(center.status(for: .qwen) == .downloadFailed("network down"))
    // Weights arrive another way; a dictation loads them while Settings is closed, and the engine
    // has unloaded by the time Settings reads the runtime again.
    disk.set(.qwen, true)
    center.apply(QwenRuntimeSnapshot(loaded: false, health: .healthy, loadsStarted: 3))
    #expect(center.status(for: .qwen) == .downloaded)
  }
}
