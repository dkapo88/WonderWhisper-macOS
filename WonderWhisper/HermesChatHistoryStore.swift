import Foundation
import OSLog

@MainActor
final class HermesChatHistoryStore {
  static let defaultMaxMessages = 50
  static let defaultsMaxKey = "hermes.chat.maxMessages"

  private let fileURL: URL
  private let maxMessages: Int
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
       maxMessages: Int? = nil,
       defaults: UserDefaults = .standard) {
    let directory = baseDirectory ?? Self.defaultBaseDirectory()
    self.fileURL = directory.appendingPathComponent("messages.json")

    let persistedMax = defaults.object(forKey: Self.defaultsMaxKey) as? Int
    self.maxMessages = max(1, maxMessages ?? persistedMax ?? Self.defaultMaxMessages)

    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  func loadMessages() -> [HermesChatMessage] {
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let data = try? Data(contentsOf: fileURL) else {
      return []
    }

    do {
      return trim(try decoder.decode([HermesChatMessage].self, from: data))
    } catch {
      AppLog.dictation.error("Failed to decode Hermes chat history: \(error.localizedDescription)")
      return []
    }
  }

  @discardableResult
  func save(_ messages: [HermesChatMessage]) -> [HermesChatMessage] {
    let trimmed = trim(messages)
    do {
      let data = try encoder.encode(trimmed)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      AppLog.dictation.error("Failed to save Hermes chat history: \(error.localizedDescription)")
    }
    return trimmed
  }

  func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }

  private func trim(_ messages: [HermesChatMessage]) -> [HermesChatMessage] {
    Array(messages.suffix(maxMessages))
  }

  private static func defaultBaseDirectory() -> URL {
    AppStoragePaths.appSupportRoot()
      .appendingPathComponent("HermesChat", isDirectory: true)
  }
}
