import Foundation

/// Bounds an await that must never strand a meeting in a non-terminal state.
///
/// A stalled provider handshake (for example a Soniox stream that closes without
/// emitting its `finished` signal) would otherwise suspend meeting finalization
/// forever, leaving the session at `.processing` with no in-app recovery.
enum MeetingFinalizationTimeout {
  struct Expired: Error {}

  /// Generous enough that a healthy but slow provider still finishes normally.
  static let finishSeconds: Double = 90

  static func run<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw Expired()
      }
      guard let result = try await group.next() else { throw Expired() }
      group.cancelAll()
      return result
    }
  }
}
