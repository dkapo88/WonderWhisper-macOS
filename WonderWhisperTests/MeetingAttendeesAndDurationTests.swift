import Foundation
import Testing
@testable import WonderWhisper

/// Meeting attendees, and the recorded versus elapsed duration a webhook reports.
struct MeetingAttendeesAndDurationTests {
  private static let start = Date(timeIntervalSince1970: 1_760_000_000)
  private static let appInfo = MeetingWebhookAppInfo(
    name: "WonderWhisper",
    version: "2026-10-15",
    build: "2026101500"
  )

  private static func session(attendees: [String] = []) -> MeetingSession {
    MeetingSession(
      title: "Planning",
      startedAt: start,
      endedAt: start.addingTimeInterval(6_720),
      recordedDuration: 2_001,
      detectedApp: "Google Meet",
      status: .completed,
      notesMarkdown: "## Summary\n\n- Planned.",
      attendees: attendees
    )
  }

  private static func json(_ session: MeetingSession) throws -> [String: Any] {
    let payload = MeetingWebhookPayloadBuilder(appInfo: appInfo).payload(
      for: session,
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: start
    )
    let object = try JSONSerialization.jsonObject(with: payload.body) as? [String: Any]
    return try #require(object?["note"] as? [String: Any])
  }

  // MARK: - Attendees

  @Test func attendeesAreTrimmedAndDeduplicatedCaseInsensitively() {
    #expect(MeetingAttendees.parse(" Ash ,dane, ASH,, Priya \n Dane;Lee ")
      == ["Ash", "dane", "Priya", "Lee"])
    #expect(MeetingAttendees.parse("  , ,").isEmpty)
    #expect(MeetingAttendees.text(["Ash", "Dane"]) == "Ash, Dane")
  }

  @Test func payloadCarriesAttendeesOnlyWhenThereAreSome() throws {
    let without = try Self.json(Self.session())
    #expect(without["attendees"] == nil)
    let with = try Self.json(Self.session(attendees: ["Ash", "Dane \"D\" K"]))
    #expect(with["attendees"] as? [String] == ["Ash", "Dane \"D\" K"])
    let payload = MeetingWebhookPayloadBuilder(appInfo: Self.appInfo).payload(
      for: Self.session(attendees: ["Ash"]),
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.start
    )
    let body = String(decoding: payload.body, as: UTF8.self)
    #expect(body.contains(#""detectedApp":"Google Meet","attendees":["Ash"],"markdown":"#))
  }

  @Test func frontMatterListsAttendeesOnlyWhenThereAreSome() {
    let plain = MeetingObsidianExporter.document(for: Self.session())
    #expect(!plain.contains("attendees:"))
    #expect(plain.contains("duration_minutes: 33\ntags:\n  - meeting\n---"))
    let listed = MeetingObsidianExporter.document(
      for: Self.session(attendees: ["Ash", "Dane \"D\""])
    )
    let block = "attendees:\n  - \"Ash\"\n  - \"Dane \\\"D\\\"\"\n"
    #expect(listed.contains("duration_minutes: 33\n" + block + "tags:\n  - meeting\n---"))
    #expect(listed.replacingOccurrences(of: block, with: "") == plain)
  }

  @Test func sessionsSavedBeforeAttendeesDecodeWithNone() throws {
    let json = #"{"id":"\#(UUID().uuidString)","title":"Old","#
      + #""startedAt":"2025-10-09T08:53:20Z","automaticallyStarted":false,"#
      + #""status":"completed","transcriptTokens":[],"audioFiles":[]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(MeetingSession.self, from: Data(json.utf8))
    #expect(session.attendees.isEmpty)
    #expect(session.title == "Old")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let original = Self.session(attendees: ["Ash"])
    let roundTripped = try decoder.decode(MeetingSession.self, from: encoder.encode(original))
    #expect(roundTripped == original)
  }

  // MARK: - Duration

  @Test func resumedMeetingReportsRecordedAndElapsedSeconds() throws {
    // Recorded 2001s across two runs, ended 112 minutes after it started.
    let note = try Self.json(Self.session())
    #expect(note["durationSeconds"] as? Int == 2_001)
    #expect(note["recordedSeconds"] as? Int == 2_001)
    #expect(note["elapsedSeconds"] as? Int == 6_720)

    var open = Self.session()
    open.endedAt = nil
    let unended = try Self.json(open)
    #expect(unended["elapsedSeconds"] is NSNull)
    #expect(unended["recordedSeconds"] as? Int == 2_001)
  }

  @Test func interruptedRecordingIsCountedUpToTheLastAudioWrite() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ww-duration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingSessionStore(rootDirectory: root)
    // A resumed meeting: 600s recorded before, then a run that started at +3000s and whose
    // audio was last written 900s later when the app quit.
    let resumedAt = Self.start.addingTimeInterval(3_000)
    let session = MeetingSession(
      title: "Interrupted",
      startedAt: Self.start,
      recordedDuration: 600,
      recordingStartedAt: resumedAt,
      status: .recording,
      audioFiles: ["microphone-0002.caf"]
    )
    try await store.save(session)
    let directory = try await store.directory(for: session.id)
    let audio = directory.appendingPathComponent("microphone-0002.caf")
    try Data("audio".utf8).write(to: audio)
    let lastWrite = resumedAt.addingTimeInterval(900)
    try FileManager.default.setAttributes(
      [.modificationDate: lastWrite],
      ofItemAtPath: audio.path
    )

    let loaded = try #require(await store.loadAll().first)
    #expect(loaded.status == .interrupted)
    #expect(loaded.recordingStartedAt == nil)
    #expect(abs((loaded.recordedDuration ?? 0) - 1_500) < 1)
    #expect(abs(loaded.duration - 1_500) < 1)
    #expect(loaded.endedAt.map { abs($0.timeIntervalSince(lastWrite)) < 1 } == true)
    #expect(abs((loaded.elapsed ?? 0) - 3_900) < 1)
  }

  @Test func resumingCarriesTheRecordedTimeForward() {
    // What `MeetingCoordinator` does on Resume and on Stop, applied to the model.
    var session = Self.session()
    session.endedAt = Self.start.addingTimeInterval(2_001)
    let resumedAt = Self.start.addingTimeInterval(5_000)
    session.recordedDuration = session.duration
    session.recordingStartedAt = resumedAt
    session.endedAt = nil
    let stoppedAt = resumedAt.addingTimeInterval(1_720)
    if let started = session.recordingStartedAt {
      session.recordedDuration = (session.recordedDuration ?? 0)
        + max(0, stoppedAt.timeIntervalSince(started))
    }
    session.recordingStartedAt = nil
    session.endedAt = stoppedAt
    #expect(session.duration == 3_721)
    #expect(session.elapsed == 6_720)
  }
}
