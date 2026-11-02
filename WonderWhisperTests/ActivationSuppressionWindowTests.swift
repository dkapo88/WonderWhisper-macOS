import Foundation
import Testing
@testable import WonderWhisper

/// The hotkey suppression window armed around synthetic paste. It used to keep a `Date` and
/// compare it with `<=`, which crashed the released app on pre-release macOS 27.2.
struct ActivationSuppressionWindowTests {
  /// A clock the test moves by hand.
  final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
    var now: TimeInterval {
      lock.lock(); defer { lock.unlock() }
      return value
    }
    func set(_ newValue: TimeInterval) {
      lock.lock(); value = newValue; lock.unlock()
    }
  }

  private func window(_ clock: ManualClock) -> ActivationSuppressionWindow {
    ActivationSuppressionWindow(now: { clock.now })
  }

  @Test func unsetWindowIsInactive() {
    let clock = ManualClock(100)
    #expect(!window(clock).isActive)
  }

  @Test func windowIsActiveBeforeTheDeadline() {
    let clock = ManualClock(100)
    let window = window(clock)
    window.suppress(for: 0.35)
    #expect(window.isActive)
    clock.set(100.349)
    #expect(window.isActive)
  }

  @Test func windowExpiresExactlyAtTheDeadline() {
    let clock = ManualClock(100)
    let window = window(clock)
    window.suppress(for: 0.5)
    clock.set(100.5)
    #expect(!window.isActive)
  }

  @Test func expiredWindowStaysClearedWhenTheClockIsReadAgain() {
    let clock = ManualClock(100)
    let window = window(clock)
    window.suppress(for: 0.35)
    clock.set(200)
    #expect(!window.isActive)
    // Cleared on expiry: a clock reading from before the deadline can't revive it.
    clock.set(100.1)
    #expect(!window.isActive)
  }

  @Test func repeatedSuppressionReplacesTheDeadline() {
    let clock = ManualClock(100)
    let window = window(clock)
    window.suppress(for: 0.35)
    clock.set(100.3)
    window.suppress(for: 0.35)
    clock.set(100.6)
    #expect(window.isActive)
    clock.set(100.65)
    #expect(!window.isActive)
    window.suppress(for: 0.35)
    #expect(window.isActive)
  }

  @Test func zeroOrNegativeDurationNeverSuppresses() {
    let clock = ManualClock(100)
    let window = window(clock)
    window.suppress(for: 0)
    #expect(!window.isActive)
    window.suppress(for: -1)
    #expect(!window.isActive)
  }

  @Test func concurrentArmingAndReadingIsSafe() async {
    let window = ActivationSuppressionWindow()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          for step in 0..<2_000 {
            if (index + step) % 5 == 0 {
              window.suppress(for: 0.35)
            } else {
              _ = window.isActive
            }
          }
        }
      }
    }
    // The last arm was moments ago on the real uptime clock.
    #expect(window.isActive)
  }

  /// The released crash: the first read after arming the shared window (a synthetic paste,
  /// then a modifier event) crashed. This runs the shipping static path. Expiry is covered with
  /// the manual clock above: other suites may arm the shared window concurrently.
  @Test func sharedHotkeySuppressionArmsWithoutCrashing() {
    HotkeyManager.suppressActivation(for: 0.2)
    #expect(HotkeyManager.isActivationSuppressed)
  }
}
