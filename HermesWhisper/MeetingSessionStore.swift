import Foundation

actor MeetingSessionStore {
  private let rootDirectory: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

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

  func save(_ session: MeetingSession) throws {
    let directory = try directory(for: session.id)
    let data = try encoder.encode(session)
    try data.write(
      to: directory.appendingPathComponent("manifest.json"),
      options: .atomic
    )
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
      let recoveredAudioFiles = (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ))?.compactMap { url -> String? in
        guard url.pathExtension.lowercased() == "caf",
              url.lastPathComponent.hasPrefix("microphone-")
                || url.lastPathComponent.hasPrefix("system-") else { return nil }
        return url.lastPathComponent
      }.sorted() ?? []
      if !recoveredAudioFiles.isEmpty {
        session.audioFiles = recoveredAudioFiles
      }
      if session.status == .recording || session.status == .processing {
        session.status = .interrupted
        session.endedAt = session.endedAt ?? Date()
        session.errorMessage = "HermesWhisper stopped before this meeting was finalized."
        try? save(session)
      }
      sessions.append(session)
    }
    return sessions.sorted { $0.startedAt > $1.startedAt }
  }

  func delete(_ session: MeetingSession) throws {
    let directory = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
    if fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
  }
}
