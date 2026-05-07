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

struct HermesSessionRecoveryTests {
  @Test func waitingSessionsRecoveredAfterLaunchBecomeInterruptedAndReplyable() {
    let waiting = HermesChatSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
      title: "Lost request",
      conversationName: "wonderwhisper-mac-lost",
      createdAt: Date(timeIntervalSince1970: 2_400),
      updatedAt: Date(timeIntervalSince1970: 2_460),
      status: .waiting,
      messages: [
        HermesChatMessage(
          role: .user,
          text: "Run the long task",
          createdAt: Date(timeIntervalSince1970: 2_460)
        )
      ]
    )
    let responded = HermesChatSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
      title: "Finished request",
      conversationName: "wonderwhisper-mac-finished",
      status: .responded
    )

    let recovered = HermesSessionRecovery.recoverAfterAppLaunch([waiting, responded])

    #expect(recovered[0].status == .interrupted)
    #expect(recovered[0].canReply)
    #expect(recovered[0].updatedAt == waiting.updatedAt)
    #expect(recovered[1] == responded)
  }

  @Test func interruptedSessionCanReplyButWaitingSessionCannot() {
    let waiting = HermesChatSession(
      title: "Active request",
      conversationName: "wonderwhisper-mac-active",
      status: .waiting
    )

    let interrupted = HermesSessionRecovery.interrupt(waiting)

    #expect(!waiting.canReply)
    #expect(interrupted.status == .interrupted)
    #expect(interrupted.canReply)
  }
}

struct HermesSessionLifecycleTests {
  @Test func archiveMovesSessionOutOfActiveListButKeepsItInArchive() {
    let session = HermesChatSession(
      title: "Finished task",
      conversationName: "wonderwhisper-mac-finished",
      status: .responded
    )

    let archived = HermesSessionLifecycle.archive(session)

    #expect(archived.status == .archived)
    #expect(archived.isArchived)
    #expect(!archived.canReply)
    #expect(HermesSessionLifecycle.activeSessions([archived]).isEmpty)
    #expect(HermesSessionLifecycle.archivedSessions([archived]) == [archived])
  }

  @Test func restoreArchivedSessionReturnsItToReplyableState() {
    let session = HermesChatSession(
      title: "Finished task",
      conversationName: "wonderwhisper-mac-finished",
      status: .responded,
      messages: [
        HermesChatMessage(role: .user, text: "Do the thing"),
        HermesChatMessage(role: .assistant, text: "Done.")
      ]
    )
    let archived = HermesSessionLifecycle.archive(session)

    let restored = HermesSessionLifecycle.restore(archived)

    #expect(restored.status == .responded)
    #expect(!restored.isArchived)
    #expect(restored.canReply)
  }

  @Test func legacyClosedSessionsAreTreatedAsArchived() {
    let closed = HermesChatSession(
      title: "Old closed task",
      conversationName: "wonderwhisper-mac-closed",
      status: .closed,
      messages: [
        HermesChatMessage(role: .assistant, text: "Old result")
      ]
    )

    let restored = HermesSessionLifecycle.restore(closed)

    #expect(closed.isArchived)
    #expect(HermesSessionLifecycle.activeSessions([closed]).isEmpty)
    #expect(HermesSessionLifecycle.archivedSessions([closed]) == [closed])
    #expect(restored.status == .responded)
    #expect(restored.canReply)
  }
}
