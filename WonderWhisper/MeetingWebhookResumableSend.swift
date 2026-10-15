import Foundation

/// The newest split send of one note to one endpoint, as the delivery log describes it: what
/// "Resend Missing Parts" and "Resend Parts..." work from.
struct MeetingWebhookResumableSend: Equatable, Sendable {
  let sendID: UUID
  let total: Int
  /// The newest record for each part index that has one.
  let partRecords: [Int: MeetingWebhookDeliveryRecord]

  /// Parts whose newest record is not delivered, plus parts with no record at all.
  var missingIndexes: [Int] {
    (1...max(1, total)).filter { partRecords[$0]?.state != .delivered }
  }

  /// True while any part of the send is still queued, sending or retrying.
  var isInFlight: Bool {
    partRecords.values.contains { $0.state.isInFlight }
  }

  /// A record carrying the split parameters, when the send was made by a build that stores
  /// them.
  var splitRecord: MeetingWebhookDeliveryRecord? {
    partRecords.values.sorted { ($0.partIndex ?? 0) < ($1.partIndex ?? 0) }
      .first { $0.supportsPartialResend }
  }

  /// The newest split send of `noteID` to `endpointID` in `records` (newest first), if any.
  static func latest(
    in records: [MeetingWebhookDeliveryRecord],
    noteID: UUID,
    endpointID: UUID
  ) -> MeetingWebhookResumableSend? {
    let split = records.filter {
      $0.noteID == noteID && $0.endpointID == endpointID && $0.event != .test
        && $0.partIndex != nil && $0.partTotal != nil
        // Unsplit sends are part 1 of 1 without split details.
        && ($0.isPartOfSplit || $0.contentFingerprint != nil)
    }
    var newest: MeetingWebhookDeliveryRecord?
    for record in split {
      if let current = newest, current.sendRank >= record.sendRank { continue }
      newest = record
    }
    guard let newest, let total = newest.partTotal else { return nil }
    let parts = split.filter { $0.sendKey == newest.sendKey }
    return MeetingWebhookResumableSend(
      sendID: newest.sendKey,
      total: total,
      partRecords: MeetingWebhookStatusFormatter.newestPerPart(parts)
    )
  }
}
