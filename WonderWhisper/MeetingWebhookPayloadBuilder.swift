import Foundation

/// Builds webhook payloads from meeting sessions. `note.markdown` is the same document the
/// Obsidian export writes (`MeetingObsidianExporter.document(for:)`), without the transcript
/// for summary-only endpoints.
struct MeetingWebhookPayloadBuilder: Sendable {
  let appInfo: MeetingWebhookAppInfo

  init(appInfo: MeetingWebhookAppInfo = .current) {
    self.appInfo = appInfo
  }

  /// The single, unsplit payload.
  func payload(
    for session: MeetingSession,
    event: MeetingWebhookEvent,
    deliveryID: UUID,
    sentAt: Date,
    content: MeetingWebhookContent = .full
  ) -> MeetingWebhookPayload {
    MeetingWebhookPayload(
      event: event,
      schemaVersion: MeetingWebhookPayload.currentSchemaVersion,
      deliveryId: deliveryID,
      sendId: nil,
      sentAt: sentAt,
      app: appInfo,
      part: nil,
      note: MeetingWebhookPayload.Note(
        id: session.id,
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        durationSeconds: max(0, Int(session.duration.rounded())),
        detectedApp: session.detectedApp,
        content: content,
        markdown: MeetingObsidianExporter.document(
          for: session,
          includeTranscript: content == .full
        )
      )
    )
  }

  /// The payloads one send to `endpoint` POSTs, in order: one unsplit payload, or the parts
  /// when the endpoint splits. Throws `MeetingWebhookPayloadSplitter.SplitError` when the
  /// endpoint's body limit can't fit even the metadata.
  func payloads(
    for session: MeetingSession,
    event: MeetingWebhookEvent,
    endpoint: MeetingWebhookEndpoint,
    sendID: UUID,
    sentAt: Date,
    makeDeliveryID: () -> UUID = { UUID() }
  ) throws -> [MeetingWebhookPayload] {
    let base = payload(
      for: session,
      event: event,
      deliveryID: makeDeliveryID(),
      sentAt: sentAt,
      content: endpoint.content
    )
    guard endpoint.splitIntoParts else { return [base] }
    return try MeetingWebhookPayloadSplitter.parts(
      of: base,
      sendID: sendID,
      maxBytes: MeetingWebhookEndpoint.clampedMaxBody(endpoint.maxBodyCharacters),
      makeDeliveryID: makeDeliveryID
    )
  }

  /// The request body: compact JSON with keys in the documented order, `note.markdown` last.
  static func encode(_ payload: MeetingWebhookPayload) -> Data {
    payload.body
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
