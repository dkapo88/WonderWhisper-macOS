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
        durationSeconds: Self.seconds(session.duration),
        recordedSeconds: Self.seconds(session.duration),
        elapsedSeconds: session.elapsed.map(Self.seconds),
        detectedApp: session.detectedApp,
        attendees: session.attendees,
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
    try plan(
      for: session,
      event: event,
      endpoint: endpoint,
      sendID: sendID,
      sentAt: sentAt,
      makeDeliveryID: makeDeliveryID
    ).payloads
  }

  /// The payloads of one send plus, for a split send, what a later partial resend needs to
  /// prove it cuts the same note the same way.
  func plan(
    for session: MeetingSession,
    event: MeetingWebhookEvent,
    endpoint: MeetingWebhookEndpoint,
    sendID: UUID,
    sentAt: Date,
    makeDeliveryID: () -> UUID = { UUID() }
  ) throws -> MeetingWebhookSendPlan {
    let base = payload(
      for: session,
      event: event,
      deliveryID: makeDeliveryID(),
      sentAt: sentAt,
      content: endpoint.content
    )
    guard endpoint.splitIntoParts else {
      return MeetingWebhookSendPlan(payloads: [base], split: nil)
    }
    let maxBytes = MeetingWebhookEndpoint.clampedMaxBody(endpoint.maxBodyCharacters)
    let split = try MeetingWebhookPayloadSplitter.split(
      of: base,
      sendID: sendID,
      maxBytes: maxBytes,
      makeDeliveryID: makeDeliveryID
    )
    let info = MeetingWebhookSplitInfo(
      contentFingerprint: MeetingWebhookFingerprint.of(base.note.markdown),
      content: endpoint.content,
      maxBodyCharacters: maxBytes,
      chunkBudget: split.chunkBudget,
      partFingerprints: split.chunks.map(MeetingWebhookFingerprint.of)
    )
    return MeetingWebhookSendPlan(payloads: split.parts, split: info)
  }

  /// The request body: compact JSON with keys in the documented order, `note.markdown` last.
  static func encode(_ payload: MeetingWebhookPayload) -> Data {
    payload.body
  }

  static func seconds(_ interval: TimeInterval) -> Int {
    max(0, Int(interval.rounded()))
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
