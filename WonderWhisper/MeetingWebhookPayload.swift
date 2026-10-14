import Foundation

/// The JSON body POSTed to a webhook (`schemaVersion` 1).
///
/// Keys are written in a fixed order with `note.markdown` last, so a receiver that keeps only
/// the start of a long body still gets every metadata field:
/// `event, schemaVersion, deliveryId, [sendId], sentAt, app, [part], note` and inside `note`
/// `id, title, startedAt, endedAt, durationSeconds, detectedApp, [content], markdown`.
/// `sendId` and `part` appear only on split sends; `note.content` only on summary-only sends.
struct MeetingWebhookPayload: Equatable, Sendable {
  struct Note: Equatable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int
    let detectedApp: String?
    let content: MeetingWebhookContent
    var markdown: String
  }

  /// One part of a split send, 1-based.
  struct Part: Equatable, Sendable {
    let index: Int
    let total: Int
  }

  let event: MeetingWebhookEvent
  let schemaVersion: Int
  var deliveryId: UUID
  /// Shared by every part of one split send; nil (and omitted) when not splitting.
  var sendId: UUID?
  let sentAt: Date
  let app: MeetingWebhookAppInfo
  /// Present only on split sends.
  var part: Part?
  var note: Note

  static let currentSchemaVersion = 1

  var jsonValue: MeetingWebhookJSONValue {
    var top: [(key: String, value: MeetingWebhookJSONValue)] = [
      ("event", .string(event.rawValue)),
      ("schemaVersion", .int(schemaVersion)),
      ("deliveryId", .string(deliveryId.uuidString))
    ]
    if let sendId {
      top.append(("sendId", .string(sendId.uuidString)))
    }
    top.append(("sentAt", .string(Self.timestamp(sentAt))))
    top.append(("app", .object([
      ("name", .string(app.name)),
      ("version", .string(app.version)),
      ("build", .string(app.build))
    ])))
    if let part {
      top.append(("part", .object([("index", .int(part.index)), ("total", .int(part.total))])))
    }
    var noteMembers: [(key: String, value: MeetingWebhookJSONValue)] = [
      ("id", .string(note.id.uuidString)),
      ("title", .string(note.title)),
      ("startedAt", .string(Self.timestamp(note.startedAt))),
      ("endedAt", note.endedAt.map { .string(Self.timestamp($0)) } ?? .null),
      ("durationSeconds", .int(note.durationSeconds)),
      ("detectedApp", note.detectedApp.map { .string($0) } ?? .null)
    ]
    if note.content == .summary {
      noteMembers.append(("content", .string(note.content.rawValue)))
    }
    noteMembers.append(("markdown", .string(note.markdown)))
    top.append(("note", .object(noteMembers)))
    return .object(top)
  }

  /// The request body.
  var body: Data {
    jsonValue.data
  }

  /// ISO 8601 in UTC, the same as `JSONEncoder.DateEncodingStrategy.iso8601`.
  static func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}
