import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Fakes

/// Scripted fake engine. Decode output and blocking are controlled per test.
private final class FakeQwenEngine: QwenASREngine, @unchecked Sendable {
  private let lock = NSLock()
  private var output: String
  private var queuedOutputs: [String] = []
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
  func setOutputs(_ texts: [String]) { lock.withLock { queuedOutputs = texts } }

  func decode(samples: [Float], language: String?, context: String?, maxTokens: Int) -> String {
    lock.withLock {
      decodes += 1
      decodingNow = true
    }
    decodeGate?.wait()
    return lock.withLock {
      decodingNow = false
      return queuedOutputs.isEmpty ? output : queuedOutputs.removeFirst()
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

// MARK: - Integrity parser fuzzing (review finding 5)

/// Malformed headers must throw a structural failure, never trap. The original
/// parser died with SIGTRAP on `data_offsets: [0, Int64.max]`.
struct QwenWeightIntegrityFuzzTests {
  private static func shard(lengthField: UInt64, header: Data, payload: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qwen-fuzz-\(UUID().uuidString).safetensors")
    var data = Data()
    var length = lengthField.littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(header)
    data.append(Data(repeating: 0, count: payload))
    try data.write(to: url)
    return url
  }

  private static func shard(json: String, payload: Int = 64) throws -> URL {
    let header = Data(json.utf8)
    return try shard(lengthField: UInt64(header.count), header: header, payload: payload)
  }

  private static func expectStructuralFailure(_ url: URL, _ label: String) {
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      _ = try QwenWeightIntegrity.verifyShard(at: url)
      Issue.record("\(label): accepted a malformed shard")
    } catch is QwenWeightIntegrity.Failure {
      // expected
    } catch {
      Issue.record("\(label): unexpected error \(error)")
    }
  }

  @Test func overflowingOffsetsThrowInsteadOfTrapping() throws {
    let cases = [
      "[0,9223372036854775807]",
      "[9223372036854775807,9223372036854775807]",
      "[0,18446744073709551615]",
      "[0,1e300]",
      "[0,9007199254740993]",
    ]
    for offsets in cases {
      let url = try Self.shard(json: #"{"w":{"dtype":"F32","shape":[1],"data_offsets":\#(offsets)}}"#)
      Self.expectStructuralFailure(url, offsets)
    }
  }

  @Test func negativeReversedAndNonNumericOffsetsThrow() throws {
    let cases = [
      "[-8,0]", "[0,-1]", "[16,8]", "[0]", "[0,8,16]", "[\"0\",\"8\"]", "[true,8]",
      "[0.5,8]", "[0,null]", "{}", "\"0-8\"",
    ]
    for offsets in cases {
      let url = try Self.shard(json: #"{"w":{"dtype":"F32","shape":[1],"data_offsets":\#(offsets)}}"#)
      Self.expectStructuralFailure(url, offsets)
    }
  }

  @Test func offsetsPastThePayloadAreTruncation() throws {
    let url = try Self.shard(json: #"{"w":{"dtype":"F32","shape":[16],"data_offsets":[0,64]}}"#, payload: 32)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: QwenWeightIntegrity.Failure.self) { try QwenWeightIntegrity.verifyShard(at: url) }
  }

  @Test func hugeTruncatedAndNonJSONHeadersThrow() throws {
    Self.expectStructuralFailure(
      try Self.shard(lengthField: UInt64.max, header: Data("{}".utf8), payload: 8), "UInt64.max length"
    )
    Self.expectStructuralFailure(
      try Self.shard(lengthField: UInt64(Int64.max), header: Data("{}".utf8), payload: 8), "Int64.max length"
    )
    Self.expectStructuralFailure(
      try Self.shard(lengthField: 60 * 1024 * 1024, header: Data("{}".utf8), payload: 8), "length past EOF"
    )
    Self.expectStructuralFailure(
      try Self.shard(lengthField: 0, header: Data(), payload: 8), "zero length"
    )
    Self.expectStructuralFailure(try Self.shard(json: "not json at all"), "non-JSON")
    Self.expectStructuralFailure(try Self.shard(json: "[1,2,3]"), "JSON array")
    Self.expectStructuralFailure(try Self.shard(json: #"{"w":5}"#), "tensor not an object")
    let tiny = FileManager.default.temporaryDirectory
      .appendingPathComponent("qwen-fuzz-tiny-\(UUID().uuidString).safetensors")
    try Data([1, 2, 3]).write(to: tiny)
    Self.expectStructuralFailure(tiny, "shorter than 8 bytes")
  }

  @Test func randomBytesNeverTrap() throws {
    var generator = SystemRandomNumberGenerator()
    for iteration in 0..<300 {
      let length = Int.random(in: 0...256, using: &generator)
      var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
      // Half the time, make the length field plausible so the JSON path is exercised.
      if iteration.isMultiple(of: 2), bytes.count >= 8 {
        let headerLength = UInt64(Int.random(in: 0...(bytes.count - 8), using: &generator))
        for i in 0..<8 { bytes[i] = UInt8((headerLength >> (8 * UInt64(i))) & 0xFF) }
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("qwen-fuzz-rand-\(UUID().uuidString).safetensors")
      try Data(bytes).write(to: url)
      _ = try? QwenWeightIntegrity.verifyShard(at: url)
      try? FileManager.default.removeItem(at: url)
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

  @Test func repetitionAcrossCleanChunksIsCaughtAfterJoining() {
    let part = Array(repeating: "the", count: 6).joined(separator: " ")
    let engine = FakeQwenEngine(output: part)
    let samples = [Float](repeating: 0.1, count: 16_000 * 30)
    #expect(QwenASRManager.degenerateReason(part, sampleCount: 16_000 * 15) == nil)
    let result = QwenASRRuntime.decodeChunks(
      samples: samples, ranges: QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count),
      engine: engine, language: nil, context: nil
    )
    guard case .degenerate(let reason, _, let joined) = result else {
      Issue.record("joined repetition escaped: \(result)")
      return
    }
    #expect(reason.contains("joined transcript: exact repetition 12x"))
    #expect(joined == part + " " + part)
    #expect(engine.decodeCount == 2)
  }

  @Test func compressedLoopIsCaughtInsideEachChunk() {
    let engine = FakeQwenEngine(output: String(repeating: "thank you ", count: 44))
    let samples = [Float](repeating: 0.1, count: 16_000 * 30)
    let result = QwenASRRuntime.decodeChunks(
      samples: samples, ranges: QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count),
      engine: engine, language: nil, context: nil
    )
    guard case .degenerate(let reason, let chunk, _) = result else {
      Issue.record("chunk repetition escaped: \(result)")
      return
    }
    #expect(reason.contains("compression ratio"))
    #expect(chunk == 0)
    #expect(engine.decodeCount == 1)
  }

  @Test func emphasisAndMultilingualDecodeKeepHealthyModelLoaded() async throws {
    let engine = healthyEngine()
    let runtime = makeRuntime(loader: FakeQwenLoader(steps: [.engine(engine)]))
    try await runtime.warmUp()
    for text in ["Wait!!!!!!!!", "no no no no", "ha ha ha",
      "English/Русский and English/Українська: 我们讨论新版本的发布计划。"] {
      engine.setOutput(text)
      #expect(try await runtime.transcribe(
        samples: [Float](repeating: 0.1, count: 16_000 * 10), language: nil, context: nil
      ) == text)
      #expect(await runtime.currentHealth() == .healthy)
      #expect(engine.unloadCount == 0)
      #expect(await runtime.loadsStarted == 1)
    }
  }

  @Test(arguments: QwenGuardRegressionCorpus.legitimate)
  func legitimateRepetitionKeepsVerifiedEngineHealthy(
    _ example: QwenGuardRegressionCorpus.Example
  ) async throws {
    let engine = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(engine)])
    let runtime = makeRuntime(loader: loader)
    try await runtime.warmUp()
    #expect(await runtime.currentHealth() == .healthy)
    engine.setOutput(example.text)
    // One fake decode, including a realistic 15s per-chunk budget for long lists.
    let samples = [Float](repeating: 0.1, count: 16_000 * min(example.seconds, 15))
    for _ in 0..<2 {
      #expect(try await runtime.transcribe(samples: samples, language: nil, context: nil)
        == example.text.trimmingCharacters(in: .whitespacesAndNewlines))
      #expect(await runtime.currentHealth() == .healthy)
      #expect(await runtime.isEngineLoaded)
      #expect(engine.unloadCount == 0)
      #expect(loader.cacheClearCount == 0)
      #expect(loader.loadCalls == 1)
      #expect(await runtime.loadsStarted == 1)
    }
  }

  @Test func progressingListAcrossChunksKeepsVerifiedEngineHealthy() async throws {
    let engine = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(engine)])
    let runtime = makeRuntime(loader: loader)
    try await runtime.warmUp()
    let parts = [1...10, 11...20].map { range in
      range.map { "Item \($0), approved and ready for release." }.joined(separator: " ")
    }
    engine.setOutputs(parts)
    let text = try await runtime.transcribe(
      samples: [Float](repeating: 0.1, count: 16_000 * 30), language: nil, context: nil
    )
    #expect(text == parts.joined(separator: " "))
    #expect(engine.decodeCount == 3, "canary and both chunks should decode")
    #expect(await runtime.currentHealth() == .healthy)
    #expect(await runtime.isEngineLoaded)
    #expect(engine.unloadCount == 0)
    #expect(loader.cacheClearCount == 0)
    #expect(loader.loadCalls == 1)
    #expect(await runtime.loadsStarted == 1)
  }

  @Test(arguments: QwenGuardRegressionCorpus.highCountEscapes)
  func highCountTailRetiresVerifiedEngineAndFallsBack(
    _ example: QwenGuardRegressionCorpus.Example
  ) async throws {
    let engine = healthyEngine()
    let loader = FakeQwenLoader(steps: [.engine(engine), .engine(healthyEngine())])
    let runtime = makeRuntime(loader: loader)
    try await runtime.warmUp()
    #expect(await runtime.currentHealth() == .healthy)
    engine.setOutput(example.text)

    do {
      _ = try await runtime.transcribe(
        samples: [Float](repeating: 0.1, count: 16_000 * example.seconds),
        language: nil, context: nil
      )
      Issue.record("corrupted transcript escaped: \(example.name)")
    } catch let error as QwenASRError {
      #expect(error.shouldFallBack)
      guard case .degenerateTranscript(let reason) = error else {
        Issue.record("expected decode guard failure, got \(error)")
        return
      }
      #expect(reason.contains("high-count exact repetition"))
      let text = try await QwenASRFallback.transcribe(
        fileURL: URL(fileURLWithPath: "/dev/null"), choice: .groq,
        settings: TranscriptionSettings(
          endpoint: URL(fileURLWithPath: "/unused"), model: "qwen-local", language: "en"
        ), groq: LoopFallbackProvider()
      )
      #expect(text == "safe fallback transcript")
      #expect(text != example.text)
    }
    #expect(engine.unloadCount == 1)
    #expect(loader.cacheClearCount == 1)
    #expect(await waitUntil { await runtime.currentHealth() == .healthy })
    #expect(await runtime.loadsStarted == 2)
  }

  /// Review finding 2: a 1.5 s tail chunk that decodes to ~1,000 chars fits
  /// the joined 16.5 s budget but must fail against its own length.
  @Test func badShortTailChunkIsCaughtPerChunk() async throws {
    let engine = TailGarbageEngine(tailSampleCount: 24_000)
    let samples = [Float](repeating: 0.1, count: 16_000 * 15 + 24_000)
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples.count)
    #expect(ranges.map(\.count) == [16_000 * 15, 24_000])

    let joined = TailGarbageEngine.headText + " " + TailGarbageEngine.tailText
    #expect(joined.count > 1_000)
    #expect(
      QwenASRManager.degenerateReason(joined, sampleCount: samples.count) == nil,
      "the old whole-recording check let this through"
    )

    let outcome = QwenASRRuntime.decodeChunks(
      samples: samples, ranges: ranges, engine: engine, language: nil, context: nil
    )
    guard case .degenerate(_, let chunk, _) = outcome else {
      Issue.record("expected the tail chunk to be rejected, got \(outcome)")
      return
    }
    #expect(chunk == 1)

    let runtime = QwenASRRuntime(
      loader: SingleEngineLoader(engine: engine),
      modelDirectory: { scratchDir },
      canary: { QwenCanary(samples: [Float](repeating: 0, count: 16_000)) }
    )
    await #expect(throws: QwenASRError.self) {
      _ = try await runtime.transcribe(samples: samples, language: nil, context: nil)
    }
  }
}

private final class LoopFallbackProvider: TranscriptionProvider {
  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    "safe fallback transcript"
  }
}

/// 15 s chunks decode normally; the short tail decodes to ~1,000 chars; the
/// 1 s canary decodes to the expected sentence.
private final class TailGarbageEngine: QwenASREngine, @unchecked Sendable {
  static let headText = "Please move the planning meeting to Thursday and send the notes."
  static let tailText = (0..<160).map { "token\($0)" }.joined(separator: " ")
  let tailSampleCount: Int

  init(tailSampleCount: Int) { self.tailSampleCount = tailSampleCount }

  func decode(samples: [Float], language: String?, context: String?, maxTokens: Int) -> String {
    if samples.count == tailSampleCount { return Self.tailText }
    if samples.count == 16_000 { return QwenCanary.expectedText }
    return Self.headText
  }

  func unload() {}
}

private struct SingleEngineLoader: QwenASREngineLoader {
  let engine: QwenASREngine
  func verifyFiles(directory: URL) throws -> String { "fake" }
  func load(directory: URL, log: (String) -> Void) throws -> QwenASREngine { engine }
  func clearCache() {}
}
