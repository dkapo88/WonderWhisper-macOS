import Foundation

/// A short window during which hotkey activation is ignored, e.g. while the app posts its own
/// synthetic paste. The deadline is a scalar on the uptime clock (`DictationClock.now`), which
/// is monotonic and unaffected by wall-clock changes; the window is transient, never stored.
///
/// Thread-safe: event-tap callbacks read it on the main thread while insertion arms it from
/// whatever thread posts the paste. Each read samples the clock once.
final class ActivationSuppressionWindow: @unchecked Sendable {
  private let lock = NSLock()
  private var deadline: TimeInterval?
  private let now: @Sendable () -> TimeInterval

  init(now: @escaping @Sendable () -> TimeInterval = { DictationClock.now() }) {
    self.now = now
  }

  /// Suppresses activation for `duration` seconds from now, replacing any earlier window.
  func suppress(for duration: TimeInterval) {
    let deadline = now() + duration
    lock.lock()
    self.deadline = deadline
    lock.unlock()
  }

  /// True until the deadline. At the deadline itself the window has expired, and it is cleared.
  var isActive: Bool {
    let current = now()
    lock.lock()
    defer { lock.unlock() }
    guard let deadline else { return false }
    if deadline > current { return true }
    self.deadline = nil
    return false
  }
}
