import Foundation

/// Contents of `iCloud Drive/WonderWhisper/settings.json`.
///
/// Every synced preference is stored with its own Lamport `counter` and writer `deviceID`, so
/// two Macs editing different settings never overwrite each other; for the same setting the
/// edit with the higher (counter, deviceID) wins. Wall-clock time is never used for ordering.
/// A nil `value` records that the setting was reset to its default.
///
/// Schema 2 replaced schema 1's wall-clock `modifiedAt` with `counter`. Schema 1 entries are
/// read with counter 0 (their ordering is discarded; their values are kept).
struct SettingsSyncDocument: Equatable, Sendable {
  static let currentSchemaVersion = 2

  /// Largest counter accepted (2^53, exact in every JSON implementation). Counters are only
  /// ever incremented by one per edit, so this is unreachable honestly; keeping far below
  /// Int64.max means `+ 1` can never overflow.
  static let maxCounter: Int64 = 1 << 53

  struct Entry: Equatable, Sendable {
    var value: SettingsSyncValue?
    var counter: Int64
    var deviceID: String

    /// Ordering for last-writer-wins: higher counter, then higher device ID.
    func isNewer(than other: Entry) -> Bool {
      SettingsSyncMerger.isNewer(counter, deviceID, than: other.counter, other.deviceID)
    }
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

  /// Dates (display-only metadata such as a device's last write) are whole milliseconds since
  /// 1970, encoded as integers.
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

extension SettingsSyncDocument.Entry: Codable {
  private enum CodingKeys: String, CodingKey {
    case value
    case counter
    case deviceID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    value = try container.decodeIfPresent(SettingsSyncValue.self, forKey: .value)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    // Missing in schema 1 (ordering discarded). JSONDecoder throws, rather than traps, on a
    // number that doesn't fit Int64; the range check rejects negatives and absurd values.
    let counter = try container.decodeIfPresent(Int64.self, forKey: .counter) ?? 0
    guard (0...SettingsSyncDocument.maxCounter).contains(counter) else {
      throw DecodingError.dataCorruptedError(
        forKey: .counter,
        in: container,
        debugDescription: "Counter \(counter) is outside the supported range."
      )
    }
    self.counter = counter
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(value, forKey: .value)
    try container.encode(counter, forKey: .counter)
    try container.encode(deviceID, forKey: .deviceID)
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
