import Foundation

/// Contents of `iCloud Drive/WonderWhisper/settings.json`.
///
/// Every synced preference is stored with its own `modifiedAt` and writer `deviceID`, so two
/// Macs editing different settings never overwrite each other; for the same setting the newest
/// edit wins. A nil `value` records that the setting was reset to its default.
struct SettingsSyncDocument: Equatable {
  static let currentSchemaVersion = 1

  struct Entry: Codable, Equatable {
    var value: SettingsSyncValue?
    var modifiedAt: Date
    var deviceID: String
  }

  struct Device: Codable, Equatable {
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
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(SettingsSyncDocument.self, from: data)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
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
