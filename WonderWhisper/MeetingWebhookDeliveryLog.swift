import Foundation

/// Persisted webhook delivery history: a JSON file under the app support root, newest first,
/// capped at 200 records. Stores only delivery metadata, never bodies, secrets or headers.
actor MeetingWebhookDeliveryLog {
  static let maximumRecords = 200
  static let interruptedMessage = "Interrupted when WonderWhisper quit"
  static let filename = "meeting-webhook-deliveries.json"

  private let fileURL: URL
  private let fileManager: FileManager
  private var savedGeneration = Int.min

  init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = fileURL
      ?? AppStoragePaths.appSupportRoot(fileManager: fileManager)
        .appendingPathComponent(Self.filename, isDirectory: false)
  }

  /// Loads the log. Records left `sending` or `retrying` by a previous run are marked
  /// `failed` (and saved that way) so nothing hangs silently.
  func load(now: Date = Date()) -> [MeetingWebhookDeliveryRecord] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let stored = try? decoder.decode([MeetingWebhookDeliveryRecord].self, from: data) else {
      return []
    }
    let recovered = Self.markingInterrupted(stored, now: now)
    let capped = Array(recovered.prefix(Self.maximumRecords))
    if capped != stored {
      write(capped)
    }
    return capped
  }

  /// The highest `sendOrder` in the saved log, read synchronously so the center can seed its
  /// ordering counter before any send is enqueued. Nil when there is no readable log or no
  /// record carries one.
  nonisolated func highestPersistedSendOrder() -> Double? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try? decoder.decode([MeetingWebhookDeliveryRecord].self, from: data)
    return records?.compactMap(\.sendOrder).max()
  }

  /// Saves a snapshot. Snapshots are numbered by the caller so a stale one that arrives late
  /// never overwrites a newer one.
  func save(_ records: [MeetingWebhookDeliveryRecord], generation: Int) {
    guard generation > savedGeneration else { return }
    savedGeneration = generation
    write(Array(records.prefix(Self.maximumRecords)))
  }

  private func write(_ records: [MeetingWebhookDeliveryRecord]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(records) else { return }
    try? fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: fileURL, options: .atomic)
  }

  /// Replaces the record with the same ID in place, or inserts a new one at the front, then
  /// caps the list.
  static func upserting(
    _ record: MeetingWebhookDeliveryRecord,
    into records: [MeetingWebhookDeliveryRecord]
  ) -> [MeetingWebhookDeliveryRecord] {
    var updated = records
    if let index = updated.firstIndex(where: { $0.id == record.id }) {
      updated[index] = record
    } else {
      updated.insert(record, at: 0)
    }
    if updated.count > maximumRecords {
      updated.removeLast(updated.count - maximumRecords)
    }
    return updated
  }

  static func markingInterrupted(
    _ records: [MeetingWebhookDeliveryRecord],
    now: Date
  ) -> [MeetingWebhookDeliveryRecord] {
    records.map { record in
      guard record.state.isInFlight else { return record }
      var interrupted = record
      interrupted.state = .failed
      interrupted.lastError = interruptedMessage
      interrupted.updatedAt = now
      return interrupted
    }
  }
}
