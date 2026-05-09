import Foundation

enum TextReplacement {
    struct Rule { let from: String; let to: String }

    static func parseRules(_ rules: String) -> [Rule] {
        let lines = rules.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [Rule] = []
        for line in lines where !line.isEmpty && line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            if parts.count == 2, !parts[0].isEmpty {
                out.append(Rule(from: parts[0], to: parts[1]))
            }
        }
        return out
    }

    static func apply(to text: String, withRules rulesText: String) -> String {
        let rules = parseRules(rulesText)
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = replaceWordBoundary(in: result, from: rule.from, to: rule.to)
        }
        return result
    }

    private static func replaceWordBoundary(in text: String, from: String, to: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var out = text
        var offset = 0
        for m in matches {
            let range = NSRange(location: m.range.location + offset, length: m.range.length)
            _ = (out as NSString).substring(with: range)
            // Output must exactly match the 'to' string as provided by the user
            let replacement = to
            out = (out as NSString).replacingCharacters(in: range, with: replacement)
            offset += replacement.count - m.range.length
        }
        return out
    }
}
