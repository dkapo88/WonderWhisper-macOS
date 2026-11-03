import Foundation

/// A JSON value whose object keys are written in insertion order. The webhook body uses this
/// instead of `JSONEncoder` so metadata always precedes the Markdown, which a receiver that
/// truncates long bodies would otherwise cut off. Strings are escaped like `JSONEncoder` with
/// `.withoutEscapingSlashes`.
indirect enum MeetingWebhookJSONValue: Sendable {
  case string(String)
  case int(Int)
  case null
  case array([MeetingWebhookJSONValue])
  case object([(key: String, value: MeetingWebhookJSONValue)])

  /// The compact serialized form.
  var serialized: String {
    var output = ""
    write(into: &output)
    return output
  }

  var data: Data {
    Data(serialized.utf8)
  }

  private func write(into output: inout String) {
    switch self {
    case let .string(value):
      Self.writeString(value, into: &output)
    case let .int(value):
      output += String(value)
    case .null:
      output += "null"
    case let .array(elements):
      output += "["
      for (offset, element) in elements.enumerated() {
        if offset > 0 { output += "," }
        element.write(into: &output)
      }
      output += "]"
    case let .object(members):
      output += "{"
      for (offset, member) in members.enumerated() {
        if offset > 0 { output += "," }
        Self.writeString(member.key, into: &output)
        output += ":"
        member.value.write(into: &output)
      }
      output += "}"
    }
  }

  private static func writeString(_ value: String, into output: inout String) {
    output += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      default:
        if scalar.value < 0x20 {
          let hex = String(scalar.value, radix: 16)
          output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
  }

  // MARK: - Length as JavaScript formats it

  /// The length of `JSON.stringify(JSON.parse(body), null, 2)` in JavaScript: re-indented with
  /// 2 spaces and `": "` after keys, counted in UTF-16 code units. MausBot shows its automation
  /// the payload in this form and cuts it at 48,000. Keys here are never integer-like, so
  /// JavaScript keeps their order.
  var javaScriptFormattedLength: Int {
    formattedLength(depth: 0)
  }

  private func formattedLength(depth: Int) -> Int {
    switch self {
    case let .string(value):
      return Self.javaScriptStringLength(value)
    case let .int(value):
      return String(value).utf16.count
    case .null:
      return 4
    case let .array(elements):
      guard !elements.isEmpty else { return 2 }
      // "[" then each element on its own line indented one level deeper, "," between, then
      // a newline, the closing indent and "]".
      let inner = elements.reduce(0) { total, element in
        total + 1 + 2 * (depth + 1) + element.formattedLength(depth: depth + 1)
      }
      return 1 + inner + (elements.count - 1) + 1 + 2 * depth + 1
    case let .object(members):
      guard !members.isEmpty else { return 2 }
      let inner = members.reduce(0) { total, member in
        total + 1 + 2 * (depth + 1) + Self.javaScriptStringLength(member.key) + 2
          + member.value.formattedLength(depth: depth + 1)
      }
      return 1 + inner + (members.count - 1) + 1 + 2 * depth + 1
    }
  }

  /// UTF-16 code units of `value` as `JSON.stringify` writes it, quotes included.
  static func javaScriptStringLength(_ value: String) -> Int {
    value.unicodeScalars.reduce(2) { $0 + javaScriptEscapedLength(of: $1) }
  }

  /// UTF-16 code units `scalar` takes once `JSON.stringify` escapes it: two for the short
  /// escapes, six for other control characters, else its UTF-16 width (JavaScript does not
  /// escape "/" or non-ASCII).
  static func javaScriptEscapedLength(of scalar: Unicode.Scalar) -> Int {
    switch scalar {
    case "\"", "\\", "\n", "\r", "\t", "\u{08}", "\u{0C}":
      return 2
    default:
      return scalar.value < 0x20 ? 6 : UTF16.width(scalar)
    }
  }

  /// UTF-8 bytes `scalar` takes once escaped inside a JSON string.
  static func escapedByteCount(of scalar: Unicode.Scalar) -> Int {
    switch scalar {
    case "\"", "\\", "\n", "\r", "\t", "\u{08}", "\u{0C}":
      return 2
    default:
      return scalar.value < 0x20 ? 6 : UTF8.width(scalar)
    }
  }

  /// UTF-8 bytes `character` takes once escaped inside a JSON string.
  static func escapedByteCount(of character: Character) -> Int {
    character.unicodeScalars.reduce(0) { $0 + escapedByteCount(of: $1) }
  }
}
