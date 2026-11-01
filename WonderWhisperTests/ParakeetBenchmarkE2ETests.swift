import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Testing
@testable import WonderWhisper

/// Opt-in comparison of the on-device dictation models on `ParakeetBenchmarkClips`, through the
/// production `ParakeetTranscriptionProvider` path (dictation padding, Bark Clean clean-up).
///
/// Accuracy and warm latency (all models in one process, interleaved per clip):
/// `TEST_RUNNER_WW_RUN_MODEL_TESTS=1 TEST_RUNNER_WW_PARAKEET_BENCH=1 xcodebuild test ...
///   -only-testing:WonderWhisperTests/ParakeetBenchmarkE2ETests/accuracyAndWarmLatency`
///
/// Resident memory (one model per test process; repeat per model):
/// `TEST_RUNNER_WW_RUN_MODEL_TESTS=1 TEST_RUNNER_WW_PARAKEET_BENCH_MEM_MODEL=bark-clean
///   TEST_RUNNER_WW_PARAKEET_BENCH_MEM_BOOST=1 xcodebuild test ...
///   -only-testing:WonderWhisperTests/ParakeetBenchmarkE2ETests/residentMemory`
///
/// Reports (with transcripts of the synthetic clips) go to `WW_PARAKEET_BENCH_OUT`, default
/// `/tmp/ww-parakeet-bench`. Never commit them.
@Suite(.serialized)
struct ParakeetBenchmarkE2ETests {
  private static let environment = ProcessInfo.processInfo.environment
  private static let benchEnabled = environment["WW_PARAKEET_BENCH"] == "1"
  private static let memoryModel = environment["WW_PARAKEET_BENCH_MEM_MODEL"]
  private static let outputDirectory = URL(
    fileURLWithPath: environment["WW_PARAKEET_BENCH_OUT"] ?? "/tmp/ww-parakeet-bench", isDirectory: true
  )
  private static let timedRuns = Int(environment["WW_PARAKEET_BENCH_RUNS"] ?? "") ?? 5
  private static let models: [ParakeetModelKind] = (environment["WW_PARAKEET_BENCH_MODELS"]
    ?? "unified,bark-clean,ultra").split(separator: ",").map { ParakeetModelKind(storedValue: String($0)) }

  // MARK: - Accuracy and warm latency

  struct ClipResult: Codable {
    let model: String
    let id: String
    let category: String
    let bin: String
    let seconds: Double
    let reference: String
    let text: String
    let errors: Int
    let referenceWords: Int
    let fillers: Int
    let missingKeyWords: [String]
    let latencies: [Double]
  }

  @Test(.enabled(if: benchEnabled))
  func accuracyAndWarmLatency() async throws {
    try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
    let clips = try Self.synthesizeClips()
    defer { try? FileManager.default.removeItem(at: Self.clipDirectory) }

    // Every model must be on disk: a missing Bark Clean would otherwise fall back to Unified.
    for kind in Self.models where !ParakeetManager.modelsPresent(for: kind) {
      if let version = kind.tdtVersion {
        _ = try await AsrModels.download(version: version)
      } else {
        try await UnifiedAsrManager().loadModels(to: ParakeetManager.modelsDirectory)
      }
      try #require(ParakeetManager.modelsPresent(for: kind), "\(kind.rawValue) not downloaded")
    }

    var providers: [ParakeetModelKind: ParakeetTranscriptionProvider] = [:]
    for kind in Self.models {
      let provider = ParakeetTranscriptionProvider(padsInput: true, boostingEnabled: { false })
      _ = try await provider.transcribe(fileURL: clips[0].url, settings: Self.settings(kind))
      try #require(await provider.loadedKindForTesting == kind, "\(kind.rawValue) did not load itself")
      providers[kind] = provider
    }

    var results: [ClipResult] = []
    for clip in clips {
      var texts: [ParakeetModelKind: String] = [:]
      var latencies: [ParakeetModelKind: [Double]] = [:]
      // Untimed warm run per clip, then timed runs with the model order rotated each run.
      for kind in Self.models {
        texts[kind] = try await providers[kind]?.transcribe(fileURL: clip.url, settings: Self.settings(kind))
      }
      for run in 0..<Self.timedRuns {
        let order = Self.models.indices.map { Self.models[($0 + run) % Self.models.count] }
        for kind in order {
          let start = DispatchTime.now().uptimeNanoseconds
          _ = try await providers[kind]?.transcribe(fileURL: clip.url, settings: Self.settings(kind))
          latencies[kind, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
      }
      for kind in Self.models {
        let text = texts[kind] ?? ""
        let reference = Self.normalizedWords(clip.clip.clean)
        let hypothesis = Self.normalizedWords(text)
        results.append(ClipResult(
          model: kind.rawValue,
          id: clip.clip.id,
          category: clip.clip.category.rawValue,
          bin: Self.bin(clip.seconds),
          seconds: clip.seconds,
          reference: clip.clip.clean,
          text: text,
          errors: Self.editDistance(reference, hypothesis),
          referenceWords: reference.count,
          fillers: hypothesis.filter(Self.fillers.contains).count,
          missingKeyWords: clip.clip.keyWords.filter { !hypothesis.contains(Self.normalizedWords($0).joined()) },
          latencies: latencies[kind] ?? []
        ))
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: Self.outputDirectory.appendingPathComponent("results.json"))
    let report = Self.report(results, clips: clips)
    try report.write(to: Self.outputDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    // The benchmark records; the acceptance thresholds are read from the report.
    #expect(results.allSatisfy { !$0.text.contains("<unk>") })
  }

  // MARK: - Resident memory

  struct HostMemory: Codable {
    let anonymous: UInt64
    let wired: UInt64
    let compressed: UInt64
    var used: UInt64 { anonymous + wired + compressed }
  }

  @Test(.enabled(if: memoryModel != nil))
  func residentMemory() async throws {
    try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
    let kind = ParakeetModelKind(storedValue: Self.memoryModel)
    let boost = Self.environment["WW_PARAKEET_BENCH_MEM_BOOST"] == "1"
    try #require(ParakeetManager.modelsPresent(for: kind), "\(kind.rawValue) not downloaded")
    if boost { try #require(ParakeetVocabularyBoosting.ctcModelsPresent(), "CTC model not downloaded") }
    let long = try Self.synthesize(ParakeetBenchmarkClips.fluent.first { $0.id == "fl-l1" }!)
    defer { try? FileManager.default.removeItem(at: Self.clipDirectory) }

    let sampler = PeakSampler()
    sleep(3)
    let baseline = Self.hostMemory()
    let footprintBefore = Self.footprint()
    sampler.start()
    let terms = ["Priya Raman", "Siobhan O'Brien", "Anika Patel", "WonderWhisper", "Kubernetes"]
    let provider = ParakeetTranscriptionProvider(
      waitsForVocabularyModel: true,
      padsInput: true,
      boostingEnabled: { boost },
      vocabularyTerms: { terms }
    )
    var settings = Self.settings(kind)
    settings = TranscriptionSettings(endpoint: settings.endpoint, model: settings.model,
                                     language: "en", vocabularyTerms: boost ? terms : [])
    _ = try await provider.transcribe(fileURL: long, settings: settings)
    try #require(await provider.loadedKindForTesting == kind)
    sleep(3)
    let loadedIdle = Self.hostMemory()
    sampler.resetPeak()
    _ = try await provider.transcribe(fileURL: long, settings: settings)
    let decodePeak = sampler.peak()
    sleep(3)
    let afterDecode = Self.hostMemory()
    sampler.stop()
    let footprint = Self.footprint()

    func mb(_ value: Int64) -> Int64 { value / 1_048_576 }
    let line = [
      "model=\(kind.rawValue)", "boost=\(boost)",
      "loadedIdleMB=\(mb(Int64(loadedIdle.used) - Int64(baseline.used)))",
      "decodePeakMB=\(mb(Int64(decodePeak) - Int64(baseline.used)))",
      "afterDecodeMB=\(mb(Int64(afterDecode.used) - Int64(baseline.used)))",
      "footprintBeforeMB=\(mb(Int64(footprintBefore.current)))",
      "footprintMB=\(mb(Int64(footprint.current)))",
      "footprintPeakMB=\(mb(Int64(footprint.peak)))"
    ].joined(separator: " ")
    let file = Self.outputDirectory.appendingPathComponent("memory.txt")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    handle.write(Data((line + "\n").utf8))
    try handle.close()
    withExtendedLifetime(provider) {}
  }

  // MARK: - Clips

  struct SynthesizedClip {
    let clip: ParakeetBenchmarkClip
    let url: URL
    let seconds: Double
  }

  private static let clipDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ww-parakeet-bench-clips", isDirectory: true)

  private static func synthesizeClips() throws -> [SynthesizedClip] {
    try ParakeetBenchmarkClips.all.map { clip in
      let url = try synthesize(clip)
      let file = try AVAudioFile(forReading: url)
      return SynthesizedClip(clip: clip, url: url, seconds: Double(file.length) / file.processingFormat.sampleRate)
    }
  }

  private static func synthesize(_ clip: ParakeetBenchmarkClip) throws -> URL {
    try FileManager.default.createDirectory(at: clipDirectory, withIntermediateDirectories: true)
    let url = clipDirectory.appendingPathComponent("\(clip.id).wav")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", clip.voice, "-o", url.path, "--data-format=LEI16@16000", clip.spoken]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "say failed for \(clip.id)")
    return url
  }

  private static func settings(_ kind: ParakeetModelKind) -> TranscriptionSettings {
    TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: "parakeet-\(kind.rawValue)",
                          timeout: 120, language: "en")
  }

  private static func bin(_ seconds: Double) -> String {
    seconds < 5 ? "short (<5 s)" : seconds < 15 ? "medium (5-15 s)" : "long (>=15 s)"
  }

  // MARK: - Scoring

  static let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm"]

  /// Lower-case words in written form: both sides go through the same NeMo ITN, so "seventeen
  /// percent" and "17%" score alike, then punctuation is dropped ("3,450" -> "3450").
  static func normalizedWords(_ text: String) -> [String] {
    TextNormalizer.shared.normalizeSentence(text)
      .lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .map { word in String(word.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || $0 == "'"
      }.map(Character.init)).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
      .filter { !$0.isEmpty }
  }

  static func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for (i, left) in a.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, right) in b.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count]
  }

  private static func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = p * Double(sorted.count - 1)
    let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
    return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
  }

  private static func report(_ results: [ClipResult], clips: [SynthesizedClip]) -> String {
    let names = models.map(\.rawValue)
    func wer(_ rows: [ClipResult]) -> String {
      let words = rows.reduce(0) { $0 + $1.referenceWords }
      return words == 0 ? "-" : String(format: "%.2f", 100 * Double(rows.reduce(0) { $0 + $1.errors }) / Double(words))
    }
    var lines = ["# Parakeet dictation benchmark", "",
                 "\(clips.count) synthetic clips, \(String(format: "%.0f", clips.reduce(0) { $0 + $1.seconds })) s; "
                   + "\(timedRuns) warm timed runs per clip and model.", "",
                 "## WER (%) vs clean references", "",
                 "| group | clips | " + names.joined(separator: " | ") + " |",
                 "|---|--:|" + names.map { _ in "--:" }.joined(separator: "|") + "|"]
    let groups: [(String, (ClipResult) -> Bool)] = [
      ("all", { _ in true }), ("disfluent", { $0.category == "disfluent" }),
      ("fluent", { $0.category == "fluent" }), ("names/numbers/negation", { $0.category == "check" })
    ]
    for (label, filter) in groups {
      let count = results.filter { $0.model == names[0] && filter($0) }.count
      lines.append("| \(label) | \(count) | "
        + names.map { name in wer(results.filter { $0.model == name && filter($0) }) }.joined(separator: " | ") + " |")
    }
    let verbatimFillers = ParakeetBenchmarkClips.disfluent.reduce(0) { total, clip in
      total + normalizedWords(clip.spoken).filter(fillers.contains).count
    }
    lines += ["", "Fillers left on disfluent clips (\(verbatimFillers) spoken): "
      + names.map { name in
        "\(name) \(results.filter { $0.model == name && $0.category == "disfluent" }.reduce(0) { $0 + $1.fillers })"
      }.joined(separator: ", "), ""]

    lines += ["## Warm latency (s), p50 / p95", "",
              "| bin | clips | " + names.joined(separator: " | ") + " | "
                + names.dropFirst().map { "\($0)/\(names[0]) p50, p95" }.joined(separator: " | ") + " |",
              "|---|--:|" + names.map { _ in "--:" }.joined(separator: "|") + "|"
                + names.dropFirst().map { _ in "--:" }.joined(separator: "|") + "|"]
    for bin in ["short (<5 s)", "medium (5-15 s)", "long (>=15 s)"] {
      let rows = results.filter { $0.bin == bin }
      let count = rows.filter { $0.model == names[0] }.count
      guard count > 0 else { continue }
      func stats(_ name: String) -> (Double, Double) {
        let values = rows.filter { $0.model == name }.flatMap(\.latencies)
        return (percentile(values, 0.5), percentile(values, 0.95))
      }
      let base = stats(names[0])
      lines.append("| \(bin) | \(count) | "
        + names.map { let s = stats($0); return String(format: "%.3f / %.3f", s.0, s.1) }.joined(separator: " | ")
        + " | " + names.dropFirst().map { name in
          let s = stats(name)
          return String(format: "%.2fx, %.2fx", s.0 / base.0, s.1 / base.1)
        }.joined(separator: " | ") + " |")
    }

    lines += ["", "## Key words missing (names, numbers, negation)", ""]
    for result in results where !result.missingKeyWords.isEmpty {
      lines.append("- \(result.model) \(result.id): \(result.missingKeyWords.joined(separator: ", "))")
    }
    lines += ["", "## Outputs", ""]
    for clip in clips {
      lines.append("- **\(clip.clip.id)** (\(String(format: "%.1f", clip.seconds)) s) ref: \(clip.clip.clean)")
      for result in results where result.id == clip.clip.id {
        lines.append("  - \(result.model) [\(result.errors)/\(result.referenceWords)]: \(result.text)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Memory probes

  /// Host-wide anonymous + wired + compressed pages: CoreML keeps compiled and Neural Engine
  /// weights outside the process footprint, so this is the honest cost of a loaded model.
  static func hostMemory() -> HostMemory {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    let page = UInt64(vm_kernel_page_size)
    return HostMemory(anonymous: UInt64(stats.internal_page_count) * page,
                      wired: UInt64(stats.wire_count) * page,
                      compressed: UInt64(stats.compressor_page_count) * page)
  }

  static func footprint() -> (current: UInt64, peak: UInt64) {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    return rc == 0 ? (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint) : (0, 0)
  }

  final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    private var running = false

    func start() {
      lock.withLock { running = true; maximum = ParakeetBenchmarkE2ETests.hostMemory().used }
      Thread.detachNewThread { [self] in
        while lock.withLock({ running }) {
          let used = ParakeetBenchmarkE2ETests.hostMemory().used
          lock.withLock { maximum = max(maximum, used) }
          usleep(50_000)
        }
      }
    }

    func resetPeak() { lock.withLock { maximum = ParakeetBenchmarkE2ETests.hostMemory().used } }
    func peak() -> UInt64 { lock.withLock { maximum } }
    func stop() { lock.withLock { running = false } }
  }
}
