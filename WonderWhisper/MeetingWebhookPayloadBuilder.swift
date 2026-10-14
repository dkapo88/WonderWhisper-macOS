import Foundation

/// Builds webhook payloads from meeting sessions. The `markdown` field is the same document
/// the Obsidian export writes (`MeetingObsidianExporter.document(for:)`).
struct MeetingWebhookPayloadBuilder: Sendable {
  let appInfo: MeetingWebhookAppInfo

  init(appInfo: MeetingWebhookAppInfo = .current) {
    self.appInfo = appInfo
  }

  func payload(
    for session: MeetingSession,
    event: MeetingWebhookEvent,
    deliveryID: UUID,
    sentAt: Date
  ) -> MeetingWebhookPayload {
    MeetingWebhookPayload(
      event: event,
      schemaVersion: MeetingWebhookPayload.currentSchemaVersion,
      deliveryId: deliveryID,
      sentAt: sentAt,
      note: MeetingWebhookPayload.Note(
        id: session.id,
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        durationSeconds: max(0, Int(session.duration.rounded())),
        detectedApp: session.detectedApp,
        markdown: MeetingObsidianExporter.document(for: session)
      ),
      app: appInfo
    )
  }

  static func encode(_ payload: MeetingWebhookPayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(payload)
  }

  /// A short sample note for "Send Test".
  static func sampleSession(now: Date = Date()) -> MeetingSession {
    let startedAt = now.addingTimeInterval(-15 * 60)
    return MeetingSession(
      title: "WonderWhisper webhook test",
      startedAt: startedAt,
      endedAt: now,
      recordedDuration: 15 * 60,
      detectedApp: nil,
      status: .completed,
      transcriptTokens: [
        MeetingTranscriptToken(
          source: .microphone,
          startTime: 0,
          endTime: 4,
          text: "This is a test delivery from WonderWhisper."
        )
      ],
      notesMarkdown: """
      ## Summary

      - This is a test payload sent from Settings > Meetings > Webhooks.
      """
    )
  }
}
