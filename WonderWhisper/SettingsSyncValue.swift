import Foundation
import CryptoKit

/// One preference value as stored in the iCloud settings file. Mirrors the plist types the
/// app actually writes to UserDefaults; anything else is skipped rather than guessed at.
enum SettingsSyncValue: Equatable, Sendable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case strings([String])
  case data(Data)

  /// Converts a raw `UserDefaults.object(forKey:)` result. Returns nil for unsupported types.
  init?(defaultsObject object: Any) {
    switch object {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if CFNumberIsFloatType(number) {
        self = .double(number.doubleValue)
      } else {
        self = .int(number.intValue)
      }
    case let string as String:
      self = .string(string)
    case let data as Data:
      self = .data(data)
    case let array as [Any]:
      let strings = array.compactMap { $0 as? String }
      guard strings.count == array.count else { return nil }
      self = .strings(strings)
    default:
      return nil
    }
  }

  var defaultsObject: Any {
    switch self {
    case .bool(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .string(let value): return value
    case .strings(let value): return value
    case .data(let value): return value
    }
  }

  static func read(_ key: String, from defaults: UserDefaults) -> SettingsSyncValue? {
    guard let object = defaults.object(forKey: key) else { return nil }
    return SettingsSyncValue(defaultsObject: object)
  }

  /// Writes the value, or removes the key for nil (a synced "reset to default").
  static func write(_ value: SettingsSyncValue?, key: String, to defaults: UserDefaults) {
    if let value {
      defaults.set(value.defaultsObject, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  /// Stable digest used to tell whether a value really changed. JSON blobs are compared by
  /// content, so re-encoding the same struct with a different key order is not a change.
  var fingerprint: String {
    let canonical: Data
    switch self {
    case .bool(let value): canonical = Data("b:\(value)".utf8)
    case .int(let value): canonical = Data("i:\(value)".utf8)
    case .double(let value): canonical = Data("d:\(value)".utf8)
    case .string(let value): canonical = Data("s:\(value)".utf8)
    case .strings(let value): canonical = Data(("a:" + value.joined(separator: "\u{1F}")).utf8)
    case .data(let value): canonical = Self.canonicalData(value)
    }
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }

  static func fingerprint(of value: SettingsSyncValue?) -> String? {
    value?.fingerprint
  }

  private static func canonicalData(_ data: Data) -> Data {
    if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
       let sorted = try? JSONSerialization.data(
         withJSONObject: object,
         options: [.sortedKeys, .fragmentsAllowed]
       ) {
      return Data("j:".utf8) + sorted
    }
    return Data("x:".utf8) + data
  }
}

extension SettingsSyncValue: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  private enum Kind: String, Codable {
    case bool
    case int
    case double
    case string
    case strings
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
    case .int: self = .int(try container.decode(Int.self, forKey: .value))
    case .double: self = .double(try container.decode(Double.self, forKey: .value))
    case .string: self = .string(try container.decode(String.self, forKey: .value))
    case .strings: self = .strings(try container.decode([String].self, forKey: .value))
    case .data: self = .data(try container.decode(Data.self, forKey: .value))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .bool(let value):
      try container.encode(Kind.bool, forKey: .type)
      try container.encode(value, forKey: .value)
    case .int(let value):
      try container.encode(Kind.int, forKey: .type)
      try container.encode(value, forKey: .value)
    case .double(let value):
      try container.encode(Kind.double, forKey: .type)
      try container.encode(value, forKey: .value)
    case .string(let value):
      try container.encode(Kind.string, forKey: .type)
      try container.encode(value, forKey: .value)
    case .strings(let value):
      try container.encode(Kind.strings, forKey: .type)
      try container.encode(value, forKey: .value)
    case .data(let value):
      try container.encode(Kind.data, forKey: .type)
      try container.encode(value, forKey: .value)
    }
  }
}
