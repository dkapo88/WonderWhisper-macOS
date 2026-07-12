import Foundation
import Testing
@testable import WonderWhisper

@MainActor
struct HermesChatHistoryStoreTests {
  @Test func persistsMessagesAcrossStoreInstances() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let user = HermesChatMessage(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      role: .user,
      text: "Plan the launch",
      createdAt: Date(timeIntervalSince1970: 1_800),
      contextLabels: ["Screen text", "Screenshot", "Clipboard"],
      clipboardText: "https://example.com/launch-plan"
    )
    let assistant = HermesChatMessage(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      role: .assistant,
      text: "Here is the plan.",
      createdAt: Date(timeIntervalSince1970: 1_860)
    )

    let firstStore = HermesChatHistoryStore(baseDirectory: directory, maxMessages: 50)
    #expect(firstStore.save([user, assistant]) == [user, assistant])

    let secondStore = HermesChatHistoryStore(baseDirectory: directory, maxMessages: 50)
    #expect(secondStore.loadMessages() == [user, assistant])
  }

  @Test func decodesLegacyMessagesWithoutClipboardPreviewText() throws {
    let payload = """
    {
      "id": "00000000-0000-0000-0000-000000000003",
      "role": "user",
      "text": "Legacy message",
      "createdAt": 1800,
      "contextLabels": ["Clipboard"]
    }
    """.data(using: .utf8)!

    let message = try JSONDecoder().decode(HermesChatMessage.self, from: payload)

    #expect(message.contextLabels == ["Clipboard"])
    #expect(message.clipboardText == nil)
  }

  @Test func keepsNewestMessagesWithinConfiguredLimit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let messages = (0..<5).map { index in
      HermesChatMessage(
        role: .user,
        text: "Message \(index)",
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let store = HermesChatHistoryStore(baseDirectory: directory, maxMessages: 3)

    let saved = store.save(messages)

    #expect(saved.map(\.text) == ["Message 2", "Message 3", "Message 4"])
    #expect(store.loadMessages().map(\.text) == ["Message 2", "Message 3", "Message 4"])
  }

  @Test func clearRemovesPersistedMessages() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HermesChatHistoryStore(baseDirectory: directory, maxMessages: 50)
    _ = store.save([
      HermesChatMessage(role: .assistant, text: "Saved response")
    ])

    store.clear()

    #expect(store.loadMessages().isEmpty)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HermesChatHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
