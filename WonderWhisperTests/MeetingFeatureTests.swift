import Foundation
import AVFoundation
import SwiftUI
import Testing
@testable import WonderWhisper

struct MeetingFeatureTests {
  @Test func meetingOverlayTabPickerIsInsulatedFromCoordinatorChurn() {
    var picked: MeetingOverlayTab?
    let transcript = MeetingOverlayTabPicker(selection: .transcript) { picked = $0 }
    // Two pickers on the same tab with different callbacks must compare equal: a live transcript,
    // audio, or session publish rebuilds the closure but cannot invalidate the segmented control.
    #expect(transcript == MeetingOverlayTabPicker(selection: .transcript) { _ in })
    // A real tab change still must.
    #expect(transcript != MeetingOverlayTabPicker(selection: .notes) { _ in })
    transcript.onSelect(.context)
    #expect(picked == .context)
    // Nothing meeting-scoped is stored, so nothing meeting-scoped can drive its identity. The
    // namespace is view-local animation identity and plays no part in equality.
    #expect(
      Mirror(reflecting: transcript).children.compactMap(\.label)
        == ["selection", "onSelect", "_selectionNamespace"]
    )
    #expect(MeetingOverlayTabPicker.maxWidth == 320)
  }

  @Test func meetingBubbleDistinguishesClicksFromDrags() {
    #expect(!MeetingBubbleInteractionPolicy.isDrag(deltaX: 2, deltaY: 2))
    #expect(MeetingBubbleInteractionPolicy.isDrag(deltaX: 5, deltaY: 0))
  }

  @Test func meetingAudioMeterTracksSilenceAndSignalStrength() {
    let silence = MeetingAudioMeter.level(from: Array(repeating: 0, count: 1_024))
    let quiet = MeetingAudioMeter.level(from: Array(repeating: 0.02, count: 1_024))
    let loud = MeetingAudioMeter.level(from: Array(repeating: 0.4, count: 1_024))

    #expect(silence == 0)
    #expect(quiet > silence)
    #expect(loud > quiet)
    #expect(loud <= 1)
  }

  @Test func meetingAudioFramerNormalizesTinyCaptureCallbacksIntoStableFrames() {
    let framer = MeetingAudioChunkFramer(source: .microphone)
    var chunks: [MeetingAudioChunk] = []

    for index in 0..<50 {
      chunks.append(contentsOf: framer.append(
        samples: Array(repeating: Float(index), count: 64),
        startTime: Double(index) * 0.004
      ))
    }

    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.samples.count == 1_600 })
    #expect(chunks[0].startTime == 0)
    #expect(abs(chunks[1].startTime - 0.1) < 0.000_001)
    #expect(chunks.allSatisfy { abs($0.duration - 0.1) < 0.000_001 })
  }

  @Test func meetingAudioFramerBatchesNativeMicrophoneCallbacksBeforeResampling() {
    let framer = MeetingAudioChunkFramer(source: .microphone, sampleRate: 48_000)
    var chunks: [MeetingAudioChunk] = []

    for index in 0..<75 {
      chunks.append(contentsOf: framer.append(
        samples: Array(repeating: 0.1, count: 512),
        startTime: Double(index * 512) / 48_000
      ))
    }

    #expect(chunks.count == 8)
    #expect(chunks.allSatisfy { $0.samples.count == 4_800 })
    #expect(chunks.allSatisfy { abs($0.duration - 0.1) < 0.000_001 })
  }

  @Test func meetingAudioFramerFlushesTheFinalPartialFrame() {
    let framer = MeetingAudioChunkFramer(source: .systemAudio)
    #expect(framer.append(
      samples: Array(repeating: 0.2, count: 800),
      startTime: 1.25
    ).isEmpty)

    let final = framer.finish()

    #expect(final.count == 1)
    #expect(final[0].source == .systemAudio)
    #expect(final[0].samples.count == 800)
    #expect(final[0].startTime == 1.25)
    #expect(abs(final[0].duration - 0.05) < 0.000_001)
  }

  @Test func meetingAudioFramerPreservesAForwardRouteChangeGap() {
    let framer = MeetingAudioChunkFramer(source: .microphone)
    let initial = framer.append(
      samples: Array(repeating: 0.2, count: 1_600),
      startTime: 0
    )
    let resumed = framer.append(
      samples: Array(repeating: 0.2, count: 1_600),
      startTime: 0.35
    )

    #expect(initial.count == 1)
    #expect(resumed.count == 1)
    #expect(abs(resumed[0].startTime - 0.35) < 0.000_001)
  }

  @Test func stereoAlignerKeepsEachSourceOnItsOwnChannel() {
    let aligner = MeetingStereoAligner()
    let system = MeetingAudioChunk(
      source: .systemAudio,
      samples: Array(repeating: 0.1, count: 3_200),
      startTime: 0,
      duration: 0.2
    )
    let microphone = MeetingAudioChunk(
      source: .microphone,
      samples: Array(repeating: 0.05, count: 3_200),
      startTime: 0,
      duration: 0.2
    )

    #expect(aligner.ingest(system).isEmpty)
    let frames = aligner.ingest(microphone)

    #expect(frames.count == 2)
    #expect(frames[0].startTime == 0)
    #expect(frames[1].startTime == 0.1)
    #expect(frames.allSatisfy { $0.microphone.count == 1_600 && $0.system.count == 1_600 })
    #expect(frames.allSatisfy { $0.microphone.allSatisfy { $0 == 0.05 } })
    #expect(frames.allSatisfy { $0.system.allSatisfy { $0 == 0.1 } })
  }

  @Test func stereoFrameInterleavesMicrophoneFirst() {
    let frame = MeetingStereoFrame(startTime: 0, microphone: [0.5, -1], system: [-0.5, 1])
    let data = frame.interleavedPCM16

    func value(at index: Int) -> Int16 {
      Int16(bitPattern: UInt16(data[index * 2]) | UInt16(data[index * 2 + 1]) << 8)
    }

    #expect(data.count == 8)
    #expect(value(at: 0) == 16_384)
    #expect(value(at: 1) == -16_384)
    #expect(value(at: 2) == Int16.min)
    #expect(value(at: 3) == Int16.max)
  }

  @Test func stereoAlignerWaitsForBothSourcesInsteadOfDiscardingOne() {
    let aligner = MeetingStereoAligner()
    let microphoneStart = MeetingAudioChunk(
      source: .microphone,
      samples: Array(repeating: 0.05, count: 1_600),
      startTime: 0,
      duration: 0.1
    )
    let systemAhead = MeetingAudioChunk(
      source: .systemAudio,
      samples: Array(repeating: 0.1, count: 8_000),
      startTime: 0,
      duration: 0.5
    )
    let delayedMicrophone = MeetingAudioChunk(
      source: .microphone,
      samples: Array(repeating: 0.05, count: 4_800),
      startTime: 0.1,
      duration: 0.3
    )

    #expect(aligner.ingest(microphoneStart).isEmpty)
    #expect(aligner.ingest(systemAhead).count == 1)
    #expect(!aligner.hasDiscardedLateAudio)
    let frames = aligner.ingest(delayedMicrophone)
    #expect(frames.count == 3)
    #expect(frames.allSatisfy { $0.microphone.allSatisfy { $0 == 0.05 } })
    #expect(!aligner.hasDiscardedLateAudio)
  }

  @Test func stereoAlignerBoundsAStalledSourceAndRequiresRecovery() {
    let aligner = MeetingStereoAligner()
    let microphone = MeetingAudioChunk(
      source: .microphone,
      samples: Array(repeating: 0.05, count: 1_600),
      startTime: 0,
      duration: 0.1
    )
    let system = MeetingAudioChunk(
      source: .systemAudio,
      samples: Array(repeating: 0.1, count: 496_000),
      startTime: 0,
      duration: 31
    )

    #expect(aligner.ingest(microphone).isEmpty)
    let frames = aligner.ingest(system)
    #expect(frames.count == 10)
    #expect(frames[1].microphone.allSatisfy { $0 == 0 })
    #expect(aligner.hasDiscardedLateAudio)
  }

  @Test func sharedTranscriptionBacklogMarksBothRawSourcesForRecovery() {
    #expect(
      MeetingIngestionBacklogPolicy.recoverySources
        == Set(MeetingAudioSource.captureSources)
    )
    #expect(MeetingIngestionBacklogPolicy.warningMessage.contains("Recording is continuing"))
  }

  @Test func meetingBubbleStaysInsideTheRightScreenEdge() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    let companionFrame = NSRect(x: 620, y: 300, width: 360, height: 200)

    let origin = MeetingOverlayLayout.bubbleOrigin(
      in: visibleFrame,
      near: companionFrame
    )

    #expect(origin.x == 860)
    #expect(origin.y == 382)
  }

  @Test func obsidianPreferencesMigrateCombinedFolderIntoVaultAndExportPaths() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = directory.appendingPathComponent("Dane's Vault", isDirectory: true)
    let exportFolder = vault.appendingPathComponent("Meetings/Work", isDirectory: true)
    try FileManager.default.createDirectory(
      at: vault.appendingPathComponent(".obsidian", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: exportFolder,
      withIntermediateDirectories: true
    )
    let suiteName = "MeetingObsidianPreferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(exportFolder.path, forKey: "meeting.obsidian.folder")

    #expect(MeetingObsidianPreferences.vaultRootPath(defaults: defaults) == vault.path)
    #expect(
      MeetingObsidianPreferences.exportFolderPath(defaults: defaults) == exportFolder.path
    )
    #expect(defaults.object(forKey: "meeting.obsidian.folder") == nil)
  }

  @Test func obsidianExportFolderMustBeInsideVaultRoot() {
    let vault = URL(fileURLWithPath: "/tmp/Dane's Vault", isDirectory: true)

    #expect(MeetingObsidianPreferences.contains(vault, in: vault))
    #expect(MeetingObsidianPreferences.contains(
      vault.appendingPathComponent("Meetings/Work", isDirectory: true),
      in: vault
    ))
    #expect(!MeetingObsidianPreferences.contains(
      URL(fileURLWithPath: "/tmp/Dane's Vault Backup/Meetings", isDirectory: true),
      in: vault
    ))
  }

  @Test func transcriptFormatterMergesAdjacentTokensBySource() {
    let tokens = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 0,
        endTime: 0.5,
        text: " Hello"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 0.5,
        endTime: 1,
        text: " world."
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 1.2,
        endTime: 2,
        text: " Hi Dane."
      )
    ]

    let blocks = MeetingTranscriptFormatter.blocks(tokens: tokens)

    #expect(blocks.count == 2)
    #expect(blocks[0].source == .microphone)
    #expect(blocks[0].text == "Hello world.")
    #expect(blocks[1].source == .systemAudio)
    #expect(MeetingTranscriptFormatter.markdown(tokens: tokens, speakers: MeetingSpeakerDirectory(
      tokens: tokens,
      userName: nil
    )).contains("**You [00:00]:**"))
  }

  @Test func transcriptFormatterPreservesSubwordOrderAtEqualTimestamps() {
    let tokens = [" GPT", "-", "5", ".", "6", " works."].map {
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 4,
        endTime: 4.08,
        text: $0
      )
    }

    #expect(MeetingTranscriptFormatter.blocks(tokens: tokens).first?.text == "GPT-5.6 works.")
  }

  @Test func transcriptFormatterOrdersLateTokensAndPreservesTimestampTies() {
    let firstAtTie = MeetingTranscriptToken(
      source: .microphone,
      startTime: 1,
      endTime: 1.1,
      text: " first"
    )
    let later = MeetingTranscriptToken(
      source: .microphone,
      startTime: 2,
      endTime: 2.1,
      text: " later"
    )
    let secondAtTie = MeetingTranscriptToken(
      source: .microphone,
      startTime: 1,
      endTime: 1.1,
      text: " second"
    )

    let sorted = MeetingTranscriptFormatter.chronologicalTokens([
      later,
      firstAtTie,
      secondAtTie
    ])

    #expect(sorted.map(\.id) == [firstAtTie.id, secondAtTie.id, later.id])
  }

  @Test func transcriptFormatterSeparatesMixedStreamSpeakers() {
    let tokens = [
      MeetingTranscriptToken(
        source: .mixed,
        startTime: 0,
        endTime: 0.5,
        text: " Hello.",
        speaker: "1"
      ),
      MeetingTranscriptToken(
        source: .mixed,
        startTime: 0.7,
        endTime: 1.2,
        text: " Hi.",
        speaker: "2"
      )
    ]

    let blocks = MeetingTranscriptFormatter.blocks(tokens: tokens)

    #expect(blocks.map(\.displayName) == ["Speaker 1", "Speaker 2"])
  }

  @Test func transcriptFormatterShowsAsyncSystemAudioSpeakers() {
    let token = MeetingTranscriptToken(
      source: .systemAudio,
      startTime: 0,
      endTime: 0.5,
      text: " Hello.",
      speaker: "2"
    )

    #expect(MeetingTranscriptFormatter.blocks(tokens: [token]).first?.displayName == "Speaker 2")
  }

  @Test func transcriptFormatterKeepsOverlappingSpeakersInReadableBlocks() {
    let tokens = [
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10,
        endTime: 10.4,
        text: " Remote starts",
        speaker: "1"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10.2,
        endTime: 10.5,
        text: " I overlap"
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10.4,
        endTime: 10.9,
        text: " and finishes",
        speaker: "1"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10.6,
        endTime: 11,
        text: " and finish"
      )
    ]

    let blocks = MeetingTranscriptFormatter.blocks(tokens: tokens)

    #expect(blocks.count == 2)
    #expect(blocks[0].text == "Remote starts and finishes")
    #expect(blocks[1].text == "I overlap and finish")
  }

  @Test func transcriptFormatterPreservesSequentialTurnOrder() {
    let tokens = [
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10,
        endTime: 10.4,
        text: " First remote turn",
        speaker: "1"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 11,
        endTime: 11.4,
        text: " My reply"
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 12,
        endTime: 12.4,
        text: " Second remote turn",
        speaker: "1"
      )
    ]

    let blocks = MeetingTranscriptFormatter.blocks(tokens: tokens)

    #expect(blocks.map(\.text) == ["First remote turn", "My reply", "Second remote turn"])
  }

  @Test func transcriptFormatterSuppressesSystemAudioEchoFromMicrophone() {
    let remoteWords = ["The", "quarterly", "token", "price", "is", "sixty", "dollars"]
    var tokens = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 2,
        endTime: 2.4,
        text: " My introduction."
      )
    ]
    tokens += remoteWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10 + Double(index) * 0.3,
        endTime: 10.2 + Double(index) * 0.3,
        text: " \(word)"
      )
    }
    tokens += remoteWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 9.84 + Double(index) * 0.3,
        endTime: 10.04 + Double(index) * 0.3,
        text: " \(word)"
      )
    }
    tokens.append(
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 18,
        endTime: 18.5,
        text: " My response."
      )
    )

    let blocks = MeetingTranscriptFormatter.blocks(tokens: tokens)
    let microphoneText = blocks.filter { $0.source == .microphone }.map(\.text).joined()
    let systemText = blocks.filter { $0.source == .systemAudio }.map(\.text).joined()

    #expect(microphoneText == "My introduction.My response.")
    #expect(systemText == "The quarterly token price is sixty dollars")
  }

  @Test func echoSuppressionToleratesOneWordDisagreementAndRemovesPunctuation() {
    let systemWords = ["This", "meeting", "covers", "the", "release", "plan"]
    let microphoneWords = ["This", "meeting", "cover", "the", "release", "plan"]
    var tokens = systemWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10 + Double(index) * 0.4,
        endTime: 10.3 + Double(index) * 0.4,
        text: " \(word)"
      )
    }
    tokens += microphoneWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10.2 + Double(index) * 0.4,
        endTime: 10.5 + Double(index) * 0.4,
        text: " \(word)"
      )
    }
    tokens.append(
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 12.3,
        endTime: 12.4,
        text: "."
      )
    )

    let microphoneBlocks = MeetingTranscriptFormatter.blocks(tokens: tokens).filter {
      $0.source == .microphone
    }

    #expect(microphoneBlocks.isEmpty)
  }

  @Test func echoSuppressionPreservesMeaningfulCorrection() {
    let systemWords = ["The", "release", "is", "Thursday", "afternoon"]
    let microphoneWords = ["The", "release", "is", "Friday", "afternoon"]
    var tokens = systemWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10 + Double(index) * 0.4,
        endTime: 10.3 + Double(index) * 0.4,
        text: " \(word)"
      )
    }
    tokens += microphoneWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10.2 + Double(index) * 0.4,
        endTime: 10.5 + Double(index) * 0.4,
        text: " \(word)"
      )
    }

    let microphoneText = MeetingTranscriptFormatter.blocks(tokens: tokens)
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")

    #expect(microphoneText == "The release is Friday afternoon")
  }

  @Test func echoSuppressionDoesNotRemoveEarlierMicrophoneSpeech() {
    let words = ["Please", "review", "the", "quarterly", "release", "plan"]
    var tokens = words.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 9.5 + Double(index) * 0.3,
        endTime: 9.7 + Double(index) * 0.3,
        text: " \(word)"
      )
    }
    tokens += words.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10 + Double(index) * 0.3,
        endTime: 10.2 + Double(index) * 0.3,
        text: " \(word)"
      )
    }

    let microphoneText = MeetingTranscriptFormatter.blocks(tokens: tokens)
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")

    #expect(microphoneText == "Please review the quarterly release plan")
  }

  @Test func echoSuppressionPreservesTicketIdentifierCorrection() {
    let systemWords = ["Please", "review", "ticket", "BC1425", "before", "release"]
    let microphoneWords = ["Please", "review", "ticket", "BC1426", "before", "release"]
    var tokens = systemWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 10 + Double(index) * 0.4,
        endTime: 10.3 + Double(index) * 0.4,
        text: " \(word)"
      )
    }
    tokens += microphoneWords.enumerated().map { index, word in
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10.2 + Double(index) * 0.4,
        endTime: 10.5 + Double(index) * 0.4,
        text: " \(word)"
      )
    }

    let microphoneText = MeetingTranscriptFormatter.blocks(tokens: tokens)
      .filter { $0.source == .microphone }
      .map(\.text)
      .joined(separator: " ")

    #expect(microphoneText == "Please review ticket BC1426 before release")
  }

  @Test func meetingStoreRecoversInterruptedRecording() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingSessionStore(rootDirectory: directory)
    var session = MeetingSession(title: "Interrupted", status: .recording)
    session.manualNotesMarkdown = "- Follow up with the release owner."

    try await store.save(session)
    let sessionDirectory = directory.appendingPathComponent(session.id.uuidString)
    try Data().write(to: sessionDirectory.appendingPathComponent("system-0001.caf"))
    try Data().write(to: sessionDirectory.appendingPathComponent("microphone-0001.caf"))
    let loaded = await store.loadAll()

    #expect(loaded.count == 1)
    #expect(loaded[0].status == .interrupted)
    #expect(loaded[0].endedAt != nil)
    #expect(loaded[0].audioFiles == ["microphone-0001.caf", "system-0001.caf"])
    #expect(loaded[0].manualNotesMarkdown == "- Follow up with the release owner.")
  }

  @Test func legacyMeetingManifestWithoutManualNotesStillDecodes() throws {
    let id = UUID()
    let data = Data("""
    {
      "id": "\(id.uuidString)",
      "title": "Legacy meeting",
      "startedAt": "1970-01-01T00:00:00Z",
      "automaticallyStarted": false,
      "status": "completed",
      "transcriptTokens": [],
      "audioFiles": []
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let session = try decoder.decode(MeetingSession.self, from: data)

    #expect(session.manualNotesMarkdown == nil)
  }

  @Test(arguments: [false, true])
  func discardedNewRecordingStaysDeletedAfterLateWritesAndRelaunch(automatic: Bool) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingSessionStore(rootDirectory: directory)
    let existing = MeetingSession(
      title: "Keep this meeting", startedAt: Date(timeIntervalSince1970: 1_000), status: .completed
    )
    let recording = MeetingSession(title: "Accidental", automaticallyStarted: automatic)
    let runID = UUID()
    try await store.save(existing)
    try await store.beginRecording(recording, runID: runID, resuming: false)
    try await store.save(recording, runID: runID)
    let sessionDirectory = try await store.directory(for: recording.id)
    let writer = MeetingAudioSegmentWriter(directory: sessionDirectory, source: .microphone)
    try writer.append(samples: [0.1, -0.2, 0.3])
    writer.finish()
    try await store.saveManualNotes("Discarded notes", for: recording.id, revision: 1, runID: runID)

    #expect(try await store.discardRecording(recording, runID: runID, resuming: false) == nil)
    try await store.save(recording, runID: runID)
    try await store.saveManualNotes("Late notes", for: recording.id, revision: 99, runID: runID)
    #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
    let reloaded = await MeetingSessionStore(rootDirectory: directory).loadAll()
    #expect(reloaded == [existing])
  }

  @Test(arguments: [false, true])
  func discardedResumeRestoresEarlierBytesAndContentAfterRelaunch(hasSidecar: Bool) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingSessionStore(rootDirectory: directory)
    let original = MeetingSession(
      title: "Saved planning meeting",
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_030),
      recordedDuration: 30,
      status: .completed,
      transcriptTokens: [MeetingTranscriptToken(
        source: .systemAudio, startTime: 2, endTime: 3, text: " Earlier decision"
      )],
      manualNotesMarkdown: "Earlier notes",
      notesMarkdown: "Earlier summary",
      audioFiles: ["microphone-0001.caf", "system-0001.caf"],
      exportedMarkdownPath: "/synthetic/already-exported.md",
      attendees: ["Alex", "Jamie"],
      speakerNames: ["system:1": "Alex"],
      microphoneMutedRanges: [MeetingTimeRange(start: 5, end: 7)]
    )
    try await store.save(original)
    let sessionDirectory = try await store.directory(for: original.id)
    for source in MeetingAudioSource.captureSources {
      let writer = MeetingAudioSegmentWriter(directory: sessionDirectory, source: source)
      try writer.append(samples: [0.1, -0.4, 0.2, -0.1])
      writer.finish()
    }
    if hasSidecar {
      try await store.saveManualNotes("Earlier sidecar notes", for: original.id, revision: 1)
    }
    let earlierFiles = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)
    let earlierBytes = try Dictionary(uniqueKeysWithValues: earlierFiles.map {
      ($0, try Data(contentsOf: sessionDirectory.appendingPathComponent($0)))
    })
    let runID = UUID()
    try await store.beginRecording(original, runID: runID, resuming: true)
    var resumed = original
    resumed.status = .recording
    resumed.recordingStartedAt = Date()
    resumed.endedAt = nil
    resumed.title = "Changed during resume"
    resumed.attendees = ["New attendee"]
    resumed.speakerNames = ["system:1": "Changed speaker"]
    resumed.transcriptTokens.append(MeetingTranscriptToken(
      source: .microphone, startTime: 31, endTime: 32, text: " New content"
    ))
    try await store.save(resumed, runID: runID)
    try await store.saveManualNotes("New notes", for: original.id, revision: 2, runID: runID)
    let plan = MeetingResumePlan(session: original)
    for source in MeetingAudioSource.captureSources {
      let writer = MeetingAudioSegmentWriter(
        directory: sessionDirectory, source: source,
        initialSegmentIndex: plan.initialSegmentIndexes[source] ?? 0,
        timelineOffset: plan.timelineOffset
      )
      try writer.append(samples: [0.7, -0.8, 0.9])
      writer.finish()
    }

    let restored = try #require(await store.discardRecording(resumed, runID: runID, resuming: true))
    var expected = original
    if hasSidecar { expected.manualNotesMarkdown = "Earlier sidecar notes" }
    #expect(restored == expected)
    try await store.save(resumed, runID: runID)
    try await store.saveManualNotes("Late notes", for: original.id, revision: 99, runID: runID)
    for (filename, bytes) in earlierBytes {
      #expect(try Data(contentsOf: sessionDirectory.appendingPathComponent(filename)) == bytes)
    }
    #expect(await store.audioFiles(for: original.id) == original.audioFiles)
    #expect(await MeetingSessionStore(rootDirectory: directory).loadAll() == [expected])

    // A second resume starts from the restored meeting, not the discarded run.
    let nextRunID = UUID()
    try await store.beginRecording(expected, runID: nextRunID, resuming: true)
    resumed = expected
    resumed.status = .completed
    resumed.notesMarkdown = "Saved by a later normal stop"
    try await store.save(resumed, runID: nextRunID)
    try await store.finishRecording(resumed)
    #expect(!FileManager.default.fileExists(
      atPath: sessionDirectory.appendingPathComponent(".resume-checkpoint.json").path
    ))
    #expect(try await !store.save(original, runID: runID))
    #expect(try await !store.save(original, runID: nextRunID))
    #expect(await MeetingSessionStore(rootDirectory: directory).loadAll() == [resumed])
  }

  @Test(arguments: [false, true]) @MainActor
  func failedResumeDiscardIsRetryableAfterRelaunchAndCannotReplaceCheckpoint(
    damagedCheckpoint: Bool
  ) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failingFiles = MeetingDiscardFileManager { url in
      if !damagedCheckpoint && url.lastPathComponent == "system-0002.caf" {
        throw CocoaError(.fileWriteNoPermission)
      }
    }
    let store = MeetingSessionStore(rootDirectory: directory, fileManager: failingFiles)
    let original = MeetingSession(
      title: "Keep earlier content", startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_010), status: .completed,
      manualNotesMarkdown: "Earlier notes", audioFiles: ["microphone-0001.caf"]
    )
    try await store.save(original)
    let sessionDirectory = try await store.directory(for: original.id)
    let earlierAudio = sessionDirectory.appendingPathComponent("microphone-0001.caf")
    let bytes = Data("earlier audio".utf8)
    try bytes.write(to: earlierAudio)
    let runID = UUID()
    try await store.beginRecording(original, runID: runID, resuming: true)
    let checkpoint = sessionDirectory.appendingPathComponent(".resume-checkpoint.json")
    let checkpointBytes = try Data(contentsOf: checkpoint)
    if damagedCheckpoint {
      try Data("invalid checkpoint".utf8).write(to: checkpoint)
    }
    let protectedCheckpoint = try Data(contentsOf: checkpoint)
    try Data("new audio".utf8).write(
      to: sessionDirectory.appendingPathComponent("system-0002.caf")
    )
    do {
      _ = try await store.discardRecording(original, runID: runID, resuming: true)
      Issue.record("Discard should report the storage failure")
    } catch {
      #expect(try Data(contentsOf: earlierAudio) == bytes)
    }
    let coordinator = try await loadedCoordinator(store: store)
    let failed = try #require(coordinator.sessions.first)
    #expect(failed.pendingDiscard == .init(runID: runID, resuming: true))
    #expect(!coordinator.canResumeMeeting(failed))
    #expect(coordinator.canRetryDiscard(failed))
    await coordinator.resumeMeeting(failed)
    #expect(coordinator.activeSessionID == nil)
    // Even a stale caller cannot overwrite the unresolved checkpoint at the store boundary.
    await #expect(throws: CocoaError.self) {
      try await store.beginRecording(original, runID: UUID(), resuming: true)
    }
    await coordinator.retryDiscard(failed.id)
    #expect(coordinator.sessions.first?.pendingDiscard != nil)
    #expect(coordinator.lastError?.contains("Retry Discard") == true)
    #expect(try Data(contentsOf: checkpoint) == protectedCheckpoint)

    // Repair the fault, relaunch with a fresh store, and retry through the application API.
    try checkpointBytes.write(to: checkpoint)
    let relaunched = try await loadedCoordinator(
      store: MeetingSessionStore(rootDirectory: directory)
    )
    await relaunched.retryDiscard(failed.id)
    #expect(relaunched.sessions == [original])
    #expect(relaunched.canResumeMeeting(original))
    #expect(relaunched.lastError == nil)
    #expect(try Data(contentsOf: earlierAudio) == bytes)
    #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
    #expect(!FileManager.default.fileExists(
      atPath: sessionDirectory.appendingPathComponent("system-0002.caf").path
    ))
  }

  @Test @MainActor func pendingDiscardBlocksContentActionsAndLateSummaryDuringRetry() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let removal = AsyncStream<Void>.makeStream()
    let files = MeetingDiscardFileManager { url in
      if url.lastPathComponent == "system-0002.caf" {
        removal.continuation.yield(())
        gate.wait()
      }
    }
    let store = MeetingSessionStore(rootDirectory: directory, fileManager: files)
    let original = MeetingSession(
      title: "Earlier meeting", startedAt: Date(timeIntervalSince1970: 1_000), status: .completed,
      transcriptTokens: [MeetingTranscriptToken(
        source: .systemAudio, startTime: 1, endTime: 2, text: " Earlier decision", speaker: "1"
      )], manualNotesMarkdown: "Earlier manual notes", notesMarkdown: "Earlier summary",
      attendees: ["Alex"]
    )
    try await store.save(original)
    let runID = UUID()
    try await store.beginRecording(original, runID: runID, resuming: true)
    let folder = try await store.directory(for: original.id)
    try Data("resumed audio".utf8).write(to: folder.appendingPathComponent("system-0002.caf"))
    var pending = original
    pending.status = .failed
    pending.pendingDiscard = .init(runID: runID, resuming: true)
    pending.transcriptTokens.append(MeetingTranscriptToken(
      source: .microphone, startTime: 5, endTime: 6, text: " Discarded new decision"
    ))
    pending.manualNotesMarkdown = "Discarded new manual notes"
    pending.audioFiles = ["system-0002.caf"]
    try await store.save(pending)
    let unrelated = MeetingSession(
      title: "Other saved meeting", status: .completed, manualNotesMarkdown: "Other notes",
      notesMarkdown: "Old summary"
    )
    try await store.save(unrelated)
    let generationReply = AsyncStream<Void>.makeStream()
    let requests = AsyncStream<String>.makeStream()
    let coordinator = try await loadedCoordinator(store: store, noteGenerator: { input, _, _ in
      requests.continuation.yield(input.transcriptPlainText)
      var replies = generationReply.stream.makeAsyncIterator()
      _ = await replies.next()
      return MeetingGeneratedNotes(
        title: nil, markdown: input.id == unrelated.id
          ? "Updated other summary" : "Summary of discarded new decision"
      )
    })
    #expect(!coordinator.canUseMeetingContent(pending.id))
    #expect(!coordinator.canSendToWebhooks(original)) // A stale snapshot cannot bypass pending.
    coordinator.updateTitle("Wrong title", for: pending.id)
    coordinator.updateAttendees("Wrong attendee", for: pending.id)
    coordinator.renameSpeaker(.init(source: .systemAudio, label: "1"), to: "Wrong", in: pending.id)
    #expect(coordinator.sessions.first(where: { $0.id == pending.id }) == pending)
    // An unrelated summary remains eligible while this discard awaits I/O.
    let unrelatedGeneration = Task { await coordinator.regenerateNotes(for: unrelated) }
    var requested = requests.stream.makeAsyncIterator()
    #expect(await requested.next() == unrelated.transcriptPlainText)
    let retry = Task { await coordinator.retryDiscard(pending.id) }
    var iterator = removal.stream.makeAsyncIterator()
    await iterator.next()
    #expect(coordinator.isStopping)
    #expect(coordinator.canUseMeetingContent(unrelated.id))
    generationReply.continuation.finish()
    var regeneration: Task<Void, Never>?
    await withCheckedContinuation { started in
      regeneration = Task {
        started.resume()
        await coordinator.regenerateNotes(for: pending)
      }
    }
    var deletion: Task<Void, Never>?
    await withCheckedContinuation { started in
      deletion = Task {
        started.resume()
        await coordinator.delete(pending)
      }
    }
    gate.signal()
    await deletion?.value
    await retry.value
    await unrelatedGeneration.value
    await regeneration?.value
    requests.continuation.finish()
    var summarizedTranscripts: [String] = []
    for await transcript in requests.stream { summarizedTranscripts.append(transcript) }
    #expect(summarizedTranscripts.isEmpty)
    #expect(coordinator.sessions.first(where: { $0.id == original.id }) == original)
    let saved = await MeetingSessionStore(rootDirectory: directory).loadAll()
    #expect(saved.first(where: { $0.id == original.id }) == original)
    #expect(saved.first(where: { $0.id == unrelated.id })?.notesMarkdown == "Updated other summary")
    #expect(coordinator.canUseMeetingContent(original.id))
    #expect(coordinator.canSendToWebhooks(original))
    // Once cleanup finishes, an intentional Delete remains available and stays deleted.
    await coordinator.delete(original)
    await coordinator.retryDiscard(original.id)
    #expect(!coordinator.sessions.contains(where: { $0.id == original.id }))
    #expect(await MeetingSessionStore(rootDirectory: directory).loadAll().count == 1)
  }

  @Test func failedFreshDiscardKeepsRetryManifestUntilAudioCleanupCompletes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = MeetingDiscardFileManager { url in
      if url.pathExtension == "caf" { throw CocoaError(.fileWriteNoPermission) }
    }
    let store = MeetingSessionStore(rootDirectory: directory, fileManager: files)
    let recording = MeetingSession(title: "Discard this new meeting", status: .recording)
    let runID = UUID()
    try await store.beginRecording(recording, runID: runID, resuming: false)
    try await store.save(recording, runID: runID)
    let folder = try await store.directory(for: recording.id)
    try Data("new audio".utf8).write(to: folder.appendingPathComponent("system-0001.caf"))
    await #expect(throws: CocoaError.self) {
      _ = try await store.discardRecording(recording, runID: runID, resuming: false)
    }
    let relaunched = MeetingSessionStore(rootDirectory: directory)
    let pending = try #require(await relaunched.loadAll().first)
    #expect(pending.pendingDiscard == .init(runID: runID, resuming: false))
    #expect(pending.audioFiles == ["system-0001.caf"])
    #expect(try await relaunched.discardRecording(pending, runID: runID, resuming: false) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test func manualNotesSidecarRestoresLatestTypedNotes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingSessionStore(rootDirectory: directory)
    var session = MeetingSession(title: "Planning", status: .completed)
    session.manualNotesMarkdown = "- Older manifest note"

    try await store.save(session)
    try await store.saveManualNotes("- Older typed note", for: session.id, revision: 1)
    try await store.saveManualNotes("- Latest typed note", for: session.id, revision: 2)
    try await store.saveManualNotes("- Stale typed note", for: session.id, revision: 1)
    let loaded = await store.loadAll()

    #expect(loaded.count == 1)
    #expect(loaded[0].manualNotesMarkdown == "- Latest typed note")
  }

  @Test func emptyManualNotesSidecarClearsOlderManifestNotes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingSessionStore(rootDirectory: directory)
    var session = MeetingSession(title: "Planning", status: .completed)
    session.manualNotesMarkdown = "- Old note"

    try await store.save(session)
    try await store.saveManualNotes(nil, for: session.id, revision: 1)
    let loaded = await store.loadAll()

    #expect(loaded.count == 1)
    #expect(loaded[0].manualNotesMarkdown == nil)
  }

  @Test func obsidianDocumentContainsNotesAndTranscript() {
    var session = MeetingSession(title: "Planning", startedAt: Date(timeIntervalSince1970: 0))
    session.endedAt = Date(timeIntervalSince1970: 300)
    session.manualNotesMarkdown = "- Dane owns the release announcement."
    session.notesMarkdown = "## Summary\n\nWe planned the release."
    session.transcriptTokens = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 3,
        endTime: 4,
        text: "Ship it."
      )
    ]

    let document = MeetingObsidianExporter.document(for: session)

    #expect(document.contains("# Planning"))
    #expect(document.contains("duration_minutes: 5"))
    #expect(document.contains("We planned the release."))
    #expect(document.contains("## Manual notes"))
    #expect(document.contains("Dane owns the release announcement."))
    #expect(document.contains("**You [00:03]:** Ship it."))
  }

  @Test func noteGeneratorSourceMaterialCombinesManualNotesAndTranscript() {
    let source = MeetingNoteGenerator.sourceMaterial(
      transcript: "We agreed to ship on Friday.",
      manualNotes: "- Casey owns the release checklist."
    )

    #expect(source.contains("MANUAL NOTES"))
    #expect(source.contains("Casey owns the release checklist."))
    #expect(source.contains("TRANSCRIPT"))
    #expect(source.contains("We agreed to ship on Friday."))
  }

  @Test func noteGeneratorOmitsReasoningForBroadModelCompatibility() {
    #expect(MeetingNoteGenerator.reasoningMode == .omit)
  }

  @Test func meetingNoteRetryPolicyRetriesTransientFailuresOnly() {
    #expect(MeetingNoteRetryPolicy.maximumAttempts == 3)
    #expect(MeetingNoteRetryPolicy.shouldRetry(URLError(.timedOut)))
    #expect(MeetingNoteRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
    #expect(MeetingNoteRetryPolicy.shouldRetry(ProviderError.http(status: 408, body: "timeout")))
    #expect(MeetingNoteRetryPolicy.shouldRetry(ProviderError.http(status: 429, body: "busy")))
    #expect(MeetingNoteRetryPolicy.shouldRetry(ProviderError.http(status: 503, body: "down")))
    #expect(!MeetingNoteRetryPolicy.shouldRetry(ProviderError.http(status: 401, body: "bad key")))
    #expect(!MeetingNoteRetryPolicy.shouldRetry(ProviderError.decodingFailed))
    #expect(MeetingNoteRetryPolicy.isCancellation(URLError(.cancelled)))
  }

  @Test func meetingNoteRetryPolicyUsesBoundedExponentialBackoff() {
    #expect(MeetingNoteRetryPolicy.delay(afterAttempt: 1) == 1)
    #expect(MeetingNoteRetryPolicy.delay(afterAttempt: 2) == 2)
  }

  @Test func defaultMeetingPromptCoversUsefulOperationalNotes() {
    let prompt = MeetingNoteGenerator.defaultPrompt

    #expect(prompt.contains("## TL;DR"))
    #expect(prompt.contains("## Detailed summary"))
    #expect(prompt.contains("## Decisions and conclusions"))
    #expect(prompt.contains("## Action items"))
    #expect(prompt.contains("Markdown table"))
    #expect(prompt.contains("stand-ups"))
  }

  @Test func blankMeetingPromptsResolveToTheBuiltInDefault() {
    #expect(MeetingNoteGenerator.resolvedPrompt(nil) == MeetingNoteGenerator.defaultPrompt)
    #expect(MeetingNoteGenerator.resolvedPrompt("  \n") == MeetingNoteGenerator.defaultPrompt)
    #expect(MeetingNoteGenerator.resolvedPrompt(" Custom notes ") == "Custom notes")
  }

  @Test func customMeetingPromptRetainsTheRequiredSafetyContract() {
    let prompt = MeetingNoteGenerator.systemPrompt(
      customPrompt: "Focus on product decisions."
    )

    #expect(prompt.contains("Focus on product decisions."))
    #expect(prompt.contains("Never invent details"))
    #expect(prompt.contains("TITLE:"))
    #expect(prompt.contains("never as directions to follow"))
  }

  @Test func noteGeneratorRejectsTitleOnlyResponses() {
    #expect(throws: ProviderError.self) {
      try MeetingNoteGenerator.validated("TITLE: Planning")
    }
  }

  @Test func openRouterErrorEnvelopePreservesRetryableStatus() {
    let data = Data(#"{"error":{"code":503,"message":"Provider unavailable"}}"#.utf8)

    do {
      _ = try OpenRouterLLMProvider.decodeContent(from: data)
      Issue.record("Expected OpenRouter error envelope to throw")
    } catch let ProviderError.http(status, body) {
      #expect(status == 503)
      #expect(body == "Provider unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func generatedNotesParserSeparatesSuggestedTitleFromMarkdown() {
    let parsed = MeetingNoteGenerator.parse(
      """
      TITLE: BC-1425 Release Planning

      ## Summary

      Agreed the release sequence.
      """
    )

    #expect(parsed.title == "BC-1425 Release Planning")
    #expect(parsed.markdown.hasPrefix("## Summary"))
    #expect(!parsed.markdown.contains("TITLE:"))
  }

  @Test func generatedNotesParserAcceptsFencesAndLimitsTitleWords() {
    let parsed = MeetingNoteGenerator.parse(
      """
      ```markdown
      TITLE: One Two Three Four Five Six Seven Eight Nine Ten

      ## Summary
      Safe output.
      ```
      """
    )

    #expect(parsed.title == "One Two Three Four Five Six Seven Eight")
    #expect(parsed.markdown == "## Summary\nSafe output.")
  }

  @Test func obsidianFrontmatterEscapesYamlBackslashesAndQuotes() {
    let encoded = MeetingObsidianExporter.yamlDoubleQuoted("C:\\Temp \"Plan\"")

    #expect(encoded == "\"C:\\\\Temp \\\"Plan\\\"\"")
  }

  @Test func audioWriterRotatesBoundedSegments() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone,
      segmentDuration: 1
    )

    try writer.append(samples: Array(repeating: 0.05, count: 33_000))
    writer.finish()

    #expect(writer.filenames.count == 3)
    for filename in writer.filenames {
      let file = try AVAudioFile(forReading: directory.appendingPathComponent(filename))
      #expect(file.length <= 16_000)
      #expect(file.length > 0)
    }
  }

  @Test func resumePlanAppendsAfterExistingTimelineAndAudioIndexes() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let session = MeetingSession(
      title: "Planning",
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(90),
      status: .completed,
      transcriptTokens: [
        MeetingTranscriptToken(
          source: .microphone,
          startTime: 94,
          endTime: 95,
          text: " tail"
        )
      ],
      audioFiles: [
        "microphone-0001.caf",
        "microphone-0002-60000.caf",
        "system-0001.caf"
      ]
    )

    let plan = MeetingResumePlan(session: session)

    #expect(plan.timelineOffset == 95)
    #expect(plan.initialSegmentIndexes[.microphone] == 2)
    #expect(plan.initialSegmentIndexes[.systemAudio] == 1)
    #expect(MeetingResumePlan.canResume(session))
  }

  @Test func resumedDurationExcludesTimeBetweenRecordingRuns() {
    let session = MeetingSession(
      title: "Planning",
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 10_000),
      recordedDuration: 120,
      status: .completed
    )

    #expect(session.duration == 120)
  }

  @Test func resumedAudioWriterUsesNonCollidingIndexAndExplicitTimeline() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone,
      segmentDuration: 1,
      initialSegmentIndex: 4,
      timelineOffset: 12.5
    )

    try writer.append(samples: Array(repeating: 0.05, count: 17_000))
    writer.finish()

    #expect(writer.filenames == [
      "microphone-0005-12500.caf",
      "microphone-0006-13500.caf"
    ])
    let segment = try #require(MeetingTranscriptRecoveryService.segment(
      filename: writer.filenames[0],
      duration: 1
    ))
    #expect(segment.index == 5)
    #expect(segment.startTime == 12.5)
  }

  @Test func resumedAudioWriterNeverOverwritesAnExistingSegment() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let existingURL = directory.appendingPathComponent("microphone-0005-12500.caf")
    let original = Data("do not replace".utf8)
    try original.write(to: existingURL)
    let writer = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone,
      initialSegmentIndex: 4,
      timelineOffset: 12.5
    )

    #expect(throws: MeetingAudioSegmentWriterError.self) {
      try writer.append(samples: [0.05])
    }
    #expect(try Data(contentsOf: existingURL) == original)
  }

  @Test func resumedTwoChannelStreamUsesRunLocalTime() {
    let chunk = MeetingAudioChunk(
      source: .systemAudio,
      samples: [0.1],
      startTime: 95.2,
      duration: 0.1
    )

    let local = MeetingTranscriptionService.streamLocalChunk(
      chunk,
      timelineOffset: 95
    )

    #expect(abs(local.startTime - 0.2) < 0.000_001)
    #expect(local.samples == chunk.samples)
  }

  @Test func triggerBundleMatchingUsesCaseInsensitiveComponentBoundaries() {
    #expect(MeetingDetector.bundleIDMatches(
      "Com.Microsoft.Teams2.Helper",
      prefix: "com.microsoft.teams2"
    ))
    #expect(MeetingDetector.bundleIDMatches(
      "us.zoom.xos",
      prefix: "US.ZOOM.XOS"
    ))
    #expect(!MeetingDetector.bundleIDMatches(
      "com.microsoft.teams20",
      prefix: "com.microsoft.teams2"
    ))
  }

  @Test func inferredTriggerRulesKeepBrowsersStrictAndCustomAppsExplicit() throws {
    let browser = try #require(MeetingTriggerRule.inferred(
      bundleID: "com.google.Chrome",
      displayName: "Chrome"
    ))
    let custom = try #require(MeetingTriggerRule.inferred(
      bundleID: "com.example.calls",
      displayName: "Example Calls"
    ))

    #expect(browser.detectionMode == .googleMeet)
    #expect(browser.captureScope == .knownFamily("chrome"))
    #expect(custom.detectionMode == .microphone)
    #expect(custom.captureScope == .bundlePrefix("com.example.calls"))
    #expect(MeetingTriggerRule.defaultRules.contains {
      $0.bundleIDPrefix.caseInsensitiveCompare("us.zoom.xos") == .orderedSame
    })
    #expect(MeetingTriggerRule.defaultRules.contains {
      $0.bundleIDPrefix.caseInsensitiveCompare("com.microsoft.teams2") == .orderedSame
    })
  }

  @Test func triggerRulesPersistWithoutDuplicateEntries() throws {
    let suiteName = "MeetingTriggerRules-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let zoom = try #require(MeetingTriggerRule.inferred(
      bundleID: "us.zoom.xos",
      displayName: "Zoom"
    ))

    MeetingTriggerRule.save([zoom, zoom], defaults: defaults)
    let loaded = MeetingTriggerRule.load(defaults: defaults)

    #expect(loaded == [zoom])
  }

  @Test func recoveryParserUsesFilenameIndexAndAudioDuration() throws {
    let microphone = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0003.caf",
      duration: 43.25
    ))
    let system = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "system-0002.caf",
      duration: 60
    ))

    #expect(microphone.source == .microphone)
    #expect(microphone.index == 3)
    #expect(microphone.startTime == 120)
    #expect(microphone.endTime == 163.25)
    #expect(system.source == .systemAudio)
    #expect(system.startTime == 60)
    #expect(MeetingTranscriptRecoveryService.segment(
      filename: "../system-0001.caf",
      duration: 60
    ) == nil)
  }

  @Test func recoveryPlanRetainsEarlierTokensAndReplacesOverlappingTail() throws {
    let first = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0001.caf",
      duration: 60
    ))
    let second = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0002.caf",
      duration: 60
    ))
    let third = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0003.caf",
      duration: 12
    ))
    let tokens = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 10,
        endTime: 11,
        text: " earlier"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 70,
        endTime: 71,
        text: " replace me"
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 80,
        endTime: 81,
        text: " other source"
      )
    ]

    let plan = MeetingTranscriptRecoveryService.recoveryPlan(
      segments: [third, first, second],
      existingTokens: tokens,
      sourcesNeedingRecovery: [.microphone]
    )

    #expect(plan.segmentsToTranscribe.map(\.filename) == [
      "microphone-0002.caf",
      "microphone-0003.caf"
    ])
    #expect(plan.retainedTokens.map(\.text) == [" earlier", " other source"])
    #expect(plan.recoverableSources == [.microphone])

    let fullPlan = MeetingTranscriptRecoveryService.recoveryPlan(
      segments: [third, first, second],
      existingTokens: tokens,
      sourcesNeedingRecovery: [.microphone],
      fullRecoverySources: [.microphone]
    )
    #expect(fullPlan.segmentsToTranscribe.map(\.filename) == [
      "microphone-0001.caf",
      "microphone-0002.caf",
      "microphone-0003.caf"
    ])
    #expect(fullPlan.retainedTokens.map(\.text) == [" other source"])
  }

  @Test func recoveryUsesInjectedTranscriberOnlyForTailSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone,
      segmentDuration: 1
    )
    try writer.append(samples: Array(repeating: 0.05, count: 33_000))
    writer.finish()
    let spy = MeetingRecoveryTranscriptionSpy()
    let service = MeetingTranscriptRecoveryService { url in
      await spy.transcribe(url)
    }
    let existing = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 0.2,
        endTime: 0.4,
        text: " earlier"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 60.2,
        endTime: 60.4,
        text: " replace me"
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 70,
        endTime: 71,
        text: " untouched"
      )
    ]

    let result = try await service.recover(
      sessionDirectory: directory,
      audioFilenames: writer.filenames,
      existingTokens: existing,
      sourcesNeedingRecovery: [.microphone]
    )

    #expect(await spy.calls() == ["microphone-0002.caf", "microphone-0003.caf"])
    #expect(result.recoveredSources == [.microphone])
    #expect(result.tokens.map(\.startTime) == [0.2, 60, 70, 120])
    #expect(result.tokens.map(\.text) == [
      " earlier",
      " Recovered microphone-0002.caf",
      " untouched",
      " Recovered microphone-0003.caf"
    ])
  }

  @Test func rawRecoveryReplacesFailedMixedStreamTokens() throws {
    let microphone = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0001.caf",
      duration: 60
    ))
    let system = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "system-0001.caf",
      duration: 60
    ))
    let mixedToken = MeetingTranscriptToken(
      source: .mixed,
      startTime: 10,
      endTime: 11,
      text: " mixed partial"
    )

    let plan = MeetingTranscriptRecoveryService.recoveryPlan(
      segments: [microphone, system],
      existingTokens: [mixedToken],
      sourcesNeedingRecovery: MeetingAudioSource.captureSources
    )

    #expect(plan.retainedTokens.isEmpty)
    #expect(plan.segmentsToTranscribe.count == 2)
  }

  @Test func rawRecoveryRetainsMixedTokensWhenOneRawTrackIsMissing() throws {
    let microphone = try #require(MeetingTranscriptRecoveryService.segment(
      filename: "microphone-0001.caf",
      duration: 60
    ))
    let mixedToken = MeetingTranscriptToken(
      source: .mixed,
      startTime: 10,
      endTime: 11,
      text: " mixed fallback"
    )

    let plan = MeetingTranscriptRecoveryService.recoveryPlan(
      segments: [microphone],
      existingTokens: [mixedToken],
      sourcesNeedingRecovery: MeetingAudioSource.captureSources
    )

    #expect(plan.retainedTokens == [mixedToken])
    #expect(plan.segmentsToTranscribe == [microphone])
    #expect(plan.recoverableSources == [.microphone])
  }

  @Test func vaultIndexNormalizesSpokenAndWrittenTicketIdentifiers() {
    let identifiers = MeetingVaultIndex.extractIdentifiers(
      from: "Discuss BC1425, INT-531, BC 1425, and B C 1426 in July 2026."
    )

    #expect(identifiers == ["BC-1425", "INT-531", "BC-1426"])
  }

  @Test func vaultIndexFindsIdentifiersInNoteFilenames() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".obsidian"),
      withIntermediateDirectories: true
    )
    try Data("Release planning details".utf8).write(
      to: directory.appendingPathComponent("BC-1425.md")
    )

    let matches = try await MeetingVaultIndex().search(
      identifier: "BC1425",
      from: directory
    )

    #expect(matches.first?.title == "BC-1425")
  }

  @Test func vaultIndexRanksRelevantTopicNotes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".obsidian"),
      withIntermediateDirectories: true
    )
    try Data("Grok 4.5 launched with a new agentic tool-calling model.".utf8).write(
      to: directory.appendingPathComponent("2026-07-09 AI Engineering Briefing.md")
    )
    try Data("Quarterly studio operations and payroll notes.".utf8).write(
      to: directory.appendingPathComponent("Studio Operations.md")
    )

    let matches = try await MeetingVaultIndex().search(
      query: "Grok 4.5",
      from: directory
    )

    #expect(matches.first?.title == "2026-07-09 AI Engineering Briefing")
    #expect(matches.first?.excerpt.contains("Grok 4.5") == true)
  }

  @Test func vaultIndexMatchesMultiEntityDiscussion() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".obsidian"),
      withIntermediateDirectories: true
    )
    try Data(
      "Microsoft is reducing model dependence across OpenAI and Anthropic providers.".utf8
    ).write(to: directory.appendingPathComponent("AI Provider Strategy.md"))

    let matches = try await MeetingVaultIndex().search(
      query: "Microsoft OpenAI Anthropic dependence",
      from: directory
    )

    #expect(matches.first?.title == "AI Provider Strategy")
  }

  @Test func recentContextTokensCoverOnlyLatestThirtySeconds() {
    let tokens = [
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 0,
        endTime: 1,
        text: " old"
      ),
      MeetingTranscriptToken(
        source: .systemAudio,
        startTime: 29,
        endTime: 30,
        text: " boundary"
      ),
      MeetingTranscriptToken(
        source: .microphone,
        startTime: 59,
        endTime: 60,
        text: " latest"
      )
    ]

    let recent = MeetingTranscriptFormatter.recentTokens(tokens, duration: 30)

    #expect(recent.map(\.text) == [" boundary", " latest"])
  }

  @Test func ticketLinksRouteJiraAndLinearIdentifiers() throws {
    let suiteName = "MeetingFeatureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MeetingTicketLink.url(for: "BC1425", defaults: defaults)?.absoluteString
      == "https://hapana.atlassian.net/browse/BC-1425")
    #expect(MeetingTicketLink.url(for: "OC-567", defaults: defaults)?.absoluteString
      == "https://linear.app/hapana/issue/OC-567")
    #expect(MeetingTicketLink.url(for: "Grok 4.5", defaults: defaults) == nil)
  }

  @Test func vaultIndexReportsMissingOrEmptyVaults() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("Missing")
    var missingError: Error?
    do {
      _ = try await MeetingVaultIndex().refresh(from: missing)
    } catch {
      missingError = error
    }
    #expect(missingError is MeetingVaultIndexError)

    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".obsidian"),
      withIntermediateDirectories: true
    )
    var emptyError: Error?
    do {
      _ = try await MeetingVaultIndex().refresh(from: directory)
    } catch {
      emptyError = error
    }
    #expect(emptyError is MeetingVaultIndexError)
  }

  @Test func contextCloudEvidenceOmitsLocalFilePaths() {
    let match = MeetingContextMatch(
      title: "AI Provider Strategy",
      path: "/Users/example/Private Vault/AI Provider Strategy.md",
      excerpt: "Microsoft is evaluating OpenAI and Anthropic."
    )

    let evidence = MeetingContextSummarizer.evidence(from: [match])

    #expect(evidence.contains("AI Provider Strategy"))
    #expect(evidence.contains("Microsoft is evaluating"))
    #expect(!evidence.contains("/Users/example"))
  }

  @Test func contextBatchSummaryParserPreservesTopicOrder() {
    let summaries = MeetingContextSummarizer.parseBatchSummaries(
      "CONTEXT 2: Second brief.\nCONTEXT 1: First brief.",
      count: 2
    )

    #expect(summaries[0] == "First brief.")
    #expect(summaries[1] == "Second brief.")
  }

  @Test func meetingContextOmitsReasoningOverrideForModelCompatibility() {
    #expect(MeetingContextSummarizer.reasoningMode == .omit)
  }

  @Test func meetingDetectorGroupsSupportedCallApplications() {
    #expect(MeetingDetector.family(for: "com.tinyspeck.slackmacgap") == "slack")
    #expect(MeetingDetector.family(for: "com.google.Chrome.helper") == "chrome")
    #expect(MeetingDetector.family(for: "company.thebrowser.dia.helper") == "dia")
    #expect(MeetingDetector.family(for: "company.thebrowser.Browser") == "arc")
    #expect(MeetingDetector.family(
      for: "company.thebrowser.browser.helper",
      executablePath: "/Applications/Dia.app/Contents/Frameworks/Browser Helper.app"
    ) == "dia")
    #expect(MeetingDetector.family(
      for: "company.thebrowser.browser.helper"
    ) == "thebrowser")
    #expect(MeetingDetector.familyMatches(
      processFamily: "thebrowser",
      includedFamily: "dia"
    ))
    #expect(MeetingDetector.familyMatches(
      processFamily: "thebrowser",
      includedFamily: "arc"
    ))
    #expect(MeetingApplicationScope.knownFamily("dia").matches(
      bundleID: "company.thebrowser.browser.helper",
      executablePath: "/Applications/Dia.app/Contents/Frameworks/Browser Helper.app"
    ))
    #expect(!MeetingDetector.familyMatches(
      processFamily: "thebrowser",
      includedFamily: "chrome"
    ))
    #expect(MeetingDetector.family(for: "com.apple.Safari") == "safari")
    #expect(MeetingDetector.family(for: "com.apple.FaceTime") == nil)
    #expect(MeetingDetector.meetAudioIsActive(hasInput: true, hasOutput: true))
    #expect(!MeetingDetector.meetAudioIsActive(hasInput: true, hasOutput: false))
    #expect(!MeetingDetector.meetAudioIsActive(hasInput: false, hasOutput: true))
    #expect(!MeetingDetector.meetAudioIsActive(hasInput: false, hasOutput: false))
    #expect(MeetingDetector.firstActiveMeetFamily(
      windowFamilies: ["chrome", "dia"],
      activeFamilies: ["dia"]
    ) == "dia")
    #expect(MeetingDetector.firstActiveMeetFamily(
      windowFamilies: ["chrome", "dia"],
      activeFamilies: []
    ) == nil)
  }

  @Test func meetingDetectionConfirmsQuicklyWithoutRetriggeringTheSameCall() {
    #expect(!MeetingDetectionPolicy.schedulingAllowed)
    #expect(MeetingDetectionPolicy.idleFallbackInterval == 5)
    #expect(MeetingDetectionPolicy.suspiciousPollInterval == 3)
    #expect(MeetingDetectionPolicy.activeMeetingPollInterval == 5)
    #expect(MeetingDetectionPolicy.eventConfirmationDelay == 1)
    #expect(
      MeetingDetectionPolicy.idleFallbackInterval
        + MeetingDetectionPolicy.eventConfirmationDelay < 10
    )
    #expect(!MeetingDetectionPolicy.confirmsAutomaticStart(stableDuration: 0.99))
    #expect(MeetingDetectionPolicy.confirmsAutomaticStart(stableDuration: 1))
    #expect(MeetingDetectionPolicy.endConfirmationDelay == 30)
    #expect(
      MeetingDetectionPolicy.suppressionReleaseDelay
        >= MeetingDetectionPolicy.endConfirmationDelay
    )
    #expect(!MeetingDetectionPolicy.releasesSuppression(
      detectedFamily: "dia",
      suppressedFamily: "dia",
      absentDuration: 60
    ))
    #expect(!MeetingDetectionPolicy.releasesSuppression(
      detectedFamily: nil,
      suppressedFamily: "dia",
      absentDuration: MeetingDetectionPolicy.suppressionReleaseDelay - 0.1
    ))
    #expect(MeetingDetectionPolicy.releasesSuppression(
      detectedFamily: nil,
      suppressedFamily: "dia",
      absentDuration: MeetingDetectionPolicy.suppressionReleaseDelay
    ))
    #expect(MeetingDetectionPolicy.releasesSuppression(
      detectedFamily: "slack",
      suppressedFamily: "dia",
      absentDuration: 0
    ))
    #expect(!MeetingDetectionPolicy.confirmsMeetingEnded(
      likelyStillActive: false,
      absentDuration: MeetingDetectionPolicy.endConfirmationDelay - 0.1
    ))
    #expect(MeetingDetectionPolicy.confirmsMeetingEnded(
      likelyStillActive: false,
      absentDuration: MeetingDetectionPolicy.endConfirmationDelay
    ))
    #expect(!MeetingDetectionPolicy.confirmsMeetingEnded(
      likelyStillActive: true,
      absentDuration: MeetingDetectionPolicy.endConfirmationDelay * 2
    ))
    #expect(!MeetingStatus.processing.isTerminal)
    #expect(MeetingStatus.completed.isTerminal)
  }

  @Test func meetingDetectionPollingAdaptsToCurrentEvidence() {
    #expect(MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: false,
      activeMeetingIsAutomatic: nil,
      hasSuspiciousSignal: false
    ) == nil)
    #expect(MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: true,
      activeMeetingIsAutomatic: false,
      hasSuspiciousSignal: true
    ) == nil)
    #expect(MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: true,
      activeMeetingIsAutomatic: nil,
      hasSuspiciousSignal: false
    ) == MeetingDetectionPolicy.idleFallbackInterval)
    #expect(MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: true,
      activeMeetingIsAutomatic: nil,
      hasSuspiciousSignal: true
    ) == MeetingDetectionPolicy.suspiciousPollInterval)
    #expect(MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: true,
      activeMeetingIsAutomatic: true,
      hasSuspiciousSignal: false
    ) == MeetingDetectionPolicy.activeMeetingPollInterval)
  }

  @Test func meetingDetectorSnapshotExpiresBeforeTheNextStartPoll() {
    #expect(MeetingDetector.audioProcessSnapshotCacheDuration > 0)
    #expect(
      MeetingDetector.audioProcessSnapshotCacheDuration
        < MeetingDetectionPolicy.eventConfirmationDelay
    )
  }

  @Test func browserMeetingTitlesRecognizeMeetAndZoomWithoutMatchingGenericPages() {
    #expect(MeetingDetector.browserMeetingName(
      windowTitle: "Daily stand-up - Google Meet"
    ) == "Google Meet")
    #expect(MeetingDetector.browserMeetingName(
      windowTitle: "Daily stand-up | Zoom"
    ) == "Zoom")
    #expect(MeetingDetector.browserMeetingName(
      windowTitle: "Zoom Meeting"
    ) == "Zoom")
    #expect(MeetingDetector.browserMeetingName(
      windowTitle: "Zoom Video Communications"
    ) == nil)
  }

  @Test func meetingTranscriptionEngineDefaultsLocalAndRetiresSingleStreamSoniox() throws {
    let suiteName = "MeetingFeatureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .parakeet)
    defaults.set("soniox", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .sonioxSeparate)
    defaults.set("soniox-separate", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .sonioxSeparate)
    defaults.set("xai-grok", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .xaiGrok)
    #expect(!MeetingTranscriptionEngine.selectableCases.contains(.soniox))
    defaults.set("unknown", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .parakeet)
  }

  @Test func meetingSonioxPCMConversionClampsAndUsesLittleEndian() {
    let data = MeetingTranscriptionService.pcm16Data(
      samples: [-2, -0.5, 0, 0.5, 2]
    )

    func value(at index: Int) -> Int16 {
      let low = UInt16(data[index * 2])
      let high = UInt16(data[index * 2 + 1]) << 8
      return Int16(bitPattern: low | high)
    }

    #expect(data.count == 10)
    #expect(value(at: 0) == Int16.min)
    #expect(value(at: 1) == -16_384)
    #expect(value(at: 2) == 0)
    #expect(value(at: 3) == 16_384)
    #expect(value(at: 4) == Int16.max)
  }

  @Test func sonioxParserExposesFinalTimingAndSpeakerMetadata() {
    let payload = """
    {
      "tokens": [
        {"text":" Hello","start_ms":120,"end_ms":420,"is_final":true,"speaker":"1"},
        {"text":" wor","start_ms":420,"end_ms":560,"is_final":false}
      ]
    }
    """

    let tokens = SonioxStreamingProvider.realtimeTokens(from: payload)

    #expect(tokens.count == 2)
    #expect(tokens[0] == SonioxRealtimeToken(
      text: " Hello",
      startMs: 120,
      endMs: 420,
      isFinal: true,
      speaker: "1"
    ))
    #expect(tokens[1].isFinal == false)
  }

  @Test func grokEventsCarryChannelAndOneBasedSpeakers() {
    let partial = XAIMeetingStreamingProvider.event(from: """
    {"type":"transcript.partial","text":"Sure, the build","is_final":true,"speech_final":false,
     "channel_index":1,"words":[
       {"text":"Sure,","start":5.041,"end":5.6,"speaker":0},
       {"text":"the","start":5.703,"end":5.8,"speaker":1},
       {"text":" ","start":5.9,"end":5.9}
     ]}
    """)
    let done = XAIMeetingStreamingProvider.event(from: #"{"type":"transcript.done","channel_index":1}"#)
    let error = XAIMeetingStreamingProvider.event(
      from: #"{"type":"error","error":{"message":"bad audio"}}"#
    )

    #expect(partial == .partial(
      channel: 1,
      text: "Sure, the build",
      words: [
        XAIMeetingWord(text: "Sure,", start: 5.041, end: 5.6, speaker: "1"),
        XAIMeetingWord(text: "the", start: 5.703, end: 5.8, speaker: "2"),
      ],
      isFinal: true
    ))
    #expect(done == .done(channel: 1))
    #expect(error == .error("bad audio"))
  }

  @Test func grokSpeechFinalRepeatsAreKeptOnce() {
    var deduplicator = XAIMeetingWordDeduplicator()
    let first = [
      XAIMeetingWord(text: "Morning,", start: 0.72, end: 1.1, speaker: "1"),
      XAIMeetingWord(text: "everyone.", start: 1.18, end: 1.7, speaker: "1"),
    ]
    let repeated = first + [XAIMeetingWord(text: "Let's", start: 1.79, end: 2, speaker: "1")]

    #expect(deduplicator.newWords(channel: 0, words: first) == first)
    #expect(deduplicator.newWords(channel: 0, words: repeated).map(\.text) == ["Let's"])
    // Channels are independent: the call's words at the same times still count.
    #expect(deduplicator.newWords(channel: 1, words: first) == first)
  }

  @Test func grokWordsBecomeTimelineTokensWithTheMicrophoneUnlabelled() {
    let words = [XAIMeetingWord(text: "Hello", start: 1, end: 1.4, speaker: "2")]

    let microphone = MeetingTranscriptionService.grokTokens(
      words,
      source: .microphone,
      timelineOffset: 95
    )
    let call = MeetingTranscriptionService.grokTokens(words, source: .systemAudio, timelineOffset: 95)

    #expect(microphone.map(\.text) == [" Hello"])
    #expect(microphone.map(\.speaker) == [nil])
    #expect(call.map(\.speaker) == ["2"])
    #expect(call.first?.startTime == 96)
    #expect(MeetingTranscriptionService.grokSource(channel: 0) == .microphone)
    #expect(MeetingTranscriptionService.grokSource(channel: 1) == .systemAudio)
  }

  @Test func grokMeetingStreamAsksForTwoDiarizedChannels() throws {
    let url = try #require(XAIMeetingStreamingProvider.websocketURL(
      keyterms: ["Priya Shah"],
      language: "auto"
    ))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    #expect(url.host == "api.x.ai")
    #expect(value("channels") == "2")
    #expect(value("multichannel") == "true")
    #expect(value("diarize") == "true")
    #expect(value("keyterm") == "Priya Shah")
    #expect(value("language") == nil)
  }

  @Test func sonioxParserSurfacesCurrentErrorSchema() {
    let payload = """
    {
      "error_code":503,
      "error_type":"service_unavailable",
      "error_message":"Please restart the request."
    }
    """

    #expect(SonioxStreamingProvider.serverError(from: payload)
      == "503 service_unavailable: Please restart the request.")
  }

  @Test func sonioxMeetingModeRequiresAConfirmedFinalTranscript() {
    let options = SonioxStreamingProvider.RealtimeOptions.meeting

    #expect(options.waitForFinished)
    #expect(options.finalizationWaitMs >= 15_000)
    #expect(!options.enableSpeakerDiarization)
    #expect(SonioxStreamingProvider.RealtimeOptions.remoteMeeting.enableSpeakerDiarization)
  }

  @Test func sonioxLivePreviewReplacesWithOnlyTheCurrentNonFinalTail() {
    let tokens = [
      SonioxRealtimeToken(
        text: "Final",
        startMs: 0,
        endMs: 100,
        isFinal: true,
        speaker: nil
      ),
      SonioxRealtimeToken(
        text: " changing",
        startMs: 100,
        endMs: 200,
        isFinal: false,
        speaker: nil
      ),
      SonioxRealtimeToken(
        text: " tail",
        startMs: 200,
        endMs: 300,
        isFinal: false,
        speaker: nil
      ),
      SonioxRealtimeToken(
        text: "<fin>",
        startMs: nil,
        endMs: nil,
        isFinal: false,
        speaker: nil
      )
    ]

    #expect(MeetingTranscriptionService.previewText(tokens: tokens) == " changing tail")
    #expect(MeetingTranscriptionService.previewText(tokens: []) == "")
  }

  @Test func automaticMeetingDetectionDefaultsOffAndPreservesExplicitChoice() throws {
    let suiteName = "MeetingFeatureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(!MeetingPreferences.automaticDetectionEnabled(defaults: defaults))
    defaults.set(true, forKey: "meeting.autoDetection.enabled")
    #expect(MeetingPreferences.automaticDetectionEnabled(defaults: defaults))
    defaults.set(false, forKey: "meeting.autoDetection.enabled")
    #expect(!MeetingPreferences.automaticDetectionEnabled(defaults: defaults))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetingFeatureTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @MainActor
  private func loadedCoordinator(
    store: MeetingSessionStore,
    noteGenerator: ((MeetingSession, String, String) async throws -> MeetingGeneratedNotes)? = nil
  ) async throws -> MeetingCoordinator {
    let coordinator: MeetingCoordinator
    if let noteGenerator {
      coordinator = MeetingCoordinator(store: store, noteGenerator: noteGenerator)
    } else {
      coordinator = MeetingCoordinator(store: store)
    }
    for _ in 0..<500 {
      if !coordinator.isLoadingSessions { return coordinator }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!coordinator.isLoadingSessions)
    return coordinator
  }

  @Test func placeholderMeetingTitlesAreReplaceableButUserTitlesArePreserved() {
    // Bare detector name, as used by an automatic start.
    #expect(MeetingCoordinator.isGeneratedTitleReplaceable(
      "Google Meet", detectedApp: "Google Meet"
    ))
    // Dated defaults from defaultTitle(detectedApp:).
    #expect(MeetingCoordinator.isGeneratedTitleReplaceable(
      "Google Meet — Mon, 27 Jul • 5:49 pm", detectedApp: "Google Meet"
    ))
    #expect(MeetingCoordinator.isGeneratedTitleReplaceable(
      "Meeting — Sun, 12 Jul • 10:32 am", detectedApp: nil
    ))
    #expect(MeetingCoordinator.isGeneratedTitleReplaceable("Meeting", detectedApp: nil))
    // A user-chosen title must never be overwritten by a regenerate.
    #expect(!MeetingCoordinator.isGeneratedTitleReplaceable(
      "Core Daily Standup P1 Review", detectedApp: "Google Meet"
    ))
    #expect(!MeetingCoordinator.isGeneratedTitleReplaceable(
      "Meeting with Ash — budget", detectedApp: nil
    ))
  }

  @Test func finalizationTimeoutExpiresInsteadOfHangingForever() async throws {
    // A provider that never returns must not strand finalization.
    await #expect(throws: MeetingFinalizationTimeout.Expired.self) {
      try await MeetingFinalizationTimeout.run(seconds: 0.05) {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      }
    }
    // A provider that completes in time still returns its value.
    let value = try await MeetingFinalizationTimeout.run(seconds: 5) { 42 }
    #expect(value == 42)
  }
}

private actor MeetingRecoveryTranscriptionSpy {
  private var filenames: [String] = []

  func transcribe(_ url: URL) -> String {
    filenames.append(url.lastPathComponent)
    return "Recovered \(url.lastPathComponent)"
  }

  func calls() -> [String] {
    filenames
  }
}

private final class MeetingDiscardFileManager: FileManager, @unchecked Sendable {
  private let beforeRemoval: @Sendable (URL) throws -> Void

  init(beforeRemoval: @escaping @Sendable (URL) throws -> Void) {
    self.beforeRemoval = beforeRemoval
    super.init()
  }

  override func removeItem(at url: URL) throws {
    try beforeRemoval(url)
    try super.removeItem(at: url)
  }
}
