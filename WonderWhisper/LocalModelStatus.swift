import Foundation

/// An on-device transcription model whose files Settings can download.
enum LocalTranscriptionModel: Hashable, Sendable {
  case parakeet(ParakeetModelKind)
  case qwen

  var displayName: String {
    switch self {
    case .parakeet(let kind): return kind.shortName
    case .qwen: return "Qwen3-ASR"
    }
  }
}

/// What the dictation Parakeet provider has in memory, published by the provider itself so
/// Settings never infers readiness from files on disk. `sequence` orders deliveries: the status
/// centre drops a snapshot older than the one it holds.
struct ParakeetRuntimeSnapshot: Equatable, Sendable {
  var sequence = 0
  /// The model a load is fetching files for (a dictation found them missing), if any, with the
  /// download fraction once FluidAudio reports one. Loading follows once the files are in.
  var downloading: ParakeetModelKind?
  var downloadProgress: Double?
  /// The model a load is running for, if any.
  var loading: ParakeetModelKind?
  /// The model loaded and usable right now, if any.
  var resident: ParakeetModelKind?
  /// The most recent load failure per model, cleared by that model's next successful load.
  var failures: [ParakeetModelKind: String] = [:]
}

/// What the shared Qwen runtime reports. `loadsStarted` is its load generation: a failure from a
/// load that started before a fresh download is not shown.
struct QwenRuntimeSnapshot: Equatable, Sendable {
  var loaded = false
  var health: QwenASRHealth = .unknown
  var loadsStarted = 0
}

/// The state Settings shows beside the selected on-device model.
enum LocalModelStatus: Equatable {
  case frameworkMissing
  case unsupported(String)
  case notDownloaded
  /// `progress` is nil until the download reports a fraction.
  case downloading(progress: Double?)
  case downloadFailed(String)
  /// Files are present but the model is not loaded (it loads in the background or on first use).
  case downloaded
  case loading
  case ready
  case loadFailed(String)

  /// Whether the Download / Retry control is offered.
  var offersDownload: Bool {
    switch self {
    case .notDownloaded, .downloadFailed, .loadFailed: return true
    case .frameworkMissing, .unsupported, .downloading, .downloaded, .loading, .ready: return false
    }
  }

  var isRetry: Bool {
    switch self {
    case .downloadFailed, .loadFailed: return true
    default: return false
    }
  }

  /// Resolves the status of one model. Order matters: an operation in flight wins over results,
  /// a model that is loaded wins over an older download failure, and files on disk never count
  /// as ready.
  static func resolve(
    model: LocalTranscriptionModel,
    isLinked: Bool,
    unsupportedReason: String? = nil,
    filesPresent: Bool,
    download: TranscriptionModelStatusCenter.DownloadOperation?,
    downloadFailure: String?,
    runtime: ParakeetRuntimeSnapshot,
    qwen: QwenRuntimeSnapshot = QwenRuntimeSnapshot()
  ) -> LocalModelStatus {
    guard isLinked else { return .frameworkMissing }
    if let unsupportedReason { return .unsupported(unsupportedReason) }
    if let download { return .downloading(progress: download.progress) }
    switch model {
    case .parakeet(let kind):
      if runtime.downloading == kind { return .downloading(progress: runtime.downloadProgress) }
      if runtime.loading == kind { return .loading }
      if runtime.resident == kind { return .ready }
      if let downloadFailure { return .downloadFailed(downloadFailure) }
      if let failure = runtime.failures[kind] { return .loadFailed(failure) }
    case .qwen:
      // Qwen loads in its own runtime when you dictate and unloads when idle.
      if qwen.health == .verifying { return .loading }
      if qwen.loaded { return .ready }
      if let downloadFailure { return .downloadFailed(downloadFailure) }
      if case .unhealthy(let reason) = qwen.health { return .loadFailed(reason) }
    }
    return filesPresent ? .downloaded : .notDownloaded
  }
}
