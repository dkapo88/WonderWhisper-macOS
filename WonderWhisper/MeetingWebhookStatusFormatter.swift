import Foundation

/// User-facing text for webhook delivery records.
enum MeetingWebhookStatusFormatter {
  static func text(for record: MeetingWebhookDeliveryRecord, now: Date = Date()) -> String {
    let name = record.endpointName
    switch record.state {
    case .sending:
      return "Sending to \(name)…"
    case .retrying:
      let next = min(record.attempts + 1, record.maximumAttempts)
      return "Retrying \(name) (attempt \(next) of \(record.maximumAttempts))"
    case .delivered:
      return "Sent to \(name) \(relative(record.updatedAt, now: now))"
    case .failed:
      return "\(name) failed: \(failureReason(for: record))"
    }
  }

  static func failureReason(for record: MeetingWebhookDeliveryRecord) -> String {
    if let error = record.lastError, !error.isEmpty { return error }
    if let status = record.lastStatusCode { return "HTTP \(status)" }
    return "Unknown error"
  }

  static func relative(_ date: Date, now: Date) -> String {
    if now.timeIntervalSince(date) < 60 { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  /// The newest record per endpoint for one note, in endpoint-name order.
  static func latestPerEndpoint(
    _ records: [MeetingWebhookDeliveryRecord],
    noteID: UUID
  ) -> [MeetingWebhookDeliveryRecord] {
    var latest: [UUID: MeetingWebhookDeliveryRecord] = [:]
    for record in records where record.noteID == noteID && record.event != .test {
      if let existing = latest[record.endpointID], existing.createdAt >= record.createdAt {
        continue
      }
      latest[record.endpointID] = record
    }
    return latest.values.sorted {
      $0.endpointName.localizedCaseInsensitiveCompare($1.endpointName) == .orderedAscending
    }
  }
}
