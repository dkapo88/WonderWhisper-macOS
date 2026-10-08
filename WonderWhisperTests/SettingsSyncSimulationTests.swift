import Foundation
import Testing
@testable import WonderWhisper

/// Seeded random simulation of 3–4 Macs sharing one iCloud settings file, driving the real
/// `SettingsSyncEngine` and `SettingsSyncTransaction` (the code the service runs, minus file IO).
///
/// Each seed runs a random history of: local edits, resets and undos; syncs that are NOT atomic
/// (edits land between the snapshot and the completion); relaunches (engine state round-tripped
/// through its persisted JSON); offline periods that produce iCloud conflict versions; deferred
/// view-model saves of different values under remote-apply provenance; app versions that drop a
/// key from the allowlist and later add it back; a schema-1 file written mid-history by an old
/// app; and first-enable choices. Then every Mac comes online, upgrades, and syncs until stable.
///
/// The oracle is independent of the engine. The simulation keeps its own operation log: every
/// user edit and every explicit choice, with the version it expects, computed from per-Mac
/// expected Lamport clocks. It checks:
/// 1. each version the engine creates is exactly the expected one;
/// 2. convergence: every Mac and the cloud file agree on every key; no conflict versions remain;
/// 3. for every key the file holds the logged edit with the highest version (so resets are never
///    resurrected), and every version in the file is in the log (nothing is fabricated).
struct SettingsSyncSimulationTests {
  static let seedCount: UInt64 = 2_000
  static let keys = ["vocab.custom", "vocab.spelling", "transcription.language", "llm.model"]
  /// The key an "older app version" doesn't sync.
  static let droppableKey = "llm.model"
  static let valuePool: [SettingsSyncValue?] = [.string("a"), .string("b"), .string("c"), nil]

  @Test func randomHistoriesConvergeOnTheNewestLoggedEdit() throws {
    var failures = 0
    var coverage = Simulation.Coverage()
    for seed in 0..<Self.seedCount {
      var simulation = Simulation(seed: seed)
      if let failure = try simulation.run() {
        Issue.record("seed \(seed): \(failure)")
        failures += 1
        if failures >= 3 { break }
      }
      coverage.add(simulation.coverage)
    }
    // The history generator must actually exercise every scenario it claims to.
    #expect(coverage.loggedEdits > 4_000)
    #expect(coverage.inFlightEdits > 500)
    #expect(coverage.inFlightUndos > 50)
    #expect(coverage.conflictVersions > 200)
    #expect(coverage.suppressedHops > 500)
    #expect(coverage.allowlistChanges > 500)
    #expect(coverage.schemaOneRewrites > 300)
    #expect(coverage.relaunches > 500)
    #expect(coverage.replaceChoices > 200 && coverage.adoptChoices > 200)
    let summary = "SettingsSyncSimulation: \(Self.seedCount) seeds, \(failures) failures, "
      + "\(coverage)"
    print(summary)
    try? summary.write(
      to: FileManager.default.temporaryDirectory
        .appendingPathComponent("WonderWhisperSettingsSyncSimulation.txt"),
      atomically: true,
      encoding: .utf8
    )
  }

  /// The oracle has teeth: a relay that re-labels received values as its own (the round-4
  /// finding-1 bug) must be detected.
  @Test func oracleRejectsAFabricatingRelay() throws {
    var detected: UInt64?
    for seed in 0..<UInt64(500) {
      var simulation = Simulation(seed: seed)
      simulation.fabricateRelays = true
      if try simulation.run() != nil {
        detected = seed
        break
      }
    }
    #expect(detected != nil, "a fabricating relay passed 500 seeds")
  }

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
    var allowlist = Set(SettingsSyncSimulationTests.keys)
    var enabled = false
    var firstEnableMode: SettingsSyncService.Mode?
    var online = true
    var offlineBase: Data?
    var replica: Data?
    // Independent model (never read from the engine):
    /// Expected Lamport clock.
    var expectedClock: SettingsSyncVersion?
    /// Keys this Mac has agreed state for (set by a completed sync, cleared on enable).
    var knownKeys: Set<String> = []
  }

  struct Coverage: CustomStringConvertible {
    var loggedEdits = 0
    var inFlightEdits = 0
    var inFlightUndos = 0
    var conflictVersions = 0
    var suppressedHops = 0
    var allowlistChanges = 0
    var schemaOneRewrites = 0
    var relaunches = 0
    var replaceChoices = 0
    var adoptChoices = 0

    mutating func add(_ other: Coverage) {
      loggedEdits += other.loggedEdits
      inFlightEdits += other.inFlightEdits
      inFlightUndos += other.inFlightUndos
      conflictVersions += other.conflictVersions
      suppressedHops += other.suppressedHops
      allowlistChanges += other.allowlistChanges
      schemaOneRewrites += other.schemaOneRewrites
      relaunches += other.relaunches
      replaceChoices += other.replaceChoices
      adoptChoices += other.adoptChoices
    }

    var description: String {
      "edits \(loggedEdits), in-flight \(inFlightEdits) (undos \(inFlightUndos)), conflicts "
        + "\(conflictVersions), suppressed hops \(suppressedHops), allowlist changes "
        + "\(allowlistChanges), schema-1 rewrites \(schemaOneRewrites), relaunches "
        + "\(relaunches), replace \(replaceChoices), adopt \(adoptChoices)"
    }
  }

  var coverage = Coverage()
  var rng: SeededGenerator
  var cloud = Cloud()
  var macs: [Mac] = []
  /// The independent operation log: per key, every expected version and its value.
  var logged: [String: [SettingsSyncVersion: SettingsSyncValue?]] = [:]
  /// Logged edits that legitimately can't win: made on a Mac that then installed an app
  /// version no longer syncing the key, before the edit reached any file.
  var dead: [String: Set<SettingsSyncVersion>] = [:]
  /// Every version that has ever been written to a file (cloud, conflict version, replica).
  var everStored: [String: Set<SettingsSyncVersion>] = [:]
  var trace: [String] = []
  var failure: String?
  var injectedSchemaOne = false
  /// Per key: (0, writer) versions the schema-1 rewrite gave to an entry, mapped to the version
  /// it had before. Such an entry carries the same edit (same value) with its ordering lost.
  var schemaOneAliases: [String: [SettingsSyncVersion: SettingsSyncVersion]] = [:]
  /// Test hook: re-label relayed values with the writing Mac's ID (a deliberate bug).
  var fabricateRelays = false

  init(seed: UInt64) {
    rng = SeededGenerator(seed: seed)
    let count = Int.random(in: 3...4, using: &rng)
    for index in 0..<count {
      let id = ["A", "B", "C", "D"][index]
      var values: SettingsSyncEngine.Values = [:]
      for key in SettingsSyncSimulationTests.keys { values[key] = .some(randomValue()) }
      macs.append(Mac(id: id, engine: SettingsSyncEngine(deviceID: id), values: values))
    }
  }

  mutating func randomValue() -> SettingsSyncValue? {
    SettingsSyncSimulationTests.valuePool.randomElement(using: &rng) ?? nil
  }

  mutating func randomKey() -> String {
    SettingsSyncSimulationTests.keys.randomElement(using: &rng) ?? "vocab.custom"
  }

  // MARK: - Run

  mutating func run() throws -> String? {
    try randomPhase()
    // In about a third of histories an old app rewrites the file in schema 1 mid-history
    // (from a steady state), and the history then carries on.
    if failure == nil, Int.random(in: 0..<3, using: &rng) == 0 {
      try settle()
      try injectSchemaOne()
      try randomPhase()
    }
    if let failure { return failure + "\n" + trace.suffix(40).joined(separator: "\n") }
    try settle()
    if let failure { return failure + "\n" + trace.suffix(40).joined(separator: "\n") }
    return try check().map { $0 + "\n" + trace.suffix(40).joined(separator: "\n") }
  }

  mutating func randomPhase() throws {
    let steps = Int.random(in: 15...35, using: &rng)
    for _ in 0..<steps where failure == nil {
      let index = Int.random(in: 0..<macs.count, using: &rng)
      switch Int.random(in: 0..<100, using: &rng) {
      case 0..<26: edit(index)
      case 26..<52: try sync(index, interleave: true)
      case 52..<58: try relaunch(index)
      case 58..<66: toggleOnline(index)
      case 66..<73: deferredHop(index)
      case 73..<77: try changeAllowlist(index)
      case 77..<79: try injectSchemaOne()
      default: enable(index)
      }
    }
  }

  mutating func settle() throws {
    for index in macs.indices where !macs[index].online { toggleOnline(index) }
    let allKeys = Set(SettingsSyncSimulationTests.keys)
    for index in macs.indices where macs[index].allowlist != allKeys {
      macs[index].allowlist = Set(SettingsSyncSimulationTests.keys)
      try relaunch(index)
    }
    for index in macs.indices where !macs[index].enabled { enable(index) }
    for _ in 0..<12 {
      let before = (cloud.file, cloud.conflicts, macs.map(\.values))
      for index in macs.indices { try sync(index, interleave: false) }
      if failure != nil { return }
      let after = (cloud.file, cloud.conflicts, macs.map(\.values))
      if before.0 == after.0, before.1 == after.1, before.2 == after.2,
         macs.allSatisfy({ $0.enabled && $0.firstEnableMode == nil }) {
        return
      }
    }
  }

  // MARK: - Independent model helpers

  func successor(_ version: SettingsSyncVersion?, _ writer: String) -> SettingsSyncVersion {
    SettingsSyncVersion((version?.counter ?? 0) + 1, writer)
  }

  mutating func log(_ key: String, _ version: SettingsSyncVersion, _ value: SettingsSyncValue?) {
    if let existing = logged[key]?[version], existing != value {
      failure = "version \(version) logged twice for \(key) with different values"
    }
    logged[key, default: [:]][version] = value
  }

  func syncedValues(_ mac: Mac) -> SettingsSyncEngine.Values {
    mac.values.filter { mac.allowlist.contains($0.key) }
  }

  /// The cloud document a Mac would see, combined with all (decodable) conflict versions.
  func visibleDocument(_ mac: Mac) throws -> SettingsSyncDocument? {
    let file = mac.online ? cloud.file : mac.replica
    let conflicts = mac.online ? cloud.conflicts : []
    var combined = try file.map(SettingsSyncDocument.decode)
    for data in conflicts {
      let version = try SettingsSyncDocument.decode(data)
      combined = combined.map { SettingsSyncMerger.combine($0, version) } ?? version
    }
    return combined
  }

  // MARK: - Actions

  /// A genuine user edit: logged with the version it must get if the Mac is versioning it.
  mutating func edit(_ index: Int, among keys: Set<String>? = nil, inFlight: Bool = false) {
    let key = keys.flatMap { $0.sorted().randomElement(using: &rng) } ?? randomKey()
    let value = randomValue()
    let old = macs[index].values[key] ?? nil
    macs[index].values[key] = .some(value)
    trace.append("\(macs[index].id) edit \(key)=\(value.map { "\($0)" } ?? "reset")")
    let mac = macs[index]
    let versioned = mac.enabled && mac.allowlist.contains(key) && mac.knownKeys.contains(key)
    note(index)
    guard versioned, old?.fingerprint != value?.fingerprint else { return }
    let expected = successor(macs[index].expectedClock, mac.id)
    macs[index].expectedClock = expected
    log(key, expected, value)
    coverage.loggedEdits += 1
    if inFlight {
      coverage.inFlightEdits += 1
      if macs[index].engine.records[key]?.fingerprint == value?.fingerprint {
        coverage.inFlightUndos += 1
      }
    }
    let actual = macs[index].engine.pending[key]?.version
    if actual != expected {
      failure = "\(mac.id) edit of \(key) got version \(String(describing: actual)), "
        + "expected \(expected)"
    }
  }

  /// A deferred view-model save caused by applying received settings: it may write a different
  /// (derived or default) value, but it runs with remote-apply provenance, so the real
  /// suppression rule drops it.
  mutating func deferredHop(_ index: Int) {
    let key = randomKey()
    let value = randomValue()
    let suppressed = SettingsSyncProvenance.applyingRemoteSettings {
      SyncProvenanceUserDefaults.suppresses(key)
    }
    if suppressed {
      coverage.suppressedHops += 1
    } else {
      macs[index].values[key] = .some(value)
    }
    note(index)
  }

  /// The defaults change notification.
  mutating func note(_ index: Int) {
    guard macs[index].enabled else { return }
    let values = syncedValues(macs[index])
    macs[index].engine.noteLocalChanges(values)
  }

  mutating func relaunch(_ index: Int) throws {
    let data = try JSONEncoder().encode(macs[index].engine)
    var engine = try JSONDecoder().decode(SettingsSyncEngine.self, from: data)
    engine.retain(keys: macs[index].allowlist)
    macs[index].engine = engine
    macs[index].knownKeys.formIntersection(macs[index].allowlist)
    coverage.relaunches += 1
    trace.append("\(macs[index].id) relaunch")
  }

  /// Installs an app version that doesn't sync `droppableKey`, or the current one again.
  mutating func changeAllowlist(_ index: Int) throws {
    let key = SettingsSyncSimulationTests.droppableKey
    if macs[index].allowlist.contains(key) {
      // Its edits of the key that never reached any file are discarded with the key (decided
      // from what was written to files, not from the engine).
      let stored = everStored[key] ?? []
      for version in logged[key]?.keys ?? [:].keys
      where version.writer == macs[index].id && !stored.contains(version) {
        dead[key, default: []].insert(version)
      }
      macs[index].allowlist.remove(key)
    } else {
      macs[index].allowlist.insert(key)
    }
    coverage.allowlistChanges += 1
    trace.append("\(macs[index].id) allowlist \(macs[index].allowlist.sorted())")
    try relaunch(index)
  }

  /// An old app version rewrites the file in schema 1 (counters lost, values kept). Only in a
  /// steady state, where every Mac holds agreed versions it can restore: a schema-1 rewrite
  /// discards ordering by design, so an edit no Mac still holds could legitimately lose.
  mutating func injectSchemaOne() throws {
    guard !injectedSchemaOne, let data = cloud.file, cloud.conflicts.isEmpty,
          macs.allSatisfy({
            $0.enabled && $0.online && $0.firstEnableMode == nil
              && $0.knownKeys == Set(SettingsSyncSimulationTests.keys)
          }) else { return }
    injectedSchemaOne = true
    let document = try SettingsSyncDocument.decode(data)
    var entries: [String: Any] = [:]
    for (key, entry) in document.entries {
      var raw: [String: Any] = ["deviceID": entry.deviceID, "modifiedAt": 1_000]
      if let value = entry.value {
        raw["value"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
      }
      entries[key] = raw
      // The old app's write carries the same edits at counter 0.
      log(key, SettingsSyncVersion(0, entry.deviceID), entry.value)
      schemaOneAliases[key, default: [:]][SettingsSyncVersion(0, entry.deviceID)] = entry.version
    }
    cloud.file = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "entries": entries, "devices": [String: Any]()
    ])
    coverage.schemaOneRewrites += 1
    trace.append("schema-1 file written")
  }

  mutating func enable(_ index: Int) {
    guard !macs[index].enabled else { return }
    let visible = macs[index].online ? cloud.file : macs[index].replica
    macs[index].enabled = true
    macs[index].engine.reset()
    macs[index].expectedClock = nil
    macs[index].knownKeys = []
    macs[index].firstEnableMode = visible == nil
      ? .initialUpload
      : (Bool.random(using: &rng) ? .preferCloud : .preferLocal)
    if macs[index].firstEnableMode == .preferLocal { coverage.replaceChoices += 1 }
    if macs[index].firstEnableMode == .preferCloud { coverage.adoptChoices += 1 }
    trace.append("\(macs[index].id) enable \(macs[index].firstEnableMode?.rawValue ?? "")")
  }

  mutating func toggleOnline(_ index: Int) {
    if macs[index].online {
      macs[index].online = false
      macs[index].offlineBase = cloud.file
      macs[index].replica = cloud.file
      trace.append("\(macs[index].id) offline")
      return
    }
    macs[index].online = true
    trace.append("\(macs[index].id) online")
    let base = macs[index].offlineBase
    guard let replica = macs[index].replica, replica != base else { return }
    if cloud.file == base || cloud.file == nil {
      cloud.file = replica
    } else if Bool.random(using: &rng) {
      cloud.conflicts.append(replica)
      coverage.conflictVersions += 1
    } else {
      if let current = cloud.file { cloud.conflicts.append(current) }
      cloud.file = replica
      coverage.conflictVersions += 1
    }
  }

  /// One sync: snapshot → (edits) → plan + write → (edits) → completion.
  mutating func sync(_ index: Int, interleave: Bool) throws {
    guard macs[index].enabled, failure == nil else { return }
    note(index)
    let mac = macs[index]
    let mode = mac.firstEnableMode ?? .normal
    trace.append("\(mac.id) sync \(mode.rawValue)\(mac.online ? "" : " (offline)")")
    let snapshot = syncedValues(mac)
    let snapshotVersion = mac.engine.latest
    let candidates = mac.engine.candidates(snapshot, mode: mode.mergeMode)
    // Edits interleave only on keys this Mac already has agreed state for: an edit to a key
    // that is still unknown is (correctly) stamped at the first observation after completion,
    // which this independent model doesn't predict.
    let interleavable = mac.knownKeys.intersection(mac.allowlist)
    let canInterleave = interleave && mode == .normal && !interleavable.isEmpty
    if canInterleave {
      for _ in 0..<Int.random(in: 0...2, using: &rng) {
        edit(index, among: interleavable, inFlight: true)
      }
    }

    // Independent expectation of what this merge must stamp (computed before planning).
    let visible = try visibleDocument(macs[index])
    let combinedMax = visible?.highestVersion
    let expectedStamp = successor([mac.expectedClock, combinedMax].compactMap { $0 }.max(), mac.id)
    var expectedStamped: [String: SettingsSyncValue?] = [:]
    for key in mac.allowlist {
      let value = snapshot[key] ?? nil
      let inCloud = visible?.entries[key] != nil
      switch mode {
      case .preferLocal, .resetOrdering:
        if value != nil || inCloud { expectedStamped[key] = value }
      case .preferCloud:
        if value != nil, !inCloud { expectedStamped[key] = value }
      case .normal, .initialUpload:
        if value != nil, !inCloud, !mac.knownKeys.contains(key) { expectedStamped[key] = value }
      }
    }

    var input = SettingsSyncTransaction.Input(
      local: candidates,
      deviceID: mac.id,
      deviceName: "Mac \(mac.id)",
      timestamp: Date(timeIntervalSince1970: 0)
    )
    input.mode = mode.mergeMode
    input.localVersion = snapshotVersion
    input.requireNoDocument = mode == .initialUpload
    let file = macs[index].online ? cloud.file : macs[index].replica
    let conflicts = macs[index].online ? cloud.conflicts : []
    let plan = SettingsSyncTransaction.plan(
      input,
      current: file.map { .contents($0) } ?? .missing,
      conflicts: conflicts.map { Optional($0) }
    )
    if plan.documentAppeared {
      macs[index].engine.reset()
      macs[index].firstEnableMode = Bool.random(using: &rng) ? .preferCloud : .preferLocal
      trace.append("\(mac.id) document appeared; re-choosing")
      return
    }
    guard var merge = plan.merge else { return }
    if var document = plan.write {
      if fabricateRelays {
        for (key, entry) in document.entries where entry.deviceID != mac.id {
          if candidates[key]?.version == entry.version {
            document.entries[key]?.deviceID = mac.id
            merge.agreed[key]?.version = document.entries[key]?.version
          }
        }
      }
      // Check the stamps against the independent expectation, then log them.
      let actual = merge.stamped.mapValues(\.value)
      if Set(actual.keys) != Set(expectedStamped.keys)
        || merge.stamped.values.contains(where: { $0.version != expectedStamp }) {
        failure = "\(mac.id) \(mode.rawValue) stamped \(merge.stamped.mapValues(\.version)), "
          + "expected \(expectedStamped.keys.sorted()) at \(expectedStamp)"
        return
      }
      for (key, value) in expectedStamped { log(key, expectedStamp, value) }
      let data = try document.encoded()
      recordStored(document)
      if macs[index].online {
        cloud.file = data
        let remaining = cloud.conflicts.indices.filter { !plan.incorporated.contains($0) }
        cloud.conflicts = remaining.map { cloud.conflicts[$0] }
      } else {
        macs[index].replica = data
      }
      // The clock adopts this transaction's versions only at completion: an edit made while
      // the transaction runs is stamped from the clock as it was (it can share a counter
      // with a stamp on a different key; versions are only ever compared within one key).
    }
    macs[index].firstEnableMode = nil
    if canInterleave {
      for _ in 0..<Int.random(in: 0...2, using: &rng) {
        edit(index, among: interleavable, inFlight: true)
      }
    }
    note(index)
    let completion = macs[index].engine.complete(
      merge,
      candidates: candidates,
      snapshot: snapshot,
      snapshotVersion: snapshotVersion,
      current: syncedValues(macs[index]),
      isValid: { _, _ in true }
    )
    for (key, value) in completion.apply { macs[index].values[key] = .some(value) }
    macs[index].knownKeys = macs[index].allowlist
    macs[index].expectedClock = [macs[index].expectedClock, merge.document.highestVersion]
      .compactMap { $0 }.max()
    if macs[index].engine.latest != macs[index].expectedClock {
      failure = "\(mac.id) clock after sync is \(String(describing: macs[index].engine.latest)), "
        + "expected \(String(describing: macs[index].expectedClock))"
    }
  }

  mutating func recordStored(_ document: SettingsSyncDocument) {
    for (key, entry) in document.entries {
      everStored[key, default: []].insert(entry.version)
    }
  }

  // MARK: - Oracle

  func check() throws -> String? {
    guard cloud.conflicts.isEmpty else {
      return "\(cloud.conflicts.count) conflict versions left after settling"
    }
    let document = try cloud.file.map(SettingsSyncDocument.decode)
    for key in SettingsSyncSimulationTests.keys {
      let newest = logged[key]?.filter { !(dead[key]?.contains($0.key) ?? false) }
        .max { $0.key < $1.key }
      let expected: SettingsSyncValue? = newest?.value ?? nil
      let entry = document?.entries[key]
      if let entry, logged[key]?[entry.version] != .some(entry.value) {
        return "\(key): file carries a version that isn't in the log: \(entry.version) "
          + "= \(String(describing: entry.value))"
      }
      let alias = entry.flatMap { schemaOneAliases[key]?[$0.version] }
      if let newest, entry?.version != newest.key, alias != newest.key {
        return "\(key): file has \(entry.map { "\($0.version)" } ?? "nothing"), newest logged "
          + "edit is \(newest.key)"
      }
      if entry?.value != expected {
        return "\(key): file value \(String(describing: entry?.value)) != expected "
          + "\(String(describing: expected))"
      }
      for mac in macs where (mac.values[key] ?? nil) != expected {
        return "\(key): Mac \(mac.id) holds \(String(describing: mac.values[key] ?? nil)), "
          + "expected \(String(describing: expected))"
      }
    }
    return nil
  }
}
