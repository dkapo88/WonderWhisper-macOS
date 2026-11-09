import Foundation

actor MeetingSessionStore {
  private let rootDirectory: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var manualNotesRevisions: [UUID: Int] = [:]
  private var recordingRunIDs: [UUID: UUID] = [:]

  private struct ResumeCheckpoint: Codable {
    let manifest: Data
    let manualNotes: Data?
    let filenames: Set<String>
  }

  init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.rootDirectory = rootDirectory
      ?? AppStoragePaths.appSupportRoot(fileManager: fileManager)
        .appendingPathComponent("Meetings", isDirectory: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder

    try? fileManager.createDirectory(
      at: self.rootDirectory,
      withIntermediateDirectories: true
    )
  }

  func directory(for sessionID: UUID) throws -> URL {
    let directory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Must succeed before capture or any resumed metadata is written.
  func beginRecording(_ session: MeetingSession, runID: UUID, resuming: Bool) throws {
    if !resuming {
      recordingRunIDs[session.id] = runID
      return
    }
    let directory = try directory(for: session.id)
    let notes = directory.appendingPathComponent("manual-notes.md")
    let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    guard try decoder.decode(MeetingSession.self, from: manifest).pendingDiscard == nil else {
      throw CocoaError(.fileWriteFileExists, userInfo: [
        NSLocalizedDescriptionKey: "Retry Discard before resuming this meeting."
      ])
    }
    let checkpoint = ResumeCheckpoint(
      manifest: manifest,
      manualNotes: fileManager.fileExists(atPath: notes.path) ? try Data(contentsOf: notes) : nil,
      filenames: Set(try fileManager.contentsOfDirectory(atPath: directory.path))
    )
    try encoder.encode(checkpoint).write(
      to: directory.appendingPathComponent(".resume-checkpoint.json"), options: .atomic
    )
    recordingRunIDs[session.id] = runID
  }

  func retireRecording(_ sessionID: UUID, runID: UUID) {
    if recordingRunIDs[sessionID] == runID {
      recordingRunIDs.removeValue(forKey: sessionID)
    }
  }

  /// Normal Stop has persisted its completed content; no rollback baseline is needed now.
  func finishRecording(_ session: MeetingSession) throws {
    defer { recordingRunIDs.removeValue(forKey: session.id) }
    guard session.pendingDiscard == nil else { return }
    let checkpoint = rootDirectory.appendingPathComponent(session.id.uuidString)
      .appendingPathComponent(".resume-checkpoint.json")
    if fileManager.fileExists(atPath: checkpoint.path) {
      try fileManager.removeItem(at: checkpoint)
    }
  }

  /// Serialized with saves, so neither an in-flight nor a late write can undo discard.
  func discardRecording(
    _ session: MeetingSession, runID: UUID, resuming: Bool
  ) throws -> MeetingSession? {
    retireRecording(session.id, runID: runID)
    // Persist the retry intent before any destructive work, including across app relaunch.
    var pending = session
    pending.pendingDiscard = .init(runID: runID, resuming: resuming)
    pending.status = .failed
    let endedAt = Date()
    if let startedAt = pending.recordingStartedAt {
      pending.recordedDuration = (pending.recordedDuration ?? 0)
        + max(0, endedAt.timeIntervalSince(startedAt))
    }
    pending.recordingStartedAt = nil
    pending.endedAt = pending.endedAt ?? endedAt
    pending.errorMessage = "Discard did not finish. Choose Retry Discard to finish cleanup."
    try save(pending)
    guard resuming else {
      // Keep the retry manifest discoverable until every audio/sidecar file is gone.
      let directory = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
      for file in try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ) where file.lastPathComponent != "manifest.json" {
        try fileManager.removeItem(at: file)
      }
      try delete(session)
      return nil
    }
    let directory = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
    let checkpointURL = directory.appendingPathComponent(".resume-checkpoint.json")
    let checkpoint = try decoder.decode(
      ResumeCheckpoint.self, from: Data(contentsOf: checkpointURL)
    )
    var restored = try decoder.decode(MeetingSession.self, from: checkpoint.manifest)
    // Capture never overwrites an earlier segment. Delete only this run's additions.
    for filename in try fileManager.contentsOfDirectory(atPath: directory.path)
      where filename != checkpointURL.lastPathComponent && !checkpoint.filenames.contains(filename) {
      try fileManager.removeItem(at: directory.appendingPathComponent(filename))
    }
    let notes = directory.appendingPathComponent("manual-notes.md")
    if let originalNotes = checkpoint.manualNotes {
      try originalNotes.write(to: notes, options: .atomic)
      let text = String(data: originalNotes, encoding: .utf8) ?? ""
      restored.manualNotesMarkdown = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : text
    } else if fileManager.fileExists(atPath: notes.path) {
      try fileManager.removeItem(at: notes)
    }
    try checkpoint.manifest.write(
      to: directory.appendingPathComponent("manifest.json"), options: .atomic
    )
    // Restoring the manifest commits rollback and clears its durable pending request.
    // Cleanup cannot turn that success back into a failed discard; a stale checkpoint
    // is safe to replace on the next resume now that the original state is restored.
    try? fileManager.removeItem(at: checkpointURL)
    manualNotesRevisions.removeValue(forKey: session.id)
    return restored
  }

  @discardableResult
  func save(_ session: MeetingSession, runID: UUID? = nil) throws -> Bool {
    if let runID, recordingRunIDs[session.id] != runID { return false }
    let directory = try directory(for: session.id)
    let data = try encoder.encode(session)
    try data.write(
      to: directory.appendingPathComponent("manifest.json"),
      options: .atomic
    )
    return true
  }

  func audioFiles(for sessionID: UUID) -> [String] {
    let directory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    return retainedAudioURLs(in: directory).map(\.lastPathComponent).sorted()
  }

  func saveManualNotes(
    _ notes: String?, for sessionID: UUID, revision: Int, runID: UUID? = nil
  ) throws {
    if let runID, recordingRunIDs[sessionID] != runID { return }
    let directory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    guard fileManager.fileExists(atPath: directory.path),
          revision >= (manualNotesRevisions[sessionID] ?? 0) else { return }
    manualNotesRevisions[sessionID] = revision
    let file = directory.appendingPathComponent("manual-notes.md")
    try Data((notes ?? "").utf8).write(to: file, options: .atomic)
  }

  func loadAll() -> [MeetingSession] {
    guard let directories = try? fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var sessions: [MeetingSession] = []
    for directory in directories {
      let manifest = directory.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifest),
            var session = try? decoder.decode(MeetingSession.self, from: data) else {
        continue
      }
      let manualNotesFile = directory.appendingPathComponent("manual-notes.md")
      if let notesData = try? Data(contentsOf: manualNotesFile),
         let manualNotes = String(data: notesData, encoding: .utf8) {
        session.manualNotesMarkdown = manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty ? nil : manualNotes
      }
      let retainedAudioURLs = retainedAudioURLs(in: directory)
      let recoveredAudioFiles = retainedAudioURLs.map(\.lastPathComponent).sorted()
      if !recoveredAudioFiles.isEmpty {
        session.audioFiles = recoveredAudioFiles
      }
      if session.status == .recording || session.status == .processing {
        if let recordingStartedAt = session.recordingStartedAt {
          let lastAudioWrite = retainedAudioURLs.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey])
              .contentModificationDate
          }.max() ?? recordingStartedAt
          let interruptionDate = min(Date(), max(recordingStartedAt, lastAudioWrite))
          session.recordedDuration = (session.recordedDuration ?? 0)
            + max(0, interruptionDate.timeIntervalSince(recordingStartedAt))
          session.recordingStartedAt = nil
          session.endedAt = interruptionDate
        }
        session.status = .interrupted
        session.endedAt = session.endedAt ?? Date()
        session.errorMessage = "WonderWhisper stopped before this meeting was finalized."
        _ = try? save(session)
      }
      sessions.append(session)
    }
    return sessions.sorted { $0.startedAt > $1.startedAt }
  }

  private func retainedAudioURLs(in directory: URL) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ))?.filter { url in
      url.pathExtension.lowercased() == "caf"
        && (url.lastPathComponent.hasPrefix("microphone-")
          || url.lastPathComponent.hasPrefix("system-"))
    } ?? []
  }

  func delete(_ session: MeetingSession) throws {
    let directory = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
    if fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
    manualNotesRevisions.removeValue(forKey: session.id)
    recordingRunIDs.removeValue(forKey: session.id)
  }
}
