import Foundation
#if canImport(FluidAudio)
import FluidAudio

/// Bark Clean's vocabulary boosting state for one loaded `AsrManager`.
///
/// `AsrManager` has no boosting of its own, so the session (CTC keyword spotting plus transcript
/// rescoring) lives here. `ParakeetBoostingCoordinator` keys its bookkeeping on this object and
/// only touches `session` under its lock, so configuration never interleaves with a decode.
actor ParakeetTdtBoostingSlot {
  nonisolated let manager: AsrManager
  private(set) var session: VocabularyBoostingSession?

  init(manager: AsrManager) {
    self.manager = manager
  }

  /// Nil turns boosting off.
  func setSession(_ session: VocabularyBoostingSession?) {
    self.session = session
  }
}
#endif
