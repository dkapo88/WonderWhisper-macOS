import Foundation

/// The JSON body POSTed to a webhook (`schemaVersion` 1).
struct MeetingWebhookPayload: Encodable, Equatable, Sendable {
  struct Note: Encodable, Equatable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int
    let detectedApp: String?
    let markdown: String

    private enum CodingKeys: String, CodingKey {
      case id, title, startedAt, endedAt, durationSeconds, detectedApp, markdown
    }

    // Explicit so `endedAt` and `detectedApp` encode as `null` instead of being omitted.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(title, forKey: .title)
      try container.encode(startedAt, forKey: .startedAt)
      if let endedAt {
        try container.encode(endedAt, forKey: .endedAt)
      } else {
        try container.encodeNil(forKey: .endedAt)
      }
      try container.encode(durationSeconds, forKey: .durationSeconds)
      if let detectedApp {
        try container.encode(detectedApp, forKey: .detectedApp)
      } else {
        try container.encodeNil(forKey: .detectedApp)
      }
      try container.encode(markdown, forKey: .markdown)
    }
  }

  let event: MeetingWebhookEvent
  let schemaVersion: Int
  let deliveryId: UUID
  let sentAt: Date
  let note: Note
  let app: MeetingWebhookAppInfo

  static let currentSchemaVersion = 1
}
