import Foundation
import Testing
@testable import WonderWhisper

/// Webhook body key order, summary-only content, split delivery and endpoint defaults.
struct MeetingWebhookSplitTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
  private static let noteID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
  private static let appInfo = MeetingWebhookAppInfo(
    name: "WonderWhisper",
    version: "2026-10-14",
    build: "2026101401"
  )
  private static let builder = MeetingWebhookPayloadBuilder(appInfo: appInfo)

  /// A finished meeting whose exported note is about 25k characters, with generated notes
  /// that contain their own `## Transcript highlights` heading.
  private static func longSession() -> MeetingSession {
    var tokens: [MeetingTranscriptToken] = []
    var time: TimeInterval = 0
    while tokens.count < 300 {
      let source: MeetingAudioSource = tokens.count.isMultiple(of: 2) ? .microphone : .systemAudio
      let text = source == .microphone
        ? "Okay, so the \"rollout\" plan is next. Can we agree on owners today?"
        : "Sure. 好的，我们继续。 Ship it 👍🏽 after QA signs off."
      tokens.append(
        MeetingTranscriptToken(source: source, startTime: time, endTime: time + 4, text: text)
      )
      time += 5
    }
    var notes = "## TL;DR\n\n- Agreed the rollout.\n\n## Transcript highlights\n\n"
    for index in 0..<10 {
      notes += "### Topic \(index)\n\n"
      notes += String(repeating: "We discussed feature \(index) and its risks. ", count: 5)
      notes += "\n\n"
    }
    return MeetingSession(
      id: noteID,
      title: "Glofox planning",
      startedAt: fixedDate,
      endedAt: fixedDate.addingTimeInterval(2_712),
      recordedDuration: 2_712,
      detectedApp: "Google Meet",
      status: .completed,
      transcriptTokens: tokens,
      manualNotesMarkdown: "Remember the pricing page.",
      notesMarkdown: notes
    )
  }

  private static func endpoint(
    split: Bool = false,
    max: Int = MeetingWebhookEndpoint.defaultMaxBodyCharacters,
    content: MeetingWebhookContent = .full
  ) -> MeetingWebhookEndpoint {
    MeetingWebhookEndpoint(
      name: "Grok Bot",
      url: "https://example.com/hook",
      splitIntoParts: split,
      maxBodyCharacters: max,
      content: content
    )
  }

  private static func base(_ markdown: String, title: String = "Glofox planning")
    -> MeetingWebhookPayload {
    MeetingWebhookPayload(
      event: .noteCompleted,
      schemaVersion: MeetingWebhookPayload.currentSchemaVersion,
      deliveryId: UUID(),
      sendId: nil,
      sentAt: fixedDate,
      app: appInfo,
      part: nil,
      note: MeetingWebhookPayload.Note(
        id: noteID,
        title: title,
        startedAt: fixedDate,
        endedAt: nil,
        durationSeconds: 60,
        detectedApp: nil,
        content: .full,
        markdown: markdown
      )
    )
  }

  private static func text(_ payload: MeetingWebhookPayload) -> String {
    String(decoding: payload.body, as: UTF8.self)
  }

  /// Splits and checks the invariants every split must hold; returns the parts.
  private static func checkedSplit(
    _ markdown: String,
    max: Int
  ) throws -> [MeetingWebhookPayload] {
    let sendID = UUID()
    let parts = try MeetingWebhookPayloadSplitter.parts(
      of: base(markdown),
      sendID: sendID,
      maxBytes: max
    )
    #expect(!parts.isEmpty)
    for (offset, part) in parts.enumerated() {
      #expect(part.body.count <= max, "part \(offset + 1) is \(part.body.count) bytes")
      #expect(part.part == MeetingWebhookPayload.Part(index: offset + 1, total: parts.count))
      #expect(part.sendId == sendID)
      #expect(part.note.id == noteID)
      let json = try #require(
        JSONSerialization.jsonObject(with: part.body) as? [String: Any]
      )
      let note = try #require(json["note"] as? [String: Any])
      #expect(note["markdown"] as? String == part.note.markdown)
    }
    #expect(Set(parts.map(\.deliveryId)).count == parts.count)
    let joined = parts.map(\.note.markdown).joined()
    #expect(joined.unicodeScalars.elementsEqual(markdown.unicodeScalars))
    return parts
  }

  // MARK: - Key order

  @Test func unsplitBodyKeepsSchemaV1WithMarkdownAsTheLastKey() throws {
    let payload = Self.builder.payload(
      for: Self.longSession(),
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.fixedDate
    )
    let body = Self.text(payload)
    #expect(body.hasPrefix(#"{"event":"meeting.note.completed","schemaVersion":1,"deliveryId":"#))
    let keys = [
      "\"event\"", "\"schemaVersion\"", "\"deliveryId\"", "\"sentAt\"", "\"app\"", "\"name\"",
      "\"version\"", "\"build\"", "\"note\"", "\"id\"", "\"title\"", "\"startedAt\"",
      "\"endedAt\"", "\"durationSeconds\"", "\"detectedApp\"", "\"markdown\""
    ]
    var cursor = body.startIndex
    for key in keys {
      let found = body.range(of: key, range: cursor..<body.endIndex)
      #expect(found != nil, "\(key) out of order")
      if let found { cursor = found.upperBound }
    }
    #expect(!body.contains("\"sendId\"") && !body.contains("\"part\""))
    #expect(!body.contains("\"content\":"))

    let json = try #require(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
    let note = try #require(json["note"] as? [String: Any])
    let markdown = MeetingObsidianExporter.document(for: Self.longSession())
    #expect(note["markdown"] as? String == markdown)
    #expect(json["sentAt"] as? String == "2025-10-09T08:53:20Z")
    // The whole body ends with the markdown value closing `note` and the document.
    let encodedMarkdown = MeetingWebhookJSONValue.string(markdown).serialized
    #expect(body.hasSuffix("\"markdown\":\(encodedMarkdown)}}"))
  }

  @Test func stringEscapingMatchesJSONEncoder() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let samples = [
      "a\"b\\c/d\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}\u{2028}é😀", "好的。", "👨‍👩‍👧‍👦", "", "\r\n\u{00}"
    ]
    for sample in samples {
      let mine = MeetingWebhookJSONValue.string(sample).serialized
      let expected = String(decoding: try encoder.encode(sample), as: UTF8.self)
      #expect(mine == expected)
      let cost = sample.reduce(0) { $0 + MeetingWebhookJSONValue.escapedByteCount(of: $1) }
      #expect(cost + 2 == mine.utf8.count)
    }
  }

  @Test func truncatedLongBodyStillCarriesAllMetadata() {
    let session = Self.longSession()
    let payload = Self.builder.payload(
      for: session,
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.fixedDate
    )
    let body = Self.text(payload)
    #expect(body.count > 20_000)
    let head = String(body.prefix(4_000))
    let needles = [
      "\"event\":\"meeting.note.completed\"", "\"schemaVersion\":1",
      "\"deliveryId\":\"\(payload.deliveryId.uuidString)\"", "\"sentAt\"", "\"app\"",
      "\"id\":\"\(session.id.uuidString)\"", "\"title\":\"Glofox planning\"", "\"startedAt\"",
      "\"endedAt\"", "\"durationSeconds\":2712", "\"detectedApp\":\"Google Meet\"",
      "\"markdown\":\""
    ]
    for needle in needles {
      #expect(head.contains(needle), "\(needle) missing from the first 4000 characters")
    }
  }

  // MARK: - Content

  @Test func summaryOnlyLeavesOutTheTranscriptSectionStructurally() throws {
    let session = Self.longSession()
    let summary = MeetingObsidianExporter.document(for: session, includeTranscript: false)
    let full = MeetingObsidianExporter.document(for: session)
    #expect(full.contains("\n## Transcript\n"))
    #expect(!summary.contains("\n## Transcript\n"))
    #expect(!summary.contains(session.transcriptMarkdown))
    #expect(summary.contains("## Transcript highlights"))
    #expect(summary.contains("### Topic 9"))
    #expect(summary.contains("## Manual notes\n\nRemember the pricing page."))
    #expect(summary.hasPrefix("---\ntitle: \"Glofox planning\""))
    #expect(summary.contains("\n# Glofox planning\n"))
    #expect(full.hasPrefix(summary))

    let payload = Self.builder.payload(
      for: session,
      event: .noteCompleted,
      deliveryID: UUID(),
      sentAt: Self.fixedDate,
      content: .summary
    )
    #expect(payload.note.markdown == summary)
    let expected = #""detectedApp":"Google Meet","content":"summary","markdown":"#
    #expect(Self.text(payload).contains(expected))
  }

  // MARK: - Splitting

  @Test func longNoteSplitsIntoBodiesUnderTheLimitAtNaturalBreaks() throws {
    let session = Self.longSession()
    let sendID = UUID()
    let parts = try Self.builder.payloads(
      for: session,
      event: .noteCompleted,
      endpoint: Self.endpoint(split: true),
      sendID: sendID,
      sentAt: Self.fixedDate
    )
    #expect(parts.count >= 6 && parts.count <= 10)
    let full = MeetingObsidianExporter.document(for: session)
    #expect(parts.map(\.note.markdown).joined() == full)
    for (offset, part) in parts.enumerated() {
      #expect(part.body.count <= 3_800)
      #expect(part.part == MeetingWebhookPayload.Part(index: offset + 1, total: parts.count))
      #expect(part.sendId == sendID)
      #expect(part.note.id == session.id)
      let body = Self.text(part)
      #expect(body.contains(
        "\"deliveryId\":\"\(part.deliveryId.uuidString)\",\"sendId\":\"\(sendID.uuidString)\""
      ))
      #expect(body.contains(
        "\"part\":{\"index\":\(offset + 1),\"total\":\(parts.count)},\"note\":{"
      ))
    }
    #expect(Set(parts.map(\.deliveryId)).count == parts.count)
    // Every cut but the last lands on a line break, and parts are filled well past half.
    for part in parts.dropLast() {
      #expect(part.note.markdown.hasSuffix("\n"))
      #expect(part.note.markdown.utf8.count > 1_900)
    }
    #expect(parts.dropFirst().contains { $0.note.markdown.hasPrefix("#") })
  }

  @Test func splittingOffSendsOneUnchangedBody() throws {
    let parts = try Self.builder.payloads(
      for: Self.longSession(),
      event: .noteCompleted,
      endpoint: Self.endpoint(split: false, max: 1_000),
      sendID: UUID(),
      sentAt: Self.fixedDate
    )
    #expect(parts.count == 1)
    #expect(parts.first?.sendId == nil)
    #expect(parts.first?.part == nil)
  }

  @Test func multiByteAndEscapeHeavyTextStaysUnderTheLimit() throws {
    _ = try Self.checkedSplit(String(repeating: "好的，我们继续。表情👍🏽👨‍👩‍👧‍👦", count: 800), max: 1_500)
    _ = try Self.checkedSplit(String(repeating: "\"q\"\n\\\t", count: 4_000), max: 1_200)
    _ = try Self.checkedSplit(String(repeating: "👨‍👩‍👧‍👦", count: 300), max: 1_000)
  }

  @Test func oneGiantWordIsHardSplit() throws {
    let parts = try Self.checkedSplit(String(repeating: "x", count: 20_000), max: 1_000)
    #expect(parts.count > 20)
  }

  @Test func emptyAndShortNotesAreOnePart() throws {
    #expect(try Self.checkedSplit("", max: 1_000).count == 1)
    #expect(try Self.checkedSplit("short", max: 3_800).count == 1)
  }

  @Test func limitTooSmallForTheMetadataFailsVisibly() {
    let huge = Self.base("body", title: String(repeating: "T", count: 3_000))
    #expect(throws: MeetingWebhookPayloadSplitter.SplitError.self) {
      try MeetingWebhookPayloadSplitter.parts(of: huge, sendID: UUID(), maxBytes: 1_000)
    }
    do {
      _ = try MeetingWebhookPayloadSplitter.parts(of: huge, sendID: UUID(), maxBytes: 1_000)
    } catch let error as MeetingWebhookPayloadSplitter.SplitError {
      #expect(error.message.contains("too small"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  @Test func partCountCrossingNineToTenStaysUnderTheLimit() throws {
    let base = Self.base(String(repeating: "word ", count: 2_000))
    var counts = Set<Int>()
    for max in stride(from: 1_700, through: 1_200, by: -5) {
      let parts = try MeetingWebhookPayloadSplitter.parts(of: base, sendID: UUID(), maxBytes: max)
      counts.insert(parts.count)
      #expect(parts.allSatisfy { $0.body.count <= max })
      #expect(parts.last?.part?.total == parts.count)
    }
    #expect(counts.contains(9) && counts.contains(10))
  }

  // MARK: - Endpoint settings

  @Test func oldEndpointJSONDecodesWithSplitOffAndFullContent() throws {
    let json = #"[{"id":"\#(UUID().uuidString)","name":"Grok Bot","#
      + #""url":"https://example.com/hook","isEnabled":true,"headerNames":[],"hasSecret":false}]"#
    let endpoint = try #require(
      try JSONDecoder().decode([MeetingWebhookEndpoint].self, from: Data(json.utf8)).first
    )
    #expect(endpoint.splitIntoParts == false)
    #expect(endpoint.maxBodyCharacters == 3_800)
    #expect(endpoint.content == .full)

    let fresh = MeetingWebhookEndpoint()
    #expect(!fresh.splitIntoParts && fresh.maxBodyCharacters == 3_800 && fresh.content == .full)
    #expect(MeetingWebhookEndpoint.clampedMaxBody(10) == 1_000)
    #expect(MeetingWebhookEndpoint.clampedMaxBody(5_000_000) == 1_000_000)

    var edited = fresh
    edited.splitIntoParts = true
    edited.maxBodyCharacters = 5_000
    edited.content = .summary
    let decoded = try JSONDecoder().decode(
      MeetingWebhookEndpoint.self,
      from: JSONEncoder().encode(edited)
    )
    #expect(decoded == edited)
  }

  // MARK: - Delivery

  private static func jobs(_ count: Int, sendID: UUID = UUID()) -> [MeetingWebhookDeliveryJob] {
    let endpoint = endpoint(split: true)
    return (1...count).map { index in
      MeetingWebhookDeliveryJob(
        deliveryID: UUID(),
        sendID: sendID,
        partIndex: index,
        partTotal: count,
        endpoint: endpoint,
        url: URL(string: "https://example.com/hook") ?? URL(fileURLWithPath: "/"),
        event: .noteCompleted,
        noteID: noteID,
        noteTitle: "Glofox planning",
        body: Data("{\"part\":\(index)}".utf8),
        signingSecret: "topsecret",
        customHeaders: ["Authorization": "Bearer abc"],
        userAgent: appInfo.userAgent
      )
    }
  }

  private static func service(
    _ transport: FakeMeetingWebhookTransport
  ) -> MeetingWebhookDeliveryService {
    MeetingWebhookDeliveryService(
      transport: transport,
      sleeper: { _ in },
      clock: { fixedDate },
      jitter: { 0 }
    )
  }

  @Test func partsAreSentInOrderEachSignedWithItsOwnDeliveryID() async {
    let transport = FakeMeetingWebhookTransport([])
    let jobs = Self.jobs(3)
    let records = await Self.service(transport).deliverParts(jobs)
    #expect(records.map(\.state) == [.delivered, .delivered, .delivered])
    #expect(transport.requests.map(\.httpBody) == jobs.map(\.body))
    #expect(transport.requests.map { $0.value(forHTTPHeaderField: "X-WonderWhisper-Delivery") }
      == jobs.map { $0.deliveryID.uuidString.lowercased() })
    #expect(transport.requests.allSatisfy {
      $0.value(forHTTPHeaderField: "X-WonderWhisper-Signature") != nil
        && $0.value(forHTTPHeaderField: "Authorization") == "Bearer abc"
    })
    let summary = MeetingWebhookStatusFormatter.representative(of: records)
    #expect(summary.map { MeetingWebhookStatusFormatter.text(for: $0, now: Self.fixedDate) }
      == "Sent to Grok Bot (3 parts) just now")
  }

  @Test func aPermanentlyFailedPartSkipsTheRest() async {
    let transport = FakeMeetingWebhookTransport([.status(200), .status(400)])
    let jobs = Self.jobs(3)
    let records = await Self.service(transport).deliverParts(jobs)
    #expect(records.map(\.state) == [.delivered, .failed, .failed])
    #expect(records.map(\.id) == jobs.map(\.deliveryID))
    #expect(transport.requests.count == 2)
    #expect(records[2].lastError == "Skipped: part 2 failed")
    #expect(records[2].attempts == 0)
    #expect(records[2].isSkipped)
    let summary = MeetingWebhookStatusFormatter.representative(of: records)
    #expect(summary.map { MeetingWebhookStatusFormatter.text(for: $0) }
      == "Grok Bot failed at part 2 of 3: HTTP 400")
  }

  @Test func retryingAPartDoesNotResendEarlierParts() async {
    let transport = FakeMeetingWebhookTransport([.status(200), .status(503), .status(200)])
    let jobs = Self.jobs(3)
    let states = StateRecorder()
    let records = await Self.service(transport).deliverParts(jobs) { states.append($0.state) }
    #expect(records.map(\.state) == [.delivered, .delivered, .delivered])
    #expect(transport.requests.map(\.httpBody)
      == [jobs[0].body, jobs[1].body, jobs[1].body, jobs[2].body])
    #expect(records[1].attempts == 2)
    #expect(states.values.contains(.retrying))
  }

  @Test func statusTextDescribesPartsInFlight() {
    var record = MeetingWebhookDeliveryRecord(
      id: UUID(), endpointID: UUID(), endpointName: "Grok Bot", noteID: Self.noteID,
      noteTitle: "Planning", event: .noteCompleted, state: .sending, attempts: 0,
      maximumAttempts: 5, lastStatusCode: nil, lastError: nil,
      createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
      sendID: UUID(), partIndex: 2, partTotal: 3
    )
    #expect(MeetingWebhookStatusFormatter.text(for: record) == "Sending Grok Bot part 2 of 3")
    record.state = .retrying
    record.attempts = 1
    #expect(MeetingWebhookStatusFormatter.text(for: record)
      == "Retrying Grok Bot part 2 of 3 (attempt 2 of 5)")
  }

  @Test func oldDeliveryRecordsDecodeAsUnsplit() throws {
    let json = #"{"id":"\#(UUID().uuidString)","endpointID":"\#(UUID().uuidString)","#
      + #""endpointName":"Grok Bot","noteID":"\#(UUID().uuidString)","noteTitle":"Planning","#
      + #""event":"meeting.note.completed","state":"delivered","attempts":1,"#
      + #""maximumAttempts":5,"createdAt":"2025-10-09T08:53:20Z","#
      + #""updatedAt":"2025-10-09T08:53:20Z"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(MeetingWebhookDeliveryRecord.self, from: Data(json.utf8))
    #expect(record.sendID == nil && record.partIndex == nil && record.partTotal == nil)
    #expect(record.sendKey == record.id)
    #expect(!record.isPartOfSplit)
  }
}
