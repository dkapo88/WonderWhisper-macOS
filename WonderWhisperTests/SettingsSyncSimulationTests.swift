import Foundation
import Testing
@testable import WonderWhisper

/// Seeded random simulation of 3–4 Macs sharing one iCloud settings file, driving the real
/// `SettingsSyncEngine` and `SettingsSyncTransaction` (the same code the service runs, minus
/// file IO). Each seed runs a random history of local edits and resets, syncs, relaunches
/// (engine state round-tripped through its persisted JSON), offline periods that produce iCloud
/// conflict versions, deferred view-model re-saves, and first-enable choices; then brings every
/// Mac online and syncs until stable.
///
/// Properties checked for every seed:
/// 1. Convergence: every Mac and the cloud file hold the same value for every key, and no
///    conflict versions remain.
/// 2. Newest genuine edit wins: for every key the converged value is the one written by the
///    genuine edit with the highest (counter, writer) version, so resets are never resurrected.
/// 3. No fabricated versions: every version in the file was created by a genuine edit (or an
///    explicit first-enable choice) and still carries that edit's value.
struct SettingsSyncSimulationTests {
  static let seedCount: UInt64 = 2_000
  static let keys = ["vocab.custom", "vocab.spelling", "transcription.language", "llm.model"]
  static let valuePool: [SettingsSyncValue?] = [.string("a"), .string("b"), .string("c"), nil]

  @Test func randomHistoriesConvergeOnTheNewestGenuineEdit() throws {
    var failures = 0
    for seed in 0..<Self.seedCount {
      var simulation = Simulation(seed: seed)
      if let failure = try simulation.run() {
        Issue.record("seed \(seed): \(failure)")
        failures += 1
        if failures >= 3 { break }
      }
    }
    print("SettingsSyncSimulation: \(Self.seedCount) seeds, \(failures) failures")
  }

  /// The first few seeds, replayable one at a time when debugging a failure.
  @Test(arguments: [UInt64(0), 1, 2, 42, 1_999])
  func singleSeedIsDeterministic(seed: UInt64) throws {
    var first = Simulation(seed: seed)
    var second = Simulation(seed: seed)
    #expect(try first.run() == nil, "seed \(seed)")
    #expect(try second.run() == nil, "seed \(seed)")
    #expect(first.cloud.file == second.cloud.file)
  }
}

/// Deterministic RNG (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed &+ 0x9E37_79B9_7F4A_7C15
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private struct Simulation {
  struct Cloud {
    var file: Data?
    var conflicts: [Data] = []
  }

  struct Mac {
    var id: String
    var engine: SettingsSyncEngine
    var values: SettingsSyncEngine.Values
    var enabled = false
    var firstEnableMode: SettingsSyncService.Mode?
    var online = true
    /// While offline: the file as it was when the Mac went offline, and its local copy.
    var offlineBase: Data?
    var replica: Data?
  }

  var rng: SeededGenerator
  var cloud = Cloud()
  var macs: [Mac] = []
  /// Every version ever created, with the value of the edit that created it.
  var genuine: [String: [SettingsSyncVersion: SettingsSyncValue?]] = [:]
  var log: [String] = []

  init(seed: UInt64) {
    rng = SeededGenerator(seed: seed)
    let count = Int.random(in: 3...4, using: &rng)
    for index in 0..<count {
      let id = ["A", "B", "C", "D"][index]
      var values: SettingsSyncEngine.Values = [:]
      for key in SettingsSyncSimulationTests.keys {
        values[key] = .some(randomValue())
      }
      macs.append(Mac(id: id, engine: SettingsSyncEngine(deviceID: id), values: values))
    }
  }

  mutating func randomValue() -> SettingsSyncValue? {
    SettingsSyncSimulationTests.valuePool.randomElement(using: &rng) ?? nil
  }

  // MARK: - Run

  mutating func run() throws -> String? {
    let steps = Int.random(in: 15...35, using: &rng)
    for _ in 0..<steps {
      let index = Int.random(in: 0..<macs.count, using: &rng)
      switch Int.random(in: 0..<100, using: &rng) {
      case 0..<30: edit(index)
      case 30..<60: try sync(index)
      case 60..<67: try relaunch(index)
      case 67..<77: try toggleOnline(index)
      case 77..<82: deferredResave(index)
      default: enable(index)
      }
    }
    try settle()
    return try check()
  }

  /// Every Mac online and enabled, then sync rounds until nothing changes.
  mutating func settle() throws {
    for index in macs.indices where !macs[index].online { try toggleOnline(index) }
    for index in macs.indices where !macs[index].enabled { enable(index) }
    for _ in 0..<12 {
      let before = (cloud.file, cloud.conflicts, macs.map(\.values))
      for index in macs.indices { try sync(index) }
      let after = (cloud.file, cloud.conflicts, macs.map(\.values))
      if before.0 == after.0, before.1 == after.1, before.2 == after.2,
         macs.allSatisfy({ $0.enabled && $0.firstEnableMode == nil }) {
        return
      }
    }
  }

  // MARK: - Actions

  mutating func edit(_ index: Int) {
    let key = SettingsSyncSimulationTests.keys.randomElement(using: &rng) ?? "vocab.custom"
    let value = randomValue()
    macs[index].values[key] = .some(value)
    log.append("\(macs[index].id) edit \(key)=\(value.map { "\($0)" } ?? "reset")")
    note(index)
  }

  /// A view model re-persisting the value it already holds (what a deferred hop does once
  /// provenance is stripped of the remote-apply case): never a genuine edit.
  mutating func deferredResave(_ index: Int) {
    let key = SettingsSyncSimulationTests.keys.randomElement(using: &rng) ?? "vocab.custom"
    macs[index].values[key] = macs[index].values[key] ?? nil
    note(index)
  }

  /// The defaults change notification: stamp genuine edits, and record the versions created.
  mutating func note(_ index: Int) {
    guard macs[index].enabled else { return }
    let before = macs[index].engine.pending
    macs[index].engine.noteLocalChanges(macs[index].values)
    for (key, edit) in macs[index].engine.pending where before[key] != edit {
      guard let version = edit.version else { continue }
      genuine[key, default: [:]][version] = macs[index].values[key] ?? nil
    }
  }

  mutating func relaunch(_ index: Int) throws {
    let data = try JSONEncoder().encode(macs[index].engine)
    macs[index].engine = try JSONDecoder().decode(SettingsSyncEngine.self, from: data)
    log.append("\(macs[index].id) relaunch")
  }

  mutating func enable(_ index: Int) {
    guard !macs[index].enabled else { return }
    let visible = macs[index].online ? cloud.file : macs[index].replica
    macs[index].enabled = true
    macs[index].engine.reset()
    if visible == nil {
      macs[index].firstEnableMode = .initialUpload
    } else {
      macs[index].firstEnableMode = Bool.random(using: &rng) ? .preferCloud : .preferLocal
    }
    log.append("\(macs[index].id) enable \(macs[index].firstEnableMode?.rawValue ?? "")")
  }

  mutating func toggleOnline(_ index: Int) throws {
    if macs[index].online {
      macs[index].online = false
      macs[index].offlineBase = cloud.file
      macs[index].replica = cloud.file
      log.append("\(macs[index].id) offline")
      return
    }
    macs[index].online = true
    let base = macs[index].offlineBase
    let replica = macs[index].replica
    log.append("\(macs[index].id) online")
    guard replica != base, let replica else { return }
    if cloud.file == base || cloud.file == nil {
      cloud.file = replica
    } else if Bool.random(using: &rng) {
      cloud.conflicts.append(replica)  // the cloud copy stays current
    } else {
      if let current = cloud.file { cloud.conflicts.append(current) }
      cloud.file = replica
    }
  }

  mutating func sync(_ index: Int) throws {
    guard macs[index].enabled else { return }
    note(index)
    var mac = macs[index]
    let mode = mac.firstEnableMode ?? .normal
    let candidates = mac.engine.candidates(mac.values, mode: mode.mergeMode)
    var input = SettingsSyncTransaction.Input(
      local: candidates,
      deviceID: mac.id,
      deviceName: "Mac \(mac.id)",
      timestamp: Date(timeIntervalSince1970: 0)
    )
    input.mode = mode.mergeMode
    input.localCounter = mac.engine.counter
    input.requireNoDocument = mode == .initialUpload

    let file = mac.online ? cloud.file : mac.replica
    let conflicts = mac.online ? cloud.conflicts : []
    let plan = SettingsSyncTransaction.plan(
      input,
      current: file.map { .contents($0) } ?? .missing,
      conflicts: conflicts.map { Optional($0) }
    )
    if plan.documentAppeared {
      // The service backs out and asks; the user picks a side.
      mac.engine.reset()
      mac.firstEnableMode = Bool.random(using: &rng) ? .preferCloud : .preferLocal
      macs[index] = mac
      return
    }
    guard let merge = plan.merge else { return }
    if let document = plan.write {
      let data = try document.encoded()
      if mac.online {
        cloud.file = data
        let remaining = cloud.conflicts.indices.filter { !plan.incorporated.contains($0) }
        cloud.conflicts = remaining.map { cloud.conflicts[$0] }
      } else {
        mac.replica = data
      }
      for (key, entry) in merge.stamped {
        genuine[key, default: [:]][entry.version] = entry.value
      }
    }
    mac.firstEnableMode = nil
    let completion = mac.engine.complete(
      merge,
      candidates: candidates,
      snapshot: mac.values,
      current: mac.values,
      isValid: { _, _ in true }
    )
    for (key, value) in completion.apply { mac.values[key] = .some(value) }
    macs[index] = mac
  }

  // MARK: - Oracle

  func check() throws -> String? {
    guard cloud.conflicts.isEmpty else {
      return "\(cloud.conflicts.count) conflict versions left after settling\n" + trace
    }
    guard let data = cloud.file else {
      let anyValue = macs.contains { mac in mac.values.values.contains { $0 != nil } }
      return anyValue ? "no cloud file although Macs hold values\n" + trace : nil
    }
    let document = try SettingsSyncDocument.decode(data)
    for key in SettingsSyncSimulationTests.keys {
      let newest = genuine[key]?.max { $0.key < $1.key }
      let expected: SettingsSyncValue? = newest?.value ?? nil
      let entry = document.entries[key]
      if let newest {
        guard entry?.version == newest.key else {
          return "\(key): file has \(entry.map { "\($0.version)" } ?? "nothing"), newest genuine "
            + "edit is \(newest.key)\n" + trace
        }
      }
      if entry?.value != expected {
        return "\(key): file value \(String(describing: entry?.value)) != expected "
          + "\(String(describing: expected))\n" + trace
      }
      if let entry, genuine[key]?[entry.version] != .some(entry.value) {
        return "\(key): file carries fabricated version \(entry.version)\n" + trace
      }
      for mac in macs where (mac.values[key] ?? nil) != expected {
        return "\(key): Mac \(mac.id) holds \(String(describing: mac.values[key] ?? nil)), "
          + "expected \(String(describing: expected))\n" + trace
      }
    }
    return nil
  }

  var trace: String { log.suffix(40).joined(separator: "\n") }
}
