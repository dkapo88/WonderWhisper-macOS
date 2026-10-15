import Foundation

/// The JSON body POSTed to a webhook (`schemaVersion` 1).
///
/// Keys are written in a fixed order with `note.markdown` last, so a receiver that keeps only
/// the start of a long body still gets every metadata field:
/// `event, schemaVersion, deliveryId, [sendId], sentAt, app, [part], note` and inside `note`
/// `id, title, startedAt, endedAt, durationSeconds, recordedSeconds, elapsedSeconds,
/// detectedApp, [attendees], [content], markdown`. `sendId` and `part` appear only on split
/// sends; `note.attendees` only when the meeting has attendees; `note.content` only on
/// summary-only sends. Split parts leave out `detectedApp` and `elapsedSeconds` when they are
/// null, to keep more room for the Markdown; an unsplit body always carries them.
struct MeetingWebhookPayload: Equatable, Sendable {
  struct Note: Equatable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    /// Recorded time in seconds (pauses and the gap before a Resume excluded). Kept for
    /// existing receivers; `recordedSeconds` carries the same value.
    let durationSeconds: Int
    let recordedSeconds: Int
    /// `endedAt` minus `startedAt` in seconds (wall clock, gaps included); nil while the
    /// meeting has no end.
    let elapsedSeconds: Int?
    let detectedApp: String?
    let attendees: [String]
    let content: MeetingWebhookContent
    var markdown: String

    init(
      id: UUID,
      title: String,
      startedAt: Date,
      endedAt: Date?,
      durationSeconds: Int,
      recordedSeconds: Int? = nil,
      elapsedSeconds: Int? = nil,
      detectedApp: String?,
      attendees: [String] = [],
      content: MeetingWebhookContent,
      markdown: String
    ) {
      self.id = id
      self.title = title
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.durationSeconds = durationSeconds
      self.recordedSeconds = recordedSeconds ?? durationSeconds
      self.elapsedSeconds = elapsedSeconds
      self.detectedApp = detectedApp
      self.attendees = attendees
      self.content = content
      self.markdown = markdown
    }
  }

  /// One part of a split send, 1-based.
  struct Part: Equatable, Sendable {
    let index: Int
    let total: Int

    /// The last line of the part's Markdown, also sent as `part.endMarker`, so a receiver can
    /// tell a complete part from a truncated one.
    var endMarker: String {
      Self.endMarker(index: index, total: total)
    }

    static func endMarker(index: Int, total: Int) -> String {
      "END-OF-PAYLOAD part \(index) of \(total)"
    }

    /// What follows a part's chunk of the note: a blank line, then the end marker. A receiver
    /// removes exactly this suffix to get the chunk back.
    var markdownSuffix: String {
      "\n\n" + endMarker
    }
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
      top.append(("part", .object([
        ("index", .int(part.index)),
        ("total", .int(part.total)),
        ("endMarker", .string(part.endMarker))
      ])))
    }
    let isPart = part != nil
    var noteMembers: [(key: String, value: MeetingWebhookJSONValue)] = [
      ("id", .string(note.id.uuidString)),
      ("title", .string(note.title)),
      ("startedAt", .string(Self.timestamp(note.startedAt))),
      ("endedAt", note.endedAt.map { .string(Self.timestamp($0)) } ?? .null),
      ("durationSeconds", .int(note.durationSeconds)),
      ("recordedSeconds", .int(note.recordedSeconds))
    ]
    if let elapsed = note.elapsedSeconds {
      noteMembers.append(("elapsedSeconds", .int(elapsed)))
    } else if !isPart {
      noteMembers.append(("elapsedSeconds", .null))
    }
    if let detectedApp = note.detectedApp {
      noteMembers.append(("detectedApp", .string(detectedApp)))
    } else if !isPart {
      noteMembers.append(("detectedApp", .null))
    }
    if !note.attendees.isEmpty {
      noteMembers.append(("attendees", .array(note.attendees.map { .string($0) })))
    }
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
