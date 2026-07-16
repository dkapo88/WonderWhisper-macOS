import Foundation
import AVFoundation
import Testing
@testable import WonderWhisper

struct MeetingFeatureTests {
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

  @Test func singleStreamMixerAlignsBothSourcesIntoOneTimeline() {
    let mixer = MeetingSingleStreamMixer()
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

    #expect(mixer.ingest(system).isEmpty)
    let mixed = mixer.ingest(microphone)

    #expect(mixed.count == 2)
    #expect(mixed.allSatisfy { $0.source == .mixed })
    #expect(mixed[0].startTime == 0)
    #expect(mixed[1].startTime == 0.1)
    #expect(mixed.allSatisfy { $0.samples.count == 1_600 })
  }

  @Test func singleStreamMixerWaitsForBothSourcesInsteadOfDiscardingOne() {
    let mixer = MeetingSingleStreamMixer()
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

    #expect(mixer.ingest(microphoneStart).isEmpty)
    #expect(mixer.ingest(systemAhead).count == 1)
    #expect(!mixer.hasDiscardedLateAudio)
    #expect(mixer.ingest(delayedMicrophone).count == 3)
    #expect(!mixer.hasDiscardedLateAudio)
  }

  @Test func singleStreamMixerBoundsAStalledSourceAndRequiresRecovery() {
    let mixer = MeetingSingleStreamMixer()
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

    #expect(mixer.ingest(microphone).isEmpty)
    #expect(mixer.ingest(system).count == 10)
    #expect(mixer.hasDiscardedLateAudio)
  }

  @Test func adaptiveEchoCancellerReducesDelayedReferenceEnergy() {
    var randomState: UInt32 = 0x1234ABCD
    let reference = (0..<12_000).map { _ -> Float in
      randomState = randomState &* 1_664_525 &+ 1_013_904_223
      return (Float(randomState % 20_001) / 10_000 - 1) * 0.25
    }
    let delay = 240
    let microphone = reference.indices.map { index in
      index >= delay ? reference[index - delay] * 0.55 : 0
    }
    let canceller = MeetingAdaptiveEchoCanceller()
    var residual: [Float] = []
    for start in stride(from: 0, to: reference.count, by: 160) {
      let end = min(reference.count, start + 160)
      residual.append(contentsOf: canceller.process(
        reference: Array(reference[start..<end]),
        microphone: Array(microphone[start..<end])
      ))
    }
    let comparisonRange = 8_000..<12_000
    let originalRMS = rms(Array(microphone[comparisonRange]))
    let residualRMS = rms(Array(residual[comparisonRange]))

    #expect(residualRMS < originalRMS * 0.3)
  }

  @Test func adaptiveEchoCancellerPreservesIndependentNearEndSpeech() {
    var referenceState: UInt32 = 0xC001D00D
    var nearEndState: UInt32 = 0xFACEB00C
    let reference = (0..<12_000).map { _ -> Float in
      referenceState = referenceState &* 1_664_525 &+ 1_013_904_223
      return (Float(referenceState % 20_001) / 10_000 - 1) * 0.25
    }
    let nearEnd = (0..<12_000).map { index -> Float in
      nearEndState = nearEndState &* 22_695_477 &+ 1
      guard index >= 7_000 else { return 0 }
      return (Float(nearEndState % 20_001) / 10_000 - 1) * 0.12
    }
    let delay = 240
    let microphone = reference.indices.map { index in
      let echo = index >= delay ? reference[index - delay] * 0.55 : 0
      return echo + nearEnd[index]
    }
    let canceller = MeetingAdaptiveEchoCanceller()
    var residual: [Float] = []
    for start in stride(from: 0, to: reference.count, by: 160) {
      let end = min(reference.count, start + 160)
      residual.append(contentsOf: canceller.process(
        reference: Array(reference[start..<end]),
        microphone: Array(microphone[start..<end])
      ))
    }
    let comparisonRange = 8_000..<12_000
    let expected = Array(nearEnd[comparisonRange])
    let difference = zip(residual[comparisonRange], expected).map { $0 - $1 }

    #expect(rms(difference) < rms(expected) * 0.4)
    #expect(rms(Array(residual[comparisonRange])) > rms(expected) * 0.7)
  }

  @Test func adaptiveEchoCancellerSustainsTenMinutesFasterThanRealtime() {
    let reference = (0..<1_600).map { index in
      Float((index % 97) - 48) / 240
    }
    let microphone = reference.map { $0 * 0.45 }
    let canceller = MeetingAdaptiveEchoCanceller()
    let startedAt = Date()

    for _ in 0..<6_000 {
      _ = canceller.process(reference: reference, microphone: microphone)
    }

    let processingTime = Date().timeIntervalSince(startedAt)
    #expect(processingTime < 30)
  }

  @Test func adaptiveEchoCancellerRejectsNonFiniteAudioWithoutPoisoningState() {
    let canceller = MeetingAdaptiveEchoCanceller(filterLength: 16)
    let contaminated = canceller.process(
      reference: [0.2, .nan, .infinity, -0.1],
      microphone: [0.1, 0.2, -.infinity, .nan]
    )
    let clean = canceller.process(
      reference: [0.1, 0.2, 0.3, 0.4],
      microphone: [0.05, 0.1, 0.15, 0.2]
    )

    #expect(contaminated.allSatisfy { $0.isFinite })
    #expect(clean.allSatisfy { $0.isFinite })
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

    #expect(origin.x == 920)
    #expect(origin.y == 368)
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
    #expect(MeetingTranscriptFormatter.markdown(tokens: tokens).contains(
      "**Microphone [00:00]:**"
    ))
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
    #expect(document.contains("**Microphone [00:03]:** Ship it."))
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
    #expect(MeetingDetectionPolicy.maximumConfirmationDelay <= 4)
    #expect(MeetingDetectionPolicy.eventConfirmationDelay == 1)
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

  @Test func meetingDetectorSnapshotExpiresBeforeTheNextStartPoll() {
    #expect(MeetingDetector.audioProcessSnapshotCacheDuration > 0)
    #expect(
      MeetingDetector.audioProcessSnapshotCacheDuration
        < MeetingDetectionPolicy.eventConfirmationDelay
    )
  }

  @Test func meetingTranscriptionEngineDefaultsLocalAndPersistsSonioxOptIn() throws {
    let suiteName = "MeetingFeatureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .parakeet)
    defaults.set("soniox", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .soniox)
    defaults.set("soniox-separate", forKey: "meeting.transcription.engine")
    #expect(MeetingTranscriptionEngine.selected(defaults: defaults) == .sonioxSeparate)
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
    #expect(SonioxStreamingProvider.RealtimeOptions.mixedMeeting.enableSpeakerDiarization)
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

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
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
