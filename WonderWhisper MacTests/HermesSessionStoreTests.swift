import Foundation
import Testing
@testable import WonderWhisper_Mac

@MainActor
struct HermesSessionStoreTests {
  @Test func persistsSessionsAcrossStoreInstances() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let createdAt = Date(timeIntervalSince1970: 2_000)
    let message = HermesChatMessage(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
      role: .assistant,
      text: "I can run that task.",
      createdAt: createdAt
    )
    let session = HermesChatSession(
      id: sessionID,
      title: "Launch task",
      conversationName: "wonderwhisper-mac-000000000101",
      serverSessionID: "srv_123",
      createdAt: createdAt,
      updatedAt: createdAt,
      status: .responded,
      messages: [message]
    )

    let firstStore = HermesSessionStore(
      baseDirectory: directory,
      maxMessagesPerSession: 50,
      maxSessions: 10
    )
    #expect(firstStore.save([session]) == [session])

    let secondStore = HermesSessionStore(
      baseDirectory: directory,
      maxMessagesPerSession: 50,
      maxSessions: 10
    )
    #expect(secondStore.loadSessions() == [session])
  }

  @Test func keepsNewestMessagesWithinEachSessionLimit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let messages = (0..<5).map { index in
      HermesChatMessage(
        role: .user,
        text: "Message \(index)",
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let session = HermesChatSession(
      title: "Trimmed task",
      conversationName: "wonderwhisper-mac-trimmed",
      messages: messages
    )
    let store = HermesSessionStore(
      baseDirectory: directory,
      maxMessagesPerSession: 3,
      maxSessions: 10
    )

    let saved = store.save([session])

    #expect(saved.first?.messages.map(\.text) == ["Message 2", "Message 3", "Message 4"])
    #expect(store.loadSessions().first?.messages.map(\.text) == [
      "Message 2",
      "Message 3",
      "Message 4"
    ])
  }

  @Test func migratesLegacyFlatHermesMessagesIntoASession() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacyMessages = [
      HermesChatMessage(
        role: .user,
        text: "Legacy request",
        createdAt: Date(timeIntervalSince1970: 2_100)
      ),
      HermesChatMessage(
        role: .assistant,
        text: "Legacy response",
        createdAt: Date(timeIntervalSince1970: 2_160)
      )
    ]
    _ = HermesChatHistoryStore(baseDirectory: directory, maxMessages: 50).save(legacyMessages)

    let store = HermesSessionStore(
      baseDirectory: directory,
      maxMessagesPerSession: 50,
      maxSessions: 10
    )
    let sessions = store.loadSessions()

    #expect(sessions.count == 1)
    #expect(sessions.first?.title == "Previous Hermes Chat")
    #expect(sessions.first?.conversationName == AppConfig.defaultHermesConversationName)
    #expect(sessions.first?.messages == legacyMessages)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HermesSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

struct HermesSessionNamingTests {
  @Test func conversationNameUsesSanitizedPrefixAndSessionID() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!

    #expect(
      HermesSessionNaming.conversationName(base: " Wonder Whisper Mac! ", id: id)
      == "wonder-whisper-mac-000000000321"
    )
  }

  @Test func titleUsesReadableLeadingWords() {
    let title = HermesSessionNaming.title(
      for: "Please summarise the attached planning notes and turn them into a task list."
    )

    #expect(title == "Please summarise the attached planning notes")
  }
}

struct HermesSessionRoutingTests {
  @Test func hotkeyRepliesToFocusedVisibleResponseWindow() {
    let focused = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!

    #expect(
      HermesSessionRouting.hotkeyTarget(
        focusedSessionID: focused,
        visibleResponseSessionIDs: [other, focused]
      ) == .reply(focused)
    )
  }

  @Test func hotkeyStartsNewSessionWhenNoResponseWindowIsVisible() {
    #expect(
      HermesSessionRouting.hotkeyTarget(
        focusedSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
        visibleResponseSessionIDs: []
      ) == .newSession
    )
  }

  @Test func hotkeyFallsBackToMostRecentVisibleResponseWindow() {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!

    #expect(
      HermesSessionRouting.hotkeyTarget(
        focusedSessionID: nil,
        visibleResponseSessionIDs: [first, second]
      ) == .reply(second)
    )
  }
}
