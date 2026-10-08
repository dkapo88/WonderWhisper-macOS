import Foundation
import Testing
@testable import WonderWhisper

/// Regression tests for review findings P1 and P2 on vocabulary boosting.
struct ParakeetBoostingCoordinatorTests {
  /// Stand-in for UnifiedAsrManager: records configuration and catches any
  /// configuration that lands while inference is running.
  final class FakeManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _history: [[String]] = []
    private var _inferring = false
    private var _overlap = false
    var failConfigure = false

    var history: [[String]] { lock.withLock { _history } }
    var overlapDetected: Bool { lock.withLock { _overlap } }

    func configure(_ terms: [String]) throws {
      struct Failed: Error {}
      if failConfigure { throw Failed() }
      lock.withLock {
        if _inferring { _overlap = true }
        _history.append(terms)
      }
    }

    func infer(sleepMs: UInt64 = 0) async -> String {
      lock.withLock { _inferring = true }
      if sleepMs > 0 { try? await Task.sleep(nanoseconds: sleepMs * 1_000_000) }
      lock.withLock { _inferring = false }
      return "text"
    }
  }

  /// Thread-safe mutable value standing in for user preferences.
  final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
      get { lock.withLock { _value } }
      set { lock.withLock { _value = newValue } }
    }
  }

  /// Controls the CTC model: ready or not, and a slow load that can be held.
  actor CtcGate {
    var ready = true
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    private(set) var waitingLoads = 0

    func hold() { holding = true }
    func setReady(_ value: Bool) { ready = value }
    func load(wait: Bool) async -> Bool {
      if wait && holding {
        waitingLoads += 1
        await withCheckedContinuation { held.append($0) }
      }
      return ready
    }
    func releaseAll() {
      holding = false
      held.forEach { $0.resume() }
      held.removeAll()
    }
  }

  private func makeCoordinator(gate: CtcGate) -> ParakeetBoostingCoordinator<FakeManager> {
    ParakeetBoostingCoordinator<FakeManager>(
      configure: { manager, terms in try manager.configure(terms) },
      ctcReady: { wait in await gate.load(wait: wait) }
    )
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<500 where !(await condition()) {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
  }

  // MARK: - P1: turning boosting off never reloads or fails dictation

  @Test func disablingAfterBoostNeutralizesInPlaceWithoutReload() async throws {
    let gate = CtcGate()
    let coordinator = makeCoordinator(gate: gate)
    let manager = FakeManager()

    let first = try await coordinator.run(on: manager, desired: ["Hapana"]) { await manager.infer() }
    #expect(first.outcome == .configured(["Hapana"]))

    // Off (toggle or emptied Vocabulary): same manager, configured empty, and
    // the transcription runs right away. There is no reload path at all.
    let second = try await coordinator.run(on: manager, desired: []) { await manager.infer() }
    #expect(second.value == "text")
    #expect(second.outcome == .neutralized)
    #expect(manager.history == [["Hapana"], []])
    #expect(await coordinator.configuredTerms(of: manager) == [])

    // Already neutral: nothing more to do.
    let third = try await coordinator.run(on: manager, desired: []) { await manager.infer() }
    #expect(third.outcome == .unchanged)
    #expect(manager.history.count == 2)
  }

  @Test func boostingFailuresNeverFailTheTranscription() async throws {
    let gate = CtcGate()
    let coordinator = makeCoordinator(gate: gate)
    let manager = FakeManager()
    _ = try await coordinator.run(on: manager, desired: ["Hapana"]) { await manager.infer() }

    manager.failConfigure = true
    let off = try await coordinator.run(on: manager, desired: []) { await manager.infer() }
    #expect(off.value == "text")
    #expect(off.outcome == .skipped)

    await gate.setReady(false)
    let fresh = FakeManager()
    let notReady = try await coordinator.run(on: fresh, desired: ["Biso"]) { await fresh.infer() }
    #expect(notReady.value == "text")
    #expect(notReady.outcome == .skipped)
    #expect(fresh.history.isEmpty)
  }

  @Test func offOnAFreshManagerAddsNoConfiguration() async throws {
    let coordinator = makeCoordinator(gate: CtcGate())
    let manager = FakeManager()
    let result = try await coordinator.run(on: manager, desired: []) { await manager.infer() }
    #expect(result.outcome == .unchanged)
    #expect(manager.history.isEmpty)
  }

  // MARK: - P2: stale warm-up configuration

  /// The reviewer's repro: warm-up captured ["OLD"] and waited on the CTC
  /// load; meanwhile boosting was disabled, the Vocabulary cleared and an
  /// unboosted transcription ran. The warm-up must not configure ["OLD"].
  @Test func warmUpSupersededWhileWaitingOnCtcDoesNotApplyOldTerms() async throws {
    let gate = CtcGate()
    await gate.hold()
    let coordinator = makeCoordinator(gate: gate)
    let manager = FakeManager()
    let preferences = Box(["OLD"])

    let warmUp = Task { await coordinator.prepare(manager) { preferences.value } }
    await waitUntil { await gate.waitingLoads == 1 }

    preferences.value = []
    let dictation = try await coordinator.run(on: manager, desired: []) { await manager.infer() }
    #expect(dictation.outcome == .unchanged)

    await gate.releaseAll()
    #expect(await warmUp.value == .stale)
    #expect(manager.history.isEmpty)
    #expect(await coordinator.configuredTerms(of: manager) == nil)
  }

  @Test func warmUpRereadsPreferencesAfterTheCtcWait() async {
    let gate = CtcGate()
    await gate.hold()
    let coordinator = makeCoordinator(gate: gate)
    let manager = FakeManager()
    let preferences = Box(["OLD"])

    let warmUp = Task { await coordinator.prepare(manager) { preferences.value } }
    await waitUntil { await gate.waitingLoads == 1 }
    preferences.value = []
    await gate.releaseAll()

    #expect(await warmUp.value == .unchanged)
    #expect(manager.history.isEmpty)
  }

  @Test func configurationNeverLandsDuringInference() async throws {
    let coordinator = makeCoordinator(gate: CtcGate())
    let manager = FakeManager()

    let dictation = Task {
      try await coordinator.run(on: manager, desired: ["A"]) { await manager.infer(sleepMs: 150) }
    }
    // Let the dictation enter inference, then race a warm-up for other terms.
    try await Task.sleep(nanoseconds: 30_000_000)
    let warmUp = await coordinator.prepare(manager) { ["B"] }
    _ = try await dictation.value

    #expect(warmUp == .configured(["B"]))
    #expect(manager.history == [["A"], ["B"]])
    #expect(!manager.overlapDetected)
  }
}
