import Foundation

/// Contents of `iCloud Drive/WonderWhisper/settings.json`.
///
/// Every synced preference is stored with its own `modifiedAt` and writer `deviceID`, so two
/// Macs editing different settings never overwrite each other; for the same setting the newest
/// edit wins. A nil `value` records that the setting was reset to its default.
struct SettingsSyncDocument: Equatable, Sendable {
  static let currentSchemaVersion = 1

  struct Entry: Codable, Equatable, Sendable {
    var value: SettingsSyncValue?
    var modifiedAt: Date
    var deviceID: String
  }

  struct Device: Codable, Equatable, Sendable {
    var name: String
    var lastWriteAt: Date
  }

  var schemaVersion: Int
  var entries: [String: Entry]
  var devices: [String: Device]

  init(
    schemaVersion: Int = SettingsSyncDocument.currentSchemaVersion,
    entries: [String: Entry] = [:],
    devices: [String: Device] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.entries = entries
    self.devices = devices
  }

  // MARK: - Encoding

  static func decode(_ data: Data) throws -> SettingsSyncDocument {
    try makeDecoder().decode(SettingsSyncDocument.self, from: data)
  }

  func encoded() throws -> Data {
    let encoder = Self.makeEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  /// Dates are whole milliseconds since 1970, encoded as integers so a timestamp read back
  /// compares exactly equal to the one written (no floating-point drift across Macs).
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(millis(date))
    }
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(Double.self)
      // Reject before converting: Int64(_:) traps on out-of-range or non-finite input.
      guard let millis = checkedMillis(value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Timestamp \(value) is outside the supported range."
        )
      }
      return date(millis: millis)
    }
    return decoder
  }

  /// Largest timestamp accepted anywhere (about the year 33658). Keeps every conversion and
  /// `+ 1` on timestamps far from Int64 overflow.
  static let maxMillis: Int64 = 1_000_000_000_000_000

  /// Milliseconds for a raw value, or nil if it isn't a finite number within ±`maxMillis`.
  static func checkedMillis(_ value: Double) -> Int64? {
    guard value.isFinite else { return nil }
    let rounded = value.rounded()
    guard abs(rounded) <= Double(maxMillis) else { return nil }
    return Int64(exactly: rounded)
  }

  /// Milliseconds since 1970 for a date, clamped into ±`maxMillis` (never traps).
  static func millis(_ date: Date) -> Int64 {
    let raw = date.timeIntervalSince1970 * 1000
    if let exact = checkedMillis(raw) { return exact }
    return raw.isNaN ? 0 : (raw > 0 ? maxMillis : -maxMillis)
  }

  static func date(millis: Int64) -> Date {
    Date(timeIntervalSince1970: Double(millis) / 1000)
  }
}

extension SettingsSyncDocument: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case entries
    case devices
  }

  /// Decodes leniently: an entry or device this build can't read (a value type from a newer
  /// version, a hand-edited typo) is dropped instead of failing the whole file.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let rawEntries = try container.decodeIfPresent(
      [String: Lossy<Entry>].self,
      forKey: .entries
    ) ?? [:]
    entries = rawEntries.compactMapValues(\.value)
    let rawDevices = try container.decodeIfPresent(
      [String: Lossy<Device>].self,
      forKey: .devices
    ) ?? [:]
    devices = rawDevices.compactMapValues(\.value)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(entries, forKey: .entries)
    try container.encode(devices, forKey: .devices)
  }

  private struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
      value = try? Wrapped(from: decoder)
    }
  }
}
