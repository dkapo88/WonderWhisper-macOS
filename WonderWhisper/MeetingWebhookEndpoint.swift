import Foundation

/// One user-configured webhook that receives finished meeting notes.
///
/// Only non-secret fields live here (stored as JSON in `AppConfig.defaults` under
/// `meeting.webhooks.endpoints`). The signing secret and custom header values live in the
/// Keychain; `headerNames` and `hasSecret` mirror them for display only. Fields added later
/// decode with their defaults, so endpoints saved by older builds keep today's behaviour.
struct MeetingWebhookEndpoint: Codable, Identifiable, Equatable, Hashable, Sendable {
  static let defaultMaxBodyCharacters = 3_800
  static let maxBodyCharactersRange = 1_000...1_000_000
  static let defaultPartDelaySeconds = 7
  static let partDelaySecondsRange = 0...60
  static let defaultNoteDelaySeconds = 30
  static let noteDelaySecondsRange = 0...600

  let id: UUID
  var name: String
  var url: String
  var isEnabled: Bool
  var headerNames: [String]
  var hasSecret: Bool
  /// Send the note as several sequential POSTs, each at most `maxBodyCharacters` long.
  var splitIntoParts: Bool
  /// The limit for the whole serialized body (measured in UTF-8 bytes), used only when
  /// `splitIntoParts` is on.
  var maxBodyCharacters: Int
  var content: MeetingWebhookContent
  /// Split sends only: the wait after one part is delivered before the next part is POSTed.
  var partDelaySeconds: Int
  /// Split sends only: the minimum gap between the last request of one send and the first
  /// request of the next send to this endpoint.
  var noteDelaySeconds: Int

  init(
    id: UUID = UUID(),
    name: String = "",
    url: String = "",
    isEnabled: Bool = true,
    headerNames: [String] = [],
    hasSecret: Bool = false,
    splitIntoParts: Bool = false,
    maxBodyCharacters: Int = MeetingWebhookEndpoint.defaultMaxBodyCharacters,
    content: MeetingWebhookContent = .full,
    partDelaySeconds: Int = MeetingWebhookEndpoint.defaultPartDelaySeconds,
    noteDelaySeconds: Int = MeetingWebhookEndpoint.defaultNoteDelaySeconds
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.isEnabled = isEnabled
    self.headerNames = headerNames
    self.hasSecret = hasSecret
    self.splitIntoParts = splitIntoParts
    self.maxBodyCharacters = Self.clampedMaxBody(maxBodyCharacters)
    self.content = content
    self.partDelaySeconds = Self.clamped(partDelaySeconds, to: Self.partDelaySecondsRange)
    self.noteDelaySeconds = Self.clamped(noteDelaySeconds, to: Self.noteDelaySecondsRange)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, url, isEnabled, headerNames, hasSecret
    case splitIntoParts, maxBodyCharacters, content, partDelaySeconds, noteDelaySeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    url = try container.decode(String.self, forKey: .url)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    headerNames = try container.decode([String].self, forKey: .headerNames)
    hasSecret = try container.decode(Bool.self, forKey: .hasSecret)
    splitIntoParts = try container.decodeIfPresent(Bool.self, forKey: .splitIntoParts) ?? false
    maxBodyCharacters = Self.clampedMaxBody(
      try container.decodeIfPresent(Int.self, forKey: .maxBodyCharacters)
        ?? Self.defaultMaxBodyCharacters
    )
    content = (try? container.decodeIfPresent(MeetingWebhookContent.self, forKey: .content))
      ?? .full
    partDelaySeconds = Self.clamped(
      (try? container.decodeIfPresent(Int.self, forKey: .partDelaySeconds))
        ?? Self.defaultPartDelaySeconds,
      to: Self.partDelaySecondsRange
    )
    noteDelaySeconds = Self.clamped(
      (try? container.decodeIfPresent(Int.self, forKey: .noteDelaySeconds))
        ?? Self.defaultNoteDelaySeconds,
      to: Self.noteDelaySecondsRange
    )
  }

  static func clampedMaxBody(_ value: Int) -> Int {
    clamped(value, to: maxBodyCharactersRange)
  }

  static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// How sends to this endpoint are spaced. Only split sends are paced and queued; an unsplit
  /// endpoint sends exactly as before.
  var pacing: MeetingWebhookPacing? {
    guard splitIntoParts else { return nil }
    return MeetingWebhookPacing(
      partDelay: TimeInterval(Self.clamped(partDelaySeconds, to: Self.partDelaySecondsRange)),
      noteDelay: TimeInterval(Self.clamped(noteDelaySeconds, to: Self.noteDelaySecondsRange))
    )
  }

  /// The name, or the URL host when the name is blank.
  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if let host = URL(string: url)?.host, !host.isEmpty { return host }
    return "Webhook"
  }
}
