import Foundation

/// User-facing text for webhook delivery records.
enum MeetingWebhookStatusFormatter {
  static func text(for record: MeetingWebhookDeliveryRecord, now: Date = Date()) -> String {
    let name = record.endpointName
    if record.state == .delivered, let notice = receiverNotice(for: record) {
      return notice
    }
    guard record.isPartOfSplit, let index = record.partIndex, let total = record.partTotal else {
      switch record.state {
      case .queued:
        return queuedText(for: record, now: now)
      case .sending:
        return "Sending to \(name)…"
      case .retrying:
        return "Retrying \(name) (\(attemptText(record)))"
      case .delivered:
        return "Sent to \(name) \(relative(record.updatedAt, now: now))"
      case .failed:
        return "\(name) failed: \(failureReason(for: record))"
      }
    }
    let part = "part \(index) of \(total)"
    switch record.state {
    case .queued:
      return queuedText(for: record, now: now)
    case .sending:
      return "Sending \(name) \(part)"
    case .retrying:
      return "Retrying \(name) \(part) (\(attemptText(record)))"
    case .delivered:
      let when = relative(record.updatedAt, now: now)
      return index == total
        ? "Sent to \(name) (\(total) parts) \(when)"
        : "Sent \(name) \(part) \(when)"
    case .failed:
      if record.isSkipped {
        return "\(name) \(part) not sent: \(failureReason(for: record))"
      }
      return "\(name) failed at \(part): \(failureReason(for: record))"
    }
  }

  /// The receiver accepted the request but did not act on it: its event filter ignored the
  /// event, or its automation is off and it only saved the request as a setup check. Nil for an
  /// ordinary delivery (a duplicate counts as ordinary).
  static func receiverNotice(for record: MeetingWebhookDeliveryRecord) -> String? {
    let name = record.endpointName
    switch record.receiverOutcome {
    case .ignored:
      return "Reached \(name), but it ignored this event type"
    case .captured:
      return "Reached \(name). Its automation is off, so it saved this as a setup check only"
    case .duplicate, nil:
      return nil
    }
  }

  /// "Queued for Notes Bot (behind 1 note)", "Queued for Notes Bot (next in 25s)", or for a
  /// later part waiting out the delay between parts "Sending Notes Bot part 3 of 5 (next in
  /// 7s)".
  private static func queuedText(for record: MeetingWebhookDeliveryRecord, now: Date) -> String {
    let name = record.endpointName
    if record.isRateLimitWait == true, let until = record.nextAttemptAt {
      return "Waiting for \(name) rate limit (\(shortDuration(until: until, now: now)))"
    }
    if let behind = record.queuedBehind, behind > 0 {
      return "Queued for \(name) (behind \(behind) \(behind == 1 ? "note" : "notes"))"
    }
    let wait = record.nextAttemptAt.map { " (next in \(seconds(until: $0, now: now))s)" } ?? ""
    if record.isPartOfSplit, let index = record.partIndex, let total = record.partTotal,
       index > 1 {
      return "Sending \(name) part \(index) of \(total)\(wait)"
    }
    return "Queued for \(name)\(wait)"
  }

  /// "45s" under a minute, else whole minutes rounded up ("4m").
  private static func shortDuration(until date: Date, now: Date) -> String {
    let remaining = seconds(until: date, now: now)
    return remaining < 60 ? "\(remaining)s" : "\((remaining + 59) / 60)m"
  }

  private static func seconds(until date: Date, now: Date) -> Int {
    max(0, Int(date.timeIntervalSince(now).rounded(.up)))
  }

  private static func attemptText(_ record: MeetingWebhookDeliveryRecord) -> String {
    let next = min(record.attempts + 1, record.maximumAttempts)
    return "attempt \(next) of \(record.maximumAttempts)"
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

  /// One record per endpoint for one note, in endpoint-name order, chosen by `latestSend(in:)`.
  static func latestPerEndpoint(
    _ records: [MeetingWebhookDeliveryRecord],
    noteID: UUID
  ) -> [MeetingWebhookDeliveryRecord] {
    let relevant = records.filter { $0.noteID == noteID && $0.event != .test }
    let byEndpoint = Dictionary(grouping: relevant, by: \.endpointID)
    let summaries = byEndpoint.values.compactMap { latestSend(in: $0) }
    return summaries.sorted {
      $0.endpointName.localizedCaseInsensitiveCompare($1.endpointName) == .orderedAscending
    }
  }

  /// The record describing the newest send among `records` (newest first, as the delivery log
  /// keeps them). Sends are ranked by `sendRank`, which is fixed when a send is enqueued, so an
  /// older send that resumes after a newer one never takes its place; ties keep the earlier
  /// record in the list. Within the send, see `representative(of:)`. A partial resend reuses
  /// its send's ID with a newer rank, so it brings the whole send back to the top.
  static func latestSend(
    in records: [MeetingWebhookDeliveryRecord]
  ) -> MeetingWebhookDeliveryRecord? {
    var newest: MeetingWebhookDeliveryRecord?
    for record in records {
      if let current = newest, current.sendRank >= record.sendRank { continue }
      newest = record
    }
    guard let newest else { return nil }
    return representative(of: records.filter { $0.sendKey == newest.sendKey })
  }

  /// The record that best describes one send, from the newest record of every part (by index):
  /// while a part is still queued, sending or retrying, the first such part (the send's
  /// progress); then the first part the receiver ignored, else the first it only captured as a
  /// setup check, so one such part shows on the send's status even when another part failed
  /// (the reason is usually the same: a receiver that ignores or parks the event); then the
  /// first failed part; else the last part.
  static func representative(
    of parts: [MeetingWebhookDeliveryRecord]
  ) -> MeetingWebhookDeliveryRecord? {
    let newest = newestPerPart(parts)
    let ordered = newest.keys.sorted().compactMap { newest[$0] }
    if let pending = ordered.first(where: { $0.state.isInFlight }) { return pending }
    return ordered.first { $0.state == .delivered && $0.receiverOutcome == .ignored }
      ?? ordered.first { $0.state == .delivered && $0.receiverOutcome == .captured }
      ?? ordered.first { $0.state == .failed }
      ?? ordered.last
  }

  /// The newest record for each part index (unsplit records count as part 1). A partial
  /// resend adds newer records for some parts of a send; ranks break ties, then list order
  /// (newest first).
  static func newestPerPart(
    _ parts: [MeetingWebhookDeliveryRecord]
  ) -> [Int: MeetingWebhookDeliveryRecord] {
    var newest: [Int: MeetingWebhookDeliveryRecord] = [:]
    for record in parts {
      let index = record.partIndex ?? 1
      if let current = newest[index], current.sendRank >= record.sendRank { continue }
      newest[index] = record
    }
    return newest
  }
}
