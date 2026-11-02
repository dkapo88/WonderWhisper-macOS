import Foundation

/// One entry in the transcription picker (Settings → Transcription and the menu bar). Purely a
/// presentation of two stored values: the engine (`simple.voiceEngine`) and, for Parakeet, the
/// model (`parakeet.version`). It adds no engine identity of its own.
enum TranscriptionChoice: Hashable, Identifiable {
  /// The on-device Parakeet engine running this model.
  case parakeet(ParakeetModelKind)
  /// Any other engine (never `.parakeetLocal`).
  case engine(SimpleVoiceEngine)

  /// On-device models first (Bark Clean, Unified, Ultra, Qwen when available), then cloud.
  static var available: [TranscriptionChoice] {
    ParakeetModelKind.allCases.map(TranscriptionChoice.parakeet)
      + SimpleVoiceEngine.availableEngines
      .filter { $0 != .parakeetLocal }
      .map(TranscriptionChoice.engine)
  }

  /// The choice the stored values select. Read-only: an unset `parakeet.version` resolves through
  /// the pinned or new-install default without being written.
  static func current(
    engine: SimpleVoiceEngine,
    storedParakeetVersion: String?,
    defaults: UserDefaults = AppConfig.defaults
  ) -> TranscriptionChoice {
    guard engine == .parakeetLocal else { return .engine(engine) }
    return .parakeet(ParakeetModelKind.resolved(stored: storedParakeetVersion, defaults: defaults))
  }

  var engine: SimpleVoiceEngine {
    switch self {
    case .parakeet: return .parakeetLocal
    case .engine(let engine): return engine
    }
  }

  var parakeetModel: ParakeetModelKind? {
    if case .parakeet(let kind) = self { return kind }
    return nil
  }

  /// The on-device model whose files this choice needs, if any.
  var localModel: LocalTranscriptionModel? {
    switch self {
    case .parakeet(let kind): return .parakeet(kind)
    case .engine(.qwenLocal): return .qwen
    case .engine: return nil
    }
  }

  /// Stable string form, e.g. for menu items: `parakeet:bark-clean`, `engine:groqStreaming`.
  var id: String {
    switch self {
    case .parakeet(let kind): return "parakeet:\(kind.rawValue)"
    case .engine(let engine): return "engine:\(engine.rawValue)"
    }
  }

  init?(id: String) {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "parakeet":
      guard let kind = ParakeetModelKind(rawValue: parts[1]) else { return nil }
      self = .parakeet(kind)
    case "engine":
      guard let engine = SimpleVoiceEngine(rawValue: parts[1]), engine != .parakeetLocal else {
        return nil
      }
      self = .engine(engine)
    default:
      return nil
    }
  }

  var displayName: String {
    switch self {
    case .parakeet(let kind): return kind.pickerName
    case .engine(let engine): return engine.displayName
    }
  }

  var detail: String {
    switch self {
    case .parakeet(let kind): return kind.detail
    case .engine(let engine): return engine.detail
    }
  }
}
