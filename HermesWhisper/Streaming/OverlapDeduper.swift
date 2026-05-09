import Foundation

// Overlap-aware boundary deduplication helpers used by streaming transcript assembly.
// Tokenization is intentionally simple and punctuation-insensitive.
enum OverlapDeduper {
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // Return how many tokens should be dropped from the beginning of `next`
    // because they overlap with the ending of `prev`.
    static func dropCount(prevTokens: [String], nextTokens: [String], maxK: Int = 24) -> Int {
        guard !prevTokens.isEmpty, !nextTokens.isEmpty else { return 0 }
        let k = min(maxK, prevTokens.count, nextTokens.count)
        guard k >= 3 else { return 0 }
        for m in stride(from: k, through: 3, by: -1) {
            if Array(prevTokens.suffix(m)) == Array(nextTokens.prefix(m)) {
                return m
            }
        }
        return 0
    }

    // Merge two transcripts while removing duplicated overlap at the boundary.
    static func merge(prev: String, next: String, maxK: Int = 24) -> String {
        guard !prev.isEmpty else { return next }
        guard !next.isEmpty else { return prev }
        let pT = tokens(prev)
        let nT = tokens(next)
        let drop = dropCount(prevTokens: pT, nextTokens: nT, maxK: maxK)
        if drop == 0 { return prev + " " + next }
        let words = next.split(whereSeparator: { $0.isWhitespace })
        let trimmed = words.count > drop ? words.dropFirst(drop).joined(separator: " ") : ""
        return trimmed.isEmpty ? prev : prev + " " + trimmed
    }
}

