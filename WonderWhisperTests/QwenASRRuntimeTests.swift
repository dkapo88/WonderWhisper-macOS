import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Fakes

/// Scripted fake engine. Decode output and blocking are controlled per test.
private final class FakeQwenEngine: QwenASREngine, @unchecked Sendable {
  private let lock = NSLock()
  private var output: String
  private var unloads = 0
  private var decodes = 0
  private var decodingNow = false
  var decodeGate: DispatchSemaphore?
  var unloadedWhileDecoding = false

  init(output: String) {
    self.output = output
  }

  var unloadCount: Int { lock.withLock { unloads } }
  var decodeCount: Int { lock.withLock { decodes } }
  var isDecoding: Bool { lock.withLock { decodingNow } }

  func setOutput(_ text: String) { lock.withLock { output = text } }

  func decode(samples: [Float], language: String?, context: String?, maxTokens: Int) -> String {
    lock.withLock {
      decodes += 1
      decodingNow = true
    }
    decodeGate?.wait()
    return lock.withLock {
      decodingNow = false
      return output
    }
  }

  func unload() {
    lock.withLock {
      if decodingNow { unloadedWhileDecoding = true }
      unloads += 1
    }
  }
}

/// Scripted fake loader. Each `load` call pops the next step.
private final class FakeQwenLoader: QwenASREngineLoader, @unchecked Sendable {
  enum Step {
    case engine(FakeQwenEngine, gate: DispatchSemaphore? = nil)
    case fail(gate: DispatchSemaphore? = nil)
  }

  struct LoadFailed: Error {}

  private let lock = NSLock()
  private var steps: [Step]
  private var calls = 0
  private var cacheClears = 0
  let fallbackEngine: FakeQwenEngine

  init(
    steps: [Step],
    fallbackEngine: FakeQwenEngine = FakeQwenEngine(output: QwenCanary.expectedText)
  ) {
    self.steps = steps
    self.fallbackEngine = fallbackEngine
  }

  var loadCalls: Int { lock.withLock { calls } }
  var cacheClearCount: Int { lock.withLock { cacheClears } }

  func verifyFiles(directory: URL) throws -> String { "fake" }

  func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine {
    let step: Step? = lock.withLock {
      calls += 1
      return steps.isEmpty ? nil : steps.removeFirst()
    }
    switch step {
    case .engine(let engine, let gate):
      gate?.wait()
      return engine
    case .fail(let gate):
      gate?.wait()
      throw LoadFailed()
    case nil:
      return fallbackEngine
    }
  }

  func clearCache() {
    lock.withLock { cacheClears += 1 }
  }
}

private let canaryText = QwenCanary.expectedText
private let fakeCanary = QwenCanary(samples: [Float](repeating: 0, count: 16_000))
private let scratchDir = URL(fileURLWithPath: "/tmp/qwen-runtime-tests-never-read", isDirectory: true)

private func makeRuntime(
  loader: FakeQwenLoader,
  idleSeconds: TimeInterval = 300,
  cooldown: TimeInterval = 60
) -> QwenASRRuntime {
  QwenASRRuntime(
    loader: loader,
    modelDirectory: { scratchDir },
    canary: { fakeCanary },
    idleSeconds: idleSeconds,
    unhealthyRetryCooldown: cooldown,
    inference: QwenInferenceQueue(label: "qwen-runtime-tests")
  )
}

private func waitUntil(
  timeout: TimeInterval = 5,
  _ condition: () async -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  return await condition()
}

/// A healthy engine passes the canary because the fake returns the expected
/// text for every decode until a test changes its output.
private func healthyEngine() -> FakeQwenEngine {
  FakeQwenEngine(output: canaryText)
}

// MARK: - Canary + integrity

struct QwenLoadCheckTests {
  @Test func canaryAcceptsCasingAndPunctuationDrift() {
    let canary = QwenCanary(samples: [Float](repeating: 0, count: 16_000))
    #expect(canary.evaluate("The quick brown fox jumps over the lazy dog.").passed)
    #expect(canary.evaluate("the quick brown fox jumped over the lazy dog").passed)
    #expect(canary.evaluate("The quick brown fox jumps over a lazy dog!").passed)
  }

  @Test func canaryRejectsGarbageAndWrongText() {
    let canary = QwenCanary(samples: [Float](repeating: 0, count: 16_000))
    #expect(!canary.evaluate(String(repeating: "!", count: 48)).passed)
    #expect(!canary.evaluate("").passed)
    #expect(!canary.evaluate("Thank you for watching.").passed)
    #expect(!canary.evaluate("注册unesnut searchData meaning").passed)
  }

  @Test func bundledCanaryClipIsPresent() {
    let canary = QwenASRRuntime.bundledCanary()
    #expect(canary != nil)
    #expect((canary?.samples.count ?? 0) > 16_000 * 2)
  }

  private func writeSafetensors(to url: URL, dataBytes: Int, truncateBy: Int = 0) throws {
    let header = #"{"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"#
      + #""b":{"dtype":"F32","shape":[\#(dataBytes / 4 - 2)],"data_offsets":[8,\#(dataBytes)]},"#
      + #""__metadata__":{"format":"mlx"}}"#
    var data = Data()
    var length = UInt64(header.utf8.count).littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(Data(header.utf8))
    data.append(Data(repeating: 1, count: dataBytes - truncateBy))
    try data.write(to: url)
  }

  @Test func integrityAcceptsCompleteShardAndRejectsTruncated() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qwen-integrity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let shard = dir.appendingPathComponent("model.safetensors")
    try writeSafetensors(to: shard, dataBytes: 4096)
    let reports = try QwenWeightIntegrity.verify(directory: dir)
    #expect(reports.count == 1)
    #expect(reports.first?.tensorCount == 2)

    try writeSafetensors(to: shard, dataBytes: 4096, truncateBy: 100)
    #expect(throws: QwenWeightIntegrity.Failure.self) {
      try QwenWeightIntegrity.verify(directory: dir)
    }

    let index = #"{"weight_map":{"a":"model-00001.safetensors"}}"#
    try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
    #expect(throws: QwenWeightIntegrity.Failure.missingShard("model-00001.safetensors")) {
      try QwenWeightIntegrity.verify(directory: dir)
    }
  }
}

// MARK: - Runtime state machine

@Suite(.serialized)
struct QwenASRRuntimeTests {
  @Test func concurrentCallersShareOneVerifiedLoad() async throws {
    let gate = DispatchSemaphore(value: 0)
    let engine = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(engine, gate: gate)])
    let runtime = makeRuntime(loader: loader)

    async let warm: Void = runtime.warmUp()
    async let first = runtime.transcribe(samples: [0.1], language: "en", context: nil)
    async let second = runtime.transcribe(samples: [0.1], language: "en", context: nil)
    #expect(await waitUntil { loader.loadCalls == 1 })
    gate.signal()
    try await warm
    let results = try await [first, second]

    #expect(results == [canaryText, canaryText])
    #expect(loader.loadCalls == 1)
    #expect(await runtime.loadsStarted == 1)
    #expect(await runtime.currentHealth() == .healthy)
  }

  /// A sibling branch hit this: a caller whose load was superseded cleared the
  /// newer load's task, so the next caller started a third, concurrent load.
  @Test func staleCallerCannotClearNewerLoad() async throws {
    let gate1 = DispatchSemaphore(value: 0)
    let gate2 = DispatchSemaphore(value: 0)
    let engine2 = healthyEngine()
    let loader = FakeQwenLoader(steps: [
      .fail(gate: gate1),  // load#1 attempt 1 (stale by the time it finishes)
      .fail(),             // load#1 attempt 2
      .engine(engine2, gate: gate2),  // load#2
    ])
    let runtime = makeRuntime(loader: loader)

    let callerA = Task { try await runtime.transcribe(samples: [0.1], language: nil, context: nil) }
    #expect(await waitUntil { loader.loadCalls == 1 })

    await runtime.resetForReload(reason: "test supersedes load#1")
    let callerB = Task { try await runtime.transcribe(samples: [0.1], language: nil, context: nil) }
    #expect(await waitUntil { await runtime.loadsStarted == 2 })

    // load#1 now fails. Its caller must fall in behind load#2, not clear it.
    gate1.signal()
    try? await Task.sleep(nanoseconds: 100_000_000)
    let callerC = Task { try await runtime.transcribe(samples: [0.1], language: nil, context: nil) }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await runtime.loadsStarted == 2, "a third load started: stale caller cleared load#2")

    gate2.signal()
    let a = try await callerA.value
    let b = try await callerB.value
    let c = try await callerC.value
    #expect([a, b, c] == [canaryText, canaryText, canaryText])
    #expect(await runtime.loadsStarted == 2)
    #expect(await runtime.currentHealth() == .healthy, "stale failure must not mark Qwen unhealthy")
  }

  @Test func idleUnloadNeverRacesInFlightDecode() async throws {
    let engine = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(engine)])
    let runtime = makeRuntime(loader: loader, idleSeconds: 0.05)
    try await runtime.warmUp()

    let decodeGate = DispatchSemaphore(value: 0)
    engine.decodeGate = decodeGate
    let dictation = Task { try await runtime.transcribe(samples: [0.1], language: nil, context: nil) }
    #expect(await waitUntil { engine.isDecoding })
    // A warm-up finishing mid-decode used to re-arm the idle timer and unload
    // the model under the decode.
    try await runtime.warmUp()
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(engine.unloadCount == 0)
    #expect(await runtime.isEngineLoaded, "idle timer dropped the engine under an in-flight decode")

    decodeGate.signal()
    engine.decodeGate = nil
    #expect(try await dictation.value == canaryText)
    #expect(!engine.unloadedWhileDecoding)
    // Idle again: now it may unload.
    #expect(await waitUntil { engine.unloadCount == 1 })
    #expect(loader.cacheClearCount >= 1)
  }

  @Test func garbageDecodeThrowsRetiresAndReloadsForNextTime() async throws {
    let first = healthyEngine()
    let second = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(first), .engine(second)])
    let runtime = makeRuntime(loader: loader)
    try await runtime.warmUp()

    first.setOutput(String(repeating: "!", count: 448))
    await #expect(throws: QwenASRError.self) {
      _ = try await runtime.transcribe(samples: [0.1], language: nil, context: nil)
    }
    #expect(first.unloadCount == 1)
    // Background reload + canary for the next dictation.
    #expect(await waitUntil { await runtime.currentHealth() == .healthy })
    #expect(await runtime.loadsStarted == 2)
    #expect(try await runtime.transcribe(samples: [0.1], language: nil, context: nil) == canaryText)
  }

  @Test func canaryFailureRetriesOnceThenSucceeds() async throws {
    let broken = FakeQwenEngine(output: String(repeating: "!", count: 48))
    let good = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(broken), .engine(good)])
    let runtime = makeRuntime(loader: loader)

    let text = try await runtime.transcribe(samples: [0.1], language: nil, context: nil)
    #expect(text == canaryText)
    #expect(broken.unloadCount == 1)
    #expect(loader.cacheClearCount == 1)
    #expect(loader.loadCalls == 2)
    #expect(await runtime.currentHealth() == .healthy)
  }

  @Test func twoCanaryFailuresMarkUnhealthyAndFailFastDuringCooldown() async throws {
    let broken1 = FakeQwenEngine(output: String(repeating: "!", count: 48))
    let broken2 = FakeQwenEngine(output: "Thank you for watching.")
    let loader = FakeQwenLoader(steps: [.engine(broken1), .engine(broken2)])
    let runtime = makeRuntime(loader: loader)

    do {
      _ = try await runtime.transcribe(samples: [0.1], language: nil, context: nil)
      Issue.record("expected unhealthy")
    } catch let error as QwenASRError {
      #expect(error.shouldFallBack)
      guard case .unhealthy = error else {
        Issue.record("expected .unhealthy, got \(error)")
        return
      }
    }
    #expect(broken1.unloadCount == 1)
    #expect(broken2.unloadCount == 1)
    #expect(loader.cacheClearCount == 2)
    guard case .unhealthy = await runtime.currentHealth() else {
      Issue.record("health should be unhealthy")
      return
    }

    // Dictation inside the cooldown falls back immediately, no new load.
    await #expect(throws: QwenASRError.self) {
      _ = try await runtime.transcribe(samples: [0.1], language: nil, context: nil)
    }
    #expect(loader.loadCalls == 2)
    // Warm-up (recording start) ignores the cooldown and retries.
    try await runtime.warmUp()
    #expect(loader.loadCalls == 3)
    #expect(await runtime.currentHealth() == .healthy)
  }

  @Test func missingModelDirectoryIsNotDownloaded() async {
    let runtime = QwenASRRuntime(
      loader: FakeQwenLoader(steps: []),
      modelDirectory: { nil },
      canary: { fakeCanary }
    )
    await #expect(throws: QwenASRError.modelNotDownloaded) {
      _ = try await runtime.transcribe(samples: [0.1], language: nil, context: nil)
    }
  }
}
