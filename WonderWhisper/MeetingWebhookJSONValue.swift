import Foundation

/// A JSON value whose object keys are written in insertion order. The webhook body uses this
/// instead of `JSONEncoder` so metadata always precedes the Markdown, which a receiver that
/// truncates long bodies would otherwise cut off. Strings are escaped like `JSONEncoder` with
/// `.withoutEscapingSlashes`.
indirect enum MeetingWebhookJSONValue: Sendable {
  case string(String)
  case int(Int)
  case null
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
