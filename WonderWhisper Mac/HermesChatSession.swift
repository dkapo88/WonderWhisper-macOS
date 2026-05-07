import Foundation
import OSLog

struct HermesChatSession: Identifiable, Codable, Equatable {
  enum Status: String, Codable, Equatable {
    case open
    case waiting
    case responded
    case error
    case interrupted
    case archived
    case closed
  }

  var id: UUID
  var title: String
  var conversationName: String
  var serverSessionID: String?
  var createdAt: Date
  var updatedAt: Date
  var status: Status
  var messages: [HermesChatMessage]

  init(id: UUID = UUID(),
       title: String = "New Hermes Task",
       conversationName: String,
       serverSessionID: String? = nil,
       createdAt: Date = Date(),
       updatedAt: Date = Date(),
       status: Status = .open,
       messages: [HermesChatMessage] = []) {
    self.id = id
    self.title = title
    self.conversationName = conversationName
    self.serverSessionID = serverSessionID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.status = status
    self.messages = messages
  }

  var lastMessagePreview: String {
    messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  var latestAssistantMessage: HermesChatMessage? {
    messages.last(where: { $0.role == .assistant || $0.role == .error })
  }

  var canReply: Bool {
    status != .waiting && !isArchived
  }

  var isArchived: Bool {
    status == .archived || status == .closed
  }
}

enum HermesHotkeyTarget: Equatable {
  case newSession
  case reply(UUID)
}

enum HermesSessionRouting {
  static func hotkeyTarget(
    focusedSessionID: UUID?,
    visibleResponseSessionIDs: [UUID]
  ) -> HermesHotkeyTarget {
    guard !visibleResponseSessionIDs.isEmpty else {
      return .newSession
    }

    if let focusedSessionID, visibleResponseSessionIDs.contains(focusedSessionID) {
      return .reply(focusedSessionID)
    }

    if let mostRecent = visibleResponseSessionIDs.last {
      return .reply(mostRecent)
    }

    return .newSession
  }
}

enum HermesSessionRecovery {
  static func recoverAfterAppLaunch(_ sessions: [HermesChatSession]) -> [HermesChatSession] {
    sessions.map { session in
      session.status == .waiting ? interrupt(session) : session
    }
  }

  static func interrupt(_ session: HermesChatSession) -> HermesChatSession {
    var interrupted = session
    interrupted.status = .interrupted
    return interrupted
  }
}

enum HermesSessionLifecycle {
  static func activeSessions(_ sessions: [HermesChatSession]) -> [HermesChatSession] {
    sessions.filter { !$0.isArchived }
  }

  static func archivedSessions(_ sessions: [HermesChatSession]) -> [HermesChatSession] {
    sessions.filter(\.isArchived)
  }

  static func archive(_ session: HermesChatSession) -> HermesChatSession {
    var archived = session
    archived.status = .archived
    archived.updatedAt = Date()
    return archived
  }

  static func restore(_ session: HermesChatSession) -> HermesChatSession {
    var restored = session
    restored.status = restoredStatus(for: session)
    restored.updatedAt = Date()
    return restored
  }

  private static func restoredStatus(for session: HermesChatSession) -> HermesChatSession.Status {
    switch session.messages.last?.role {
    case .assistant:
      return .responded
    case .error:
      return .error
    case .user:
      return .interrupted
    case nil:
      return .open
    }
  }
}

enum HermesSessionNaming {
  static func conversationName(base: String, id: UUID) -> String {
    let prefix = sanitizedPrefix(base)
    let suffix = id.uuidString
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .suffix(12)
    return "\(prefix)-\(suffix)"
  }

  static func title(for text: String) -> String {
    let words = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .prefix(6)
      .map(String.init)
      .joined(separator: " ")

    if words.isEmpty {
      return "New Hermes Task"
    }

    return words.count > 54 ? String(words.prefix(51)) + "..." : words
  }

  private static func sanitizedPrefix(_ value: String) -> String {
    let folded = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()

    let scalars = folded.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) {
        return Character(scalar)
      }
      return "-"
    }
    let compacted = String(scalars)
      .split(separator: "-")
      .joined(separator: "-")

    return compacted.isEmpty ? AppConfig.defaultHermesConversationName : compacted
  }
}

@MainActor
final class HermesSessionStore {
  static let defaultMaxMessagesPerSession = 50
  static let defaultMaxSessions = 25
  static let defaultsMaxMessagesKey = "hermes.chat.maxMessages"
  static let defaultsMaxSessionsKey = "hermes.sessions.maxSessions"

  private let directory: URL
  private let fileURL: URL
  private let legacyMessagesURL: URL
  private let maxMessagesPerSession: Int
  private let maxSessions: Int
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return encoder
  }()

  init(baseDirectory: URL? = nil,
       maxMessagesPerSession: Int? = nil,
       maxSessions: Int? = nil,
       defaults: UserDefaults = .standard) {
    let directory = baseDirectory ?? Self.defaultBaseDirectory()
    self.directory = directory
    self.fileURL = directory.appendingPathComponent("sessions.json")
    self.legacyMessagesURL = directory.appendingPathComponent("messages.json")

    let persistedMessageMax = defaults.object(forKey: Self.defaultsMaxMessagesKey) as? Int
    self.maxMessagesPerSession = max(
      1,
      maxMessagesPerSession ?? persistedMessageMax ?? Self.defaultMaxMessagesPerSession
    )

    let persistedSessionMax = defaults.object(forKey: Self.defaultsMaxSessionsKey) as? Int
    self.maxSessions = max(1, maxSessions ?? persistedSessionMax ?? Self.defaultMaxSessions)

    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  func loadSessions() -> [HermesChatSession] {
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let data = try? Data(contentsOf: fileURL) else {
      return migrateLegacyMessagesIfNeeded()
    }

    do {
      return trim(try decoder.decode([HermesChatSession].self, from: data))
    } catch {
      AppLog.dictation.error("Failed to decode Hermes sessions: \(error.localizedDescription)")
      return migrateLegacyMessagesIfNeeded()
    }
  }

  @discardableResult
  func save(_ sessions: [HermesChatSession]) -> [HermesChatSession] {
    let trimmed = trim(sessions)
    do {
      let data = try encoder.encode(trimmed)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      AppLog.dictation.error("Failed to save Hermes sessions: \(error.localizedDescription)")
    }
    return trimmed
  }

  func clear() {
    try? FileManager.default.removeItem(at: fileURL)
    try? FileManager.default.removeItem(at: legacyMessagesURL)
  }

  private func migrateLegacyMessagesIfNeeded() -> [HermesChatSession] {
    guard FileManager.default.fileExists(atPath: legacyMessagesURL.path),
          let data = try? Data(contentsOf: legacyMessagesURL),
          let messages = try? decoder.decode([HermesChatMessage].self, from: data),
          !messages.isEmpty else {
      return []
    }

    let lastDate = messages.last?.createdAt ?? Date()
    let status: HermesChatSession.Status
    switch messages.last?.role {
    case .error:
      status = .error
    case .assistant:
      status = .responded
    case .user, nil:
      status = .open
    }

    let session = HermesChatSession(
      title: "Previous Hermes Chat",
      conversationName: AppConfig.defaultHermesConversationName,
      createdAt: messages.first?.createdAt ?? lastDate,
      updatedAt: lastDate,
      status: status,
      messages: messages
    )
    return save([session])
  }

  private func trim(_ sessions: [HermesChatSession]) -> [HermesChatSession] {
    let sorted = sessions.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.updatedAt > rhs.updatedAt
    }
    return Array(sorted.prefix(maxSessions)).map { session in
      var trimmed = session
      trimmed.messages = Array(session.messages.suffix(maxMessagesPerSession))
      return trimmed
    }
  }

  private static func defaultBaseDirectory() -> URL {
    let appSupport: URL
    do {
      appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    } catch {
      AppLog.dictation.error(
        "Failed to access Application Support directory for Hermes sessions: \(error.localizedDescription)"
      )
      return URL(fileURLWithPath: "/tmp/WonderWhisper/HermesChat", isDirectory: true)
    }

    return appSupport
      .appendingPathComponent("WonderWhisper", isDirectory: true)
      .appendingPathComponent("HermesChat", isDirectory: true)
  }
}
