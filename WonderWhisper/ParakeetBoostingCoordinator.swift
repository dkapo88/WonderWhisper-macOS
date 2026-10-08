import Foundation

/// Serializes vocabulary-boosting configuration with inference for one kind of
/// ASR manager, so a vocabulary setting can never delay or break dictation.
///
/// - Configuration and inference never overlap: FluidAudio lets a configure
///   call complete while a decode on the same manager is suspended, which
///   could apply stale terms to the transcription in flight.
/// - Every request bumps a generation. Background preparation (warm-up) that
///   waited on the slow CTC load is discarded if anything newer ran, and it
///   re-reads preferences after the wait instead of using its snapshot.
/// - Turning boosting off on a boosted manager never reloads the ASR model on
///   the transcription path: the manager is neutralized (configured with an
///   empty vocabulary) and the caller may swap in an unboosted replacement in
///   the background.
///
/// Generic over the manager so the policy is testable without CoreML models.
actor ParakeetBoostingCoordinator<Manager: AnyObject & Sendable> {
  /// Configure `manager` with `terms`; empty terms neutralize boosting.
  typealias Configure = @Sendable (Manager, [String]) async throws -> Void
  /// Whether the CTC model is ready. `wait == false` must return immediately.
  typealias CtcReady = @Sendable (_ wait: Bool) async -> Bool

  enum Outcome: Equatable, Sendable {
    /// Boosting matches the request (including "off" on a fresh manager).
    case unchanged
    case configured([String])
    /// Was boosted, now configured empty. An unboosted replacement would
    /// avoid the leftover CTC pass.
    case neutralized
    /// The CTC model isn't ready, or configuring failed; inference runs as is.
    case skipped
    /// Superseded by a newer request.
    case stale
  }

  private let configure: Configure
  private let ctcReady: CtcReady
  private let log: @Sendable (String) -> Void
  /// Terms configured per manager. Absent = fresh (never configured);
  /// empty = neutralized; non-empty = boosted.
  private var configuredTerms: [ObjectIdentifier: [String]] = [:]
  private var generation = 0
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    configure: @escaping Configure,
    ctcReady: @escaping CtcReady,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.configure = configure
    self.ctcReady = ctcReady
    self.log = log
  }

  /// Terms currently configured on `manager` (nil = never configured).
  func configuredTerms(of manager: Manager) -> [String]? {
    configuredTerms[ObjectIdentifier(manager)]
  }

  /// Drop bookkeeping for a manager that is being released.
  func forget(_ manager: Manager) {
    configuredTerms.removeValue(forKey: ObjectIdentifier(manager))
  }

  /// Align boosting with `desired`, then run `inference` with no configuration
  /// able to interleave. Never waits on the CTC load and never throws for
  /// boosting reasons; only `inference` can throw.
  func run<T: Sendable>(
    on manager: Manager,
    desired: [String],
    inference: @Sendable () async throws -> T
  ) async throws -> (value: T, outcome: Outcome) {
    generation += 1
    await acquire()
    defer { release() }
    let outcome = await align(manager, desired: desired)
    let value = try await inference()
    return (value, outcome)
  }

  /// Background preparation (recording warm-up). May wait for the CTC model,
  /// but only applies if no newer request ran meanwhile, and re-reads
  /// `desired` after the wait.
  func prepare(
    _ manager: Manager,
    desired: @Sendable () -> [String]
  ) async -> Outcome {
    generation += 1
    let token = generation
    if !desired().isEmpty {
      _ = await ctcReady(true)
    }
    guard token == generation else { return .stale }
    await acquire()
    defer { release() }
    guard token == generation else { return .stale }
    return await align(manager, desired: desired())
  }

  /// Run `body` exclusively (no configuration or inference interleaves), e.g.
  /// to swap in a replacement manager.
  func exclusive<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
    await acquire()
    defer { release() }
    return await body()
  }

  // MARK: - Private

  private func align(_ manager: Manager, desired: [String]) async -> Outcome {
    let id = ObjectIdentifier(manager)
    let current = configuredTerms[id]
    if desired.isEmpty {
      // Fresh or already neutral: nothing to clear.
      guard let current, !current.isEmpty else { return .unchanged }
      do {
        try await configure(manager, [])
        configuredTerms[id] = []
        log("boosting off; neutralized without reloading ASR")
        return .neutralized
      } catch {
        // Can't clear in place: the next transcription keeps the old terms,
        // which is stale but never blocks or breaks dictation.
        log("neutralize failed: \(error.localizedDescription)")
        return .skipped
      }
    }
    guard desired != current else { return .unchanged }
    guard await ctcReady(false) else {
      log("CTC model not ready; transcribing without updating boosting")
      return .skipped
    }
    do {
      try await configure(manager, desired)
      configuredTerms[id] = desired
      return .configured(desired)
    } catch {
      log("configure failed; transcribing without updating boosting: \(error.localizedDescription)")
      return .skipped
    }
  }

  private func acquire() async {
    if !locked {
      locked = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      locked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
