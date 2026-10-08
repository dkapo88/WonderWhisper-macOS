import Foundation

/// Contents of `iCloud Drive/WonderWhisper/settings.json`.
///
/// Every synced preference is stored with the version (Lamport `counter`, writer
/// `deviceID`) of the genuine edit that produced it. For one setting
/// the higher version wins; two Macs editing different settings never overwrite each other.
/// Wall-clock time is never used for ordering. A nil `value` records that the setting was reset
/// to its default.
///
/// Entries this build can't decode (an unknown value type, a counter outside `0...2^40`) are
/// kept verbatim in `opaqueEntries` and written back unchanged: their provenance can't be
/// established, so their keys are blocked (not applied, not overwritten) until the user
/// repairs them.
///
/// Schema 2 replaced schema 1's wall-clock `modifiedAt` with `counter`. Schema 1 entries are
/// read with counter 0 (their ordering is discarded; their values are kept). Schema 3 protects
/// the simplified counter format from older development builds that only write schema 2.
struct SettingsSyncDocument: Equatable, Sendable {
  static let currentSchemaVersion = 3

  /// Largest counter accepted (2^40). Counters only grow by one per edit, so honest use can't
  /// reach it; anything above is an invalid entry (preserved, key blocked until repaired). A
  /// Mac that would have to stamp above it stops and blocks further changes
  /// rather than reuse a version.
  static let maxCounter: Int64 = 1 << 40

  struct Entry: Equatable, Sendable {
    var value: SettingsSyncValue?
    var counter: Int64
    /// The device that made the edit (not necessarily the device that last wrote the file).
    var deviceID: String

    init(value: SettingsSyncValue?, counter: Int64, deviceID: String) {
      self.value = value
      self.counter = counter
      self.deviceID = deviceID
    }

    init(value: SettingsSyncValue?, version: SettingsSyncVersion) {
      self.init(
        value: value,
        counter: version.counter,
        deviceID: version.writer
      )
    }

    var version: SettingsSyncVersion { SettingsSyncVersion(counter, deviceID) }
  }

  struct Device: Codable, Equatable, Sendable {
    var name: String
    var lastWriteAt: Date
  }

  var schemaVersion: Int
  var entries: [String: Entry]
  var devices: [String: Device]
  /// Raw JSON of entries that couldn't be decoded, preserved byte-for-byte in meaning.
  var opaqueEntries: [String: Data] = [:]

  init(
    schemaVersion: Int = SettingsSyncDocument.currentSchemaVersion,
    entries: [String: Entry] = [:],
    devices: [String: Device] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.entries = entries
    self.devices = devices
  }

  /// Highest version among decoded entries (nil when empty).
  var highestVersion: SettingsSyncVersion? { entries.values.map(\.version).max() }

  // MARK: - Encoding

  static func decode(_ data: Data) throws -> SettingsSyncDocument {
    var document = try makeDecoder().decode(SettingsSyncDocument.self, from: data)
    // Keep every entry the typed decoder dropped, as raw JSON.
    if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let rawEntries = root["entries"] as? [String: Any] {
      for (key, raw) in rawEntries where document.entries[key] == nil {
        if let bytes = try? JSONSerialization.data(
          withJSONObject: raw,
          options: [.fragmentsAllowed, .sortedKeys]
        ) {
          document.opaqueEntries[key] = bytes
        }
      }
    }
    return document
  }

  func encoded() throws -> Data {
    let encoder = Self.makeEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let typed = try encoder.encode(self)
    guard !opaqueEntries.isEmpty else { return typed }
    guard var root = try JSONSerialization.jsonObject(with: typed) as? [String: Any] else {
      return typed
    }
    var entries = root["entries"] as? [String: Any] ?? [:]
    for (key, bytes) in opaqueEntries where entries[key] == nil {
      entries[key] = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
    }
    root["entries"] = entries
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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

  /// Largest display timestamp accepted (about the year 33658).
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

  /// Decodes leniently: an entry or device this build can't read is skipped here instead of
  /// failing the whole file (`decode(_:)` then keeps skipped entries as opaque raw JSON).
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
