import AVFoundation
import Foundation
import Testing
@testable import WonderWhisper

/// Opt-in check of dictation input padding with the real Parakeet models: a very short utterance
/// cut right after its last word, and an utterance just under the 15 s window that padding
/// pushes across it (no dropped or duplicated words at the seam).
///
/// Run with:
/// `TEST_RUNNER_WW_PARAKEET_E2E=1 xcodebuild test ...
///   -only-testing:WonderWhisperTests/ParakeetPaddingE2ETests`
/// Results go to `WW_PARAKEET_E2E_OUT` + `.padding`, default `/tmp/ww-parakeet-e2e.txt.padding`.
@Suite(.serialized)
struct ParakeetPaddingE2ETests {
  private static let environment = ProcessInfo.processInfo.environment
  private static let isEnabled = environment["WW_PARAKEET_E2E"] == "1"
  private static let outputPath = (environment["WW_PARAKEET_E2E_OUT"] ?? "/tmp/ww-parakeet-e2e.txt") + ".padding"

  private static let shortPhrases = ["Yes.", "Send it.", "Thanks, Ash."]
  private static let boundaryPhrase = "The quarterly booking review covers three studios in Singapore. "
    + "Attendance rose in the morning classes, the evening coaches asked for longer breaks, "
    + "and the front desk wants a simpler refund form before the holiday timetable starts in December."

  @Test(.enabled(if: isEnabled))
  func paddingKeepsShortAndWindowBoundaryUtterancesWhole() async throws {
    var report: [String] = []
    var failures: [String] = []
    for model in ["parakeet-unified", "parakeet-ultra"] {
      let padded = ParakeetTranscriptionProvider(padsInput: true, boostingEnabled: { false })
      let plain = ParakeetTranscriptionProvider(padsInput: false, boostingEnabled: { false })

      for phrase in Self.shortPhrases {
        let wav = try Self.speech(phrase)
        defer { try? FileManager.default.removeItem(at: wav) }
        let withPadding = try await Self.transcribe(padded, model: model, wav: wav)
        let without = try await Self.transcribe(plain, model: model, wav: wav)
        let missing = Self.missingWords(reference: phrase, output: withPadding)
        let missingWithout = Self.missingWords(reference: phrase, output: without)
        report.append("\(model) short \(String(format: "%.2f", Self.duration(wav)))s \"\(phrase)\" "
          + "padded=\"\(withPadding)\" unpadded=\"\(without)\" paddedMissing=\(missing) unpaddedMissing=\(missingWithout)")
        // Synthetic speech this short can be misheard either way; padding must never lose words.
        if missing.count > missingWithout.count {
          failures.append("\(model) short \"\(phrase)\" padded lost \(missing)")
        }
      }

      // Speech ends at 14.8 s, so the padded input (15.2 s) crosses the 15 s window.
      let wav = try Self.speech(Self.boundaryPhrase, endingAt: 14.8)
      defer { try? FileManager.default.removeItem(at: wav) }
      let withPadding = try await Self.transcribe(padded, model: model, wav: wav)
      let without = try await Self.transcribe(plain, model: model, wav: wav)
      let missing = Self.missingWords(reference: Self.boundaryPhrase, output: withPadding)
      let duplicated = Self.duplicatedBigrams(reference: Self.boundaryPhrase, output: withPadding)
      report.append("\(model) boundary \(String(format: "%.2f", Self.duration(wav)))s "
        + "padded=\"\(withPadding)\" unpadded=\"\(without)\" paddedMissing=\(missing) "
        + "paddedDuplicated=\(duplicated) unpaddedMissing=\(Self.missingWords(reference: Self.boundaryPhrase, output: without))")
      if missing.count > 1 { failures.append("\(model) boundary missing \(missing)") }
      if !duplicated.isEmpty { failures.append("\(model) boundary duplicated \(duplicated)") }
    }
    try (report.joined(separator: "\n") + "\n").write(toFile: Self.outputPath, atomically: true, encoding: .utf8)
    #expect(failures.isEmpty, "\(failures)")
  }

  private static func transcribe(_ provider: ParakeetTranscriptionProvider, model: String, wav: URL) async throws -> String {
    try await provider.transcribe(
      fileURL: wav,
      settings: TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: model, language: "en")
    )
  }

  private static func words(_ text: String) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  private static func missingWords(reference: String, output: String) -> [String] {
    let produced = Set(words(output))
    return words(reference).filter { !produced.contains($0) }
  }

  /// Bigrams that occur more often in the output than in the reference (seam duplication).
  private static func duplicatedBigrams(reference: String, output: String) -> [String] {
    func bigrams(_ list: [String]) -> [String: Int] {
      guard list.count > 1 else { return [:] }
      var counts: [String: Int] = [:]
      for index in 0..<(list.count - 1) { counts["\(list[index]) \(list[index + 1])", default: 0] += 1 }
      return counts
    }
    let expected = bigrams(words(reference))
    return bigrams(words(output)).filter { $0.value > (expected[$0.key] ?? 0) }.map(\.key).sorted()
  }

  private static func duration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(file.length) / file.processingFormat.sampleRate
  }

  /// Synthesised 16 kHz speech, cut right after the last voiced sample (a fast release).
  /// `endingAt` prepends silence so that last word ends at that time.
  private static func speech(_ text: String, endingAt: Double? = nil, trimTrailingSilence: Bool = true) throws -> URL {
    let spoken = try say(text, rate: 175)
    defer { try? FileManager.default.removeItem(at: spoken) }
    let file = try AVAudioFile(forReading: spoken)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    if trimTrailingSilence, let last = samples.lastIndex(where: { abs($0) > 0.01 }) {
      samples = Array(samples[0...last])
    }
    if let endingAt {
      let lead = max(0, Int(endingAt * DictationAudioFixtures.sampleRate) - samples.count)
      samples = [Float](repeating: 0, count: lead) + samples
    }
    return try DictationAudioFixtures.writeWAV(samples, to: DictationAudioFixtures.temporaryURL())
  }

  private static func say(_ text: String, rate: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ww-padding-e2e-\(UUID().uuidString).wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-r", String(Int(rate)), "-o", url.path, "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return url
  }
}
