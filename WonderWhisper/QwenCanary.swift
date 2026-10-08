import Foundation

/// A short known clip decoded once per Qwen load to prove the weights are real.
///
/// `qwen-canary.wav` is 2.7 s of macOS TTS ("Samantha") saying the expected
/// sentence, 16 kHz mono. A healthy 0.6B model decodes it verbatim in ~60 ms
/// warm; uninitialized weights decode it as 448 `!` tokens.
struct QwenCanary {
  static let resourceName = "qwen-canary"
  static let expectedText = "The quick brown fox jumps over the lazy dog."
  /// Normalized edit-distance similarity required to pass. Loose enough for
  /// punctuation/casing drift, far above anything garbage can reach.
  static let minimumSimilarity = 0.8
  /// The canary is 2.7 s; a healthy decode is ~10 tokens.
  static let maxTokens = 48

  struct Result: Equatable {
    let text: String
    let similarity: Double
    let passed: Bool
    let reason: String?
  }

  let samples: [Float]
  let expectedText: String

  init(samples: [Float], expectedText: String = QwenCanary.expectedText) {
    self.samples = samples
    self.expectedText = expectedText
  }

  func evaluate(_ text: String) -> Result {
    if let reason = QwenASRManager.degenerateReason(text, sampleCount: samples.count) {
      return Result(text: text, similarity: 0, passed: false, reason: reason)
    }
    let score = Self.similarity(text, expectedText)
    let passed = score >= Self.minimumSimilarity
    return Result(
      text: text,
      similarity: score,
      passed: passed,
      reason: passed ? nil : String(format: "similarity %.2f", score)
    )
  }

  /// Lowercased letters/digits with single spaces.
  static func normalize(_ text: String) -> String {
    let mapped = text.lowercased().map { ch -> Character in
      ch.isLetter || ch.isNumber ? ch : " "
    }
    return String(mapped)
      .split(separator: " ")
      .joined(separator: " ")
  }

  /// 1 - (Levenshtein distance / longer length) over normalized text.
  static func similarity(_ lhs: String, _ rhs: String) -> Double {
    let a = Array(normalize(lhs))
    let b = Array(normalize(rhs))
    let longest = max(a.count, b.count)
    guard longest > 0 else { return 1 }
    if a.isEmpty || b.isEmpty { return 0 }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return 1 - Double(previous[b.count]) / Double(longest)
  }
}
