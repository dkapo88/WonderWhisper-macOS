import Foundation
import Combine
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Owns the runtime state Settings shows for on-device transcription models: each model's
/// download operation and failure, the dictation Parakeet provider's loaded/loading/failed
/// models, and whether Qwen is loaded. Owned by `DictationViewModel`, so it outlives the
/// Settings window: reopening Settings shows a download still in flight.
@MainActor
final class TranscriptionModelStatusCenter: ObservableObject {
  struct DownloadOperation: Equatable {
    let id: UUID
    var progress: Double?
  }

  /// Runs one model download. Reports progress fractions; throws on failure. `force`
  /// re-fetches files that are present but failed to load.
  typealias Downloader = @Sendable (
    _ model: LocalTranscriptionModel,
    _ force: Bool,
    _ progress: @escaping @Sendable (Double) -> Void
  ) async throws -> Void

  @Published private(set) var downloads: [LocalTranscriptionModel: DownloadOperation] = [:]
  @Published private(set) var downloadFailures: [LocalTranscriptionModel: String] = [:]
  @Published private(set) var parakeetRuntime = ParakeetRuntimeSnapshot()
  @Published private(set) var qwenRuntime = QwenRuntimeSnapshot()
  /// Bumped when files may have changed on disk, so views re-read presence.
  @Published private(set) var diskRevision = 0

  /// Called on the main actor after a model's files finished downloading.
  var onDownloadFinished: ((LocalTranscriptionModel) -> Void)?

  private let downloader: Downloader
  private let filesPresent: (LocalTranscriptionModel) -> Bool
  /// Per model, the runtime sequence at which a fresh download superseded an old load failure.
  private var failureMaskedThrough: [ParakeetModelKind: Int] = [:]
  /// The Qwen load generation a fresh download superseded, likewise.
  private var qwenFailureMaskedThrough: Int?
  /// The Qwen load generation when its last download failed: a healthy load started after it
  /// supersedes that failure, even once the engine has unloaded again.
  private var qwenDownloadFailedAtGeneration: Int?

  init(
    downloader: @escaping Downloader = TranscriptionModelStatusCenter.liveDownload,
    filesPresent: @escaping (LocalTranscriptionModel) -> Bool = TranscriptionModelStatusCenter.liveFilesPresent
  ) {
    self.downloader = downloader
    self.filesPresent = filesPresent
  }

  // MARK: - Status

  func status(for model: LocalTranscriptionModel) -> LocalModelStatus {
    LocalModelStatus.resolve(
      model: model,
      isLinked: Self.isLinked(model),
      unsupportedReason: Self.unsupportedReason(model),
      filesPresent: filesPresent(model),
      download: downloads[model],
      downloadFailure: downloadFailures[model],
      runtime: visibleRuntime(for: model),
      qwen: visibleQwenRuntime
    )
  }

  /// For a selected Parakeet model, the model dictation will actually run (a downloaded stand-in
  /// for a missing Bark Clean), or nil when that is the selected model itself.
  func fallback(for kind: ParakeetModelKind) -> ParakeetModelKind? {
    let effective = ParakeetModelKind.effective(
      requested: kind,
      barkCleanResident: parakeetRuntime.resident == .barkClean,
      isInstalled: { self.filesPresent(.parakeet($0)) }
    )
    return effective == kind ? nil : effective
  }

  /// The runtime snapshot with a load failure hidden once a later download replaced the files.
  private func visibleRuntime(for model: LocalTranscriptionModel) -> ParakeetRuntimeSnapshot {
    guard case .parakeet(let kind) = model,
          let masked = failureMaskedThrough[kind],
          parakeetRuntime.sequence <= masked else { return parakeetRuntime }
    var runtime = parakeetRuntime
    runtime.failures[kind] = nil
    return runtime
  }

  /// Qwen's state with a failure from a load older than a fresh download hidden.
  private var visibleQwenRuntime: QwenRuntimeSnapshot {
    guard let masked = qwenFailureMaskedThrough, qwenRuntime.loadsStarted <= masked,
          case .unhealthy = qwenRuntime.health else { return qwenRuntime }
    var runtime = qwenRuntime
    runtime.health = .unknown
    return runtime
  }

  // MARK: - Runtime updates

  /// A snapshot from the dictation provider. Older deliveries never overwrite newer ones. A model
  /// that loaded since supersedes its older download failure (a dictation fetched it).
  func apply(_ snapshot: ParakeetRuntimeSnapshot) {
    guard snapshot.sequence > parakeetRuntime.sequence else { return }
    parakeetRuntime = snapshot
    if let resident = snapshot.resident, downloadFailures[.parakeet(resident)] != nil {
      downloadFailures[.parakeet(resident)] = nil
    }
  }

  /// What the shared Qwen runtime reports (read while Settings shows Qwen).
  func apply(_ snapshot: QwenRuntimeSnapshot) {
    guard snapshot != qwenRuntime else { return }
    qwenRuntime = snapshot
    guard downloadFailures[.qwen] != nil else { return }
    let loadedSinceFailure = snapshot.health == .healthy
      && snapshot.loadsStarted > (qwenDownloadFailedAtGeneration ?? -1)
    if snapshot.loaded || loadedSinceFailure { downloadFailures[.qwen] = nil }
  }

  func refreshDisk() { diskRevision += 1 }

  // MARK: - Downloads

  /// Starts downloading `model` unless it is already downloading. Each model has its own
  /// operation, so switching the selection mid-download never relabels another model.
  func download(_ model: LocalTranscriptionModel) {
    guard downloads[model] == nil, Self.isLinked(model), Self.unsupportedReason(model) == nil else {
      return
    }
    let force: Bool
    if case .loadFailed = status(for: model) { force = true } else { force = false }
    let operation = DownloadOperation(id: UUID(), progress: nil)
    downloads[model] = operation
    downloadFailures[model] = nil
    let downloader = self.downloader
    let id = operation.id
    // Strong captures: a download is finite, and the centre lives as long as the view model.
    Task {
      let progress: @Sendable (Double) -> Void = { fraction in
        Task { @MainActor in self.updateProgress(model, id: id, fraction: fraction) }
      }
      let failure: String?
      do {
        try await downloader(model, force, progress)
        failure = nil
      } catch {
        failure = (error as NSError).localizedDescription
        AppLog.dictation.error("[Models] \(model.displayName) download failed: \(failure ?? "")")
      }
      self.finishDownload(model, id: id, failure: failure)
    }
  }

  private func updateProgress(_ model: LocalTranscriptionModel, id: UUID, fraction: Double) {
    guard downloads[model]?.id == id else { return }
    downloads[model]?.progress = max(0, min(1, fraction))
  }

  private func finishDownload(_ model: LocalTranscriptionModel, id: UUID, failure: String?) {
    // A completion for an operation that is no longer current changes nothing.
    guard downloads[model]?.id == id else { return }
    downloads[model] = nil
    diskRevision += 1
    if let failure {
      downloadFailures[model] = failure
      if model == .qwen { qwenDownloadFailedAtGeneration = qwenRuntime.loadsStarted }
      return
    }
    switch model {
    case .parakeet(let kind): failureMaskedThrough[kind] = parakeetRuntime.sequence
    case .qwen: qwenFailureMaskedThrough = qwenRuntime.loadsStarted
    }
    onDownloadFinished?(model)
  }

  // MARK: - Live environment

  static func isLinked(_ model: LocalTranscriptionModel) -> Bool {
    switch model {
    case .parakeet: return ParakeetManager.isLinked
    case .qwen: return QwenASRManager.isLinked
    }
  }

  static func unsupportedReason(_ model: LocalTranscriptionModel) -> String? {
    if case .qwen = model, !QwenASRManager.isAppleSilicon { return "Requires Apple Silicon" }
    return nil
  }

  nonisolated static func liveFilesPresent(_ model: LocalTranscriptionModel) -> Bool {
    switch model {
    case .parakeet(let kind): return ParakeetManager.modelsPresent(for: kind)
    case .qwen: return QwenASRManager.modelsPresent()
    }
  }

  nonisolated static let liveDownload: Downloader = { model, force, progress in
    switch model {
    case .parakeet(let kind):
      #if canImport(FluidAudio)
      let handler: ProgressHandler = { progress($0.fractionCompleted) }
      if let version = kind.tdtVersion {
        // Download only; the provider loads it.
        _ = try await AsrModels.download(
          to: ParakeetManager.modelDirectory(for: kind),
          force: force,
          version: version,
          progressHandler: handler
        )
      } else {
        // Unified's loader checks every file and purges and re-fetches a cache that fails to load.
        try await UnifiedAsrManager().loadModels(
          to: ParakeetManager.modelsDirectory,
          progressHandler: handler
        )
      }
      #else
      throw ProviderError.notImplemented
      #endif
    case .qwen:
      #if canImport(Qwen3ASR)
      if force, let installed = QwenASRManager.installedModelDirectory() {
        // Weights that are present but fail verification: move them to the Bin and fetch again.
        try FileManager.default.trashItem(at: installed, resultingItemURL: nil)
      }
      try await QwenASRManager.downloadModel { fraction, _ in progress(fraction) }
      #else
      throw QwenASRError.frameworkMissing
      #endif
    }
  }
}
