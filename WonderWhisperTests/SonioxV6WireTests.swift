import Foundation
import AVFoundation
import Testing
@testable import WonderWhisper

/// What actually goes to Soniox: the real-time connection request and start message for
/// dictation and both meeting streams, and the async recovery POST bodies.
@Suite(.serialized)
struct SonioxV6WireTests {
  private static let testKey = "test-soniox-key"

  /// Participant names first (one holds a comma), then vocabulary, then the meeting terms.
  private static let participantNames = ["Rivera, Jr.", "Ada Lovelace"]
  private static let customVocabulary = "Kubernetes, ada lovelace"
  private static let spellingCorrections = "kube cuddle -> kubectl"

  private static var expectedMeetingTerms: [String] {
    MeetingTranscriptionService.vocabularyTerms(
      participantNames: participantNames,
      customVocabulary: customVocabulary,
      spellingCorrections: spellingCorrections
    )
  }

  private static func json(_ message: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
    return try #require(object as? [String: Any])
  }

  private static func expectConnection(_ request: URLRequest) {
    #expect(request.url?.absoluteString == "wss://stt-rt.soniox.com/transcribe-websocket")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
  }

  // MARK: - Real-time

  @Test func sonioxModelAliasesMapToV6() {
    for legacy in ["", "  ", "soniox-streaming", "stt-rt-v3", "stt-rt-v4", "stt-rt-v5", "STT-RT-V5"] {
      #expect(SonioxStreamingProvider.apiModel(for: legacy) == "stt-rt-v6", "\(legacy)")
    }
    #expect(SonioxStreamingProvider.apiModel(for: "stt-rt-v6") == "stt-rt-v6")
    #expect(SonioxStreamingProvider.apiModel(for: "stt-rt-preview") == "stt-rt-preview")
  }

  @Test func dictationStartRequestUsesV6AndTheAuthorizationHeader() async throws {
    let provider = SonioxStreamingProvider(
      apiKeyProvider: { Self.testKey },
      vocabularyProvider: { "WonderWhisper, Soniox V6 ,, CORE-759" },
      languageProvider: { " EN " },
      realtimeOptions: .dictation
    )
    await provider.setInputSampleRate(48_000)
    await provider.updateSettings(TranscriptionSettings(
      endpoint: URL(string: "https://localhost")!,
      model: "soniox-streaming"
    ))

    let start = try await provider.startRequest(apiKey: Self.testKey)
    Self.expectConnection(start.request)
    #expect(!start.message.contains(Self.testKey))

    let config = try Self.json(start.message)
    #expect(config["model"] as? String == "stt-rt-v6")
    #expect(config["api_key"] == nil)
    #expect(config["audio_format"] as? String == "pcm_s16le")
    #expect(config["sample_rate"] as? Int == 48_000)
    #expect(config["num_channels"] as? Int == 1)
    #expect(config["language_hints"] as? [String] == ["en"])
    #expect(config["enable_language_identification"] as? Bool == true)
    #expect(config["enable_endpoint_detection"] as? Bool == true)
    #expect(config["max_endpoint_delay_ms"] == nil)
    #expect(config["enable_speaker_diarization"] as? Bool == false)
    let context = try #require(config["context"] as? [String: Any])
    #expect(context["terms"] as? [String] == ["WonderWhisper", "Soniox V6", "CORE-759"])
    #expect(Set(config.keys) == [
      "model", "audio_format", "sample_rate", "num_channels", "language_hints",
      "enable_language_identification", "enable_endpoint_detection",
      "enable_speaker_diarization", "context"
    ])
  }

  @Test func dictationAutoLanguageSendsNoHintAndKeepsIdentification() async throws {
    let provider = SonioxStreamingProvider(
      apiKeyProvider: { Self.testKey },
      languageProvider: { "auto" },
      realtimeOptions: .dictation
    )
    let config = try Self.json(try await provider.startRequest(apiKey: Self.testKey).message)
    #expect(config["language_hints"] == nil)
    #expect(config["enable_language_identification"] as? Bool == true)
    #expect(config["context"] == nil)
    #expect(config["sample_rate"] as? Int == 16_000)
  }

  @Test func meetingStreamsSendV6TheHeaderAndTheSameTermsVerbatim() async throws {
    let terms = Self.expectedMeetingTerms
    #expect(terms.first == "Rivera, Jr.")
    #expect(terms.prefix(2) == ["Rivera, Jr.", "Ada Lovelace"])

    var configs: [MeetingAudioSource: [String: Any]] = [:]
    for source in MeetingAudioSource.captureSources {
      let provider = await MeetingTranscriptionService.sonioxStreamProvider(
        source: source,
        terms: terms,
        apiKeyProvider: { Self.testKey },
        languageProvider: { "en" }
      )
      let start = try await provider.startRequest(apiKey: Self.testKey)
      Self.expectConnection(start.request)
      #expect(!start.message.contains(Self.testKey))
      configs[source] = try Self.json(start.message)
    }

    let microphone = try #require(configs[.microphone])
    let system = try #require(configs[.systemAudio])
    for config in [microphone, system] {
      #expect(config["model"] as? String == "stt-rt-v6")
      #expect(config["api_key"] == nil)
      #expect(config["audio_format"] as? String == "pcm_s16le")
      #expect(config["sample_rate"] as? Int == 16_000)
      #expect(config["num_channels"] as? Int == 1)
      #expect(config["language_hints"] as? [String] == ["en"])
      #expect(config["enable_language_identification"] as? Bool == true)
      #expect(config["enable_endpoint_detection"] as? Bool == true)
      #expect(config["max_endpoint_delay_ms"] as? Int == 1_500)
      let context = try #require(config["context"] as? [String: Any])
      #expect(context["terms"] as? [String] == terms)
    }
    // Only the call side is split into speakers.
    #expect(microphone["enable_speaker_diarization"] as? Bool == false)
    #expect(system["enable_speaker_diarization"] as? Bool == true)
  }

  @Test func meetingRealtimeOptionsAreUnchanged() {
    let microphone = SonioxStreamingProvider.RealtimeOptions.meeting
    let system = SonioxStreamingProvider.RealtimeOptions.remoteMeeting
    let dictation = SonioxStreamingProvider.RealtimeOptions.dictation
    #expect(microphone.waitForFinished && system.waitForFinished)
    #expect(microphone.finalizationWaitMs == 15_000 && system.finalizationWaitMs == 15_000)
    #expect(!dictation.waitForFinished && dictation.finalizationWaitMs == 1_800)
    #expect(dictation.enableEndpointDetection && dictation.maxEndpointDelayMs == nil)
  }

  @Test func onlyExactControlTokensAreFiltered() {
    #expect(SonioxStreamingProvider.isControlToken("<fin>"))
    #expect(SonioxStreamingProvider.isControlToken(" <end> "))
    #expect(!SonioxStreamingProvider.isControlToken("<b>"))
    #expect(!SonioxStreamingProvider.isControlToken("a < b"))
  }

  // MARK: - Async recovery

  @Test func asyncRecoveryPostsV6BodiesWithTheSharedTermsSnapshot() async throws {
    let stub = SonioxAsyncStub()
    SonioxAsyncStubProtocol.install(stub)
    defer { SonioxAsyncStubProtocol.install(nil) }
    let directory = try Self.makeRetainedAudio()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The vocabulary is read once per recovery; a later change must not reach either body.
    let vocabularyReads = Counter()
    let service = MeetingSonioxAsyncRecoveryService(
      apiKeyProvider: { Self.testKey },
      vocabularyProvider: {
        let read = vocabularyReads.increment()
        return .init(
          customVocabulary: read == 1 ? Self.customVocabulary : "Changed Midway",
          spellingCorrections: Self.spellingCorrections
        )
      },
      languageProvider: { "en" },
      session: SonioxAsyncStubProtocol.session()
    )

    let tokens = try await service.recover(
      sessionDirectory: directory,
      audioFilenames: ["microphone-0001.caf", "system-0001.caf"],
      participantNames: Self.participantNames
    )

    #expect(vocabularyReads.value == 1)
    // Each transcript echoes its file id, so each body can be tied to its source.
    let fileBySource = Dictionary(
      tokens.map { ($0.source, $0.text) },
      uniquingKeysWith: { first, _ in first }
    )
    let microphoneFile = try #require(fileBySource[.microphone])
    let systemFile = try #require(fileBySource[.systemAudio])
    #expect(microphoneFile != systemFile)
    let bodies = stub.createBodies
    #expect(bodies.count == 2)
    let microphoneBody = try Self.json(String(decoding: try #require(bodies[microphoneFile]), as: UTF8.self))
    let systemBody = try Self.json(String(decoding: try #require(bodies[systemFile]), as: UTF8.self))

    for body in [microphoneBody, systemBody] {
      #expect(body["model"] as? String == "stt-async-v6")
      #expect(body["language_hints"] as? [String] == ["en"])
      let context = try #require(body["context"] as? [String: Any])
      #expect(context["terms"] as? [String] == Self.expectedMeetingTerms)
      #expect((context["terms"] as? [String])?.first == "Rivera, Jr.")
      #expect(Set(body.keys) == [
        "model", "file_id", "language_hints", "enable_speaker_diarization", "context"
      ])
    }
    #expect(microphoneBody["file_id"] as? String == microphoneFile)
    #expect(systemBody["file_id"] as? String == systemFile)
    #expect(microphoneBody["enable_speaker_diarization"] as? Bool == false)
    #expect(systemBody["enable_speaker_diarization"] as? Bool == true)
    #expect(tokens.first { $0.source == .systemAudio }?.speaker == "1")
    #expect(tokens.first { $0.source == .microphone }?.speaker == nil)

    // Every request carried the key in the header, and both sides were cleaned up.
    #expect(stub.authorizations.allSatisfy { $0 == "Bearer \(Self.testKey)" })
    #expect(!stub.authorizations.isEmpty)
    let deletes = Set(stub.deletedPaths)
    #expect(deletes.isSuperset(of: [
      "files/\(microphoneFile)", "files/\(systemFile)",
      "transcriptions/tr-\(microphoneFile)", "transcriptions/tr-\(systemFile)"
    ]))
  }

  @Test func asyncRecoveryWithoutTermsOmitsContextAndAutoLanguageOmitsHints() async throws {
    let stub = SonioxAsyncStub()
    SonioxAsyncStubProtocol.install(stub)
    defer { SonioxAsyncStubProtocol.install(nil) }
    let directory = try Self.makeRetainedAudio()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = MeetingSonioxAsyncRecoveryService(
      apiKeyProvider: { Self.testKey },
      vocabularyProvider: { .init(customVocabulary: "", spellingCorrections: "") },
      languageProvider: { "auto" },
      session: SonioxAsyncStubProtocol.session()
    )
    _ = try await service.recover(
      sessionDirectory: directory,
      audioFilenames: ["microphone-0001.caf", "system-0001.caf"]
    )
    let bodies = stub.createBodies.values.map { String(decoding: $0, as: UTF8.self) }
    #expect(bodies.count == 2)
    for body in bodies {
      let json = try Self.json(body)
      #expect(json["model"] as? String == "stt-async-v6")
      #expect(json["language_hints"] == nil)
      // The fixed meeting terms are always present.
      let context = try #require(json["context"] as? [String: Any])
      #expect(context["terms"] as? [String] == MeetingTranscriptionService.meetingTerms)
    }
  }

  @Test func asyncRecoveryFailureThrowsAndStillDeletesUploadedFiles() async throws {
    let stub = SonioxAsyncStub(failCreate: true)
    SonioxAsyncStubProtocol.install(stub)
    defer { SonioxAsyncStubProtocol.install(nil) }
    let directory = try Self.makeRetainedAudio()
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = MeetingSonioxAsyncRecoveryService(
      apiKeyProvider: { Self.testKey },
      vocabularyProvider: { .init(customVocabulary: "", spellingCorrections: "") },
      languageProvider: { "en" },
      session: SonioxAsyncStubProtocol.session()
    )
    await #expect(throws: MeetingSonioxAsyncRecoveryService.RecoveryError.self) {
      _ = try await service.recover(
        sessionDirectory: directory,
        audioFilenames: ["microphone-0001.caf", "system-0001.caf"],
        participantNames: Self.participantNames
      )
    }
    // Cleanup of a cancelled sibling retries off the request path; give it a moment.
    for _ in 0..<40 where !Set(stub.deletedPaths).isSuperset(of: stub.uploadedFiles.map { "files/\($0)" }) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(!stub.uploadedFiles.isEmpty)
    #expect(Set(stub.deletedPaths).isSuperset(of: stub.uploadedFiles.map { "files/\($0)" }))
  }

  // MARK: - Recovery fallback

  @MainActor @Test func sonioxAsyncRecoveryIsTriedFirstForAFullSonioxRecovery() async throws {
    var localCalls = 0
    let token = MeetingTranscriptToken(
      source: .systemAudio, startTime: 0, endTime: 1, text: " remote", speaker: "1"
    )
    let result = try await MeetingCoordinator.recoverRetainedTranscript(
      usesSoniox: true,
      fullRecoverySources: MeetingAudioSource.captureSources,
      remote: { [token] },
      local: { localCalls += 1; return ([], []) }
    )
    #expect(localCalls == 0)
    #expect(result.tokens == [token])
    #expect(result.sources == MeetingAudioSource.captureSources)
    #expect(result.method == "with Soniox async diarization")
    #expect(result.asyncFallbackWarning == nil)
  }

  @MainActor @Test func failedSonioxAsyncRecoveryFallsBackToLocalRecovery() async throws {
    let local = MeetingTranscriptToken(
      source: .microphone, startTime: 0, endTime: 1, text: " local", speaker: nil
    )
    let result = try await MeetingCoordinator.recoverRetainedTranscript(
      usesSoniox: true,
      fullRecoverySources: MeetingAudioSource.captureSources,
      remote: { throw MeetingSonioxAsyncRecoveryService.RecoveryError.http(500, "down") },
      local: { ([local], MeetingAudioSource.captureSources) }
    )
    #expect(result.tokens == [local])
    #expect(result.method == "locally")
    #expect(result.asyncFallbackWarning?.hasPrefix(
      "Soniox async diarization failed; local recovery was used: "
    ) == true)
  }

  @MainActor @Test func partialOrNonSonioxRecoveryStaysLocal() async throws {
    var remoteCalls = 0
    for (usesSoniox, sources) in [
      (true, Set([MeetingAudioSource.microphone])),
      (false, MeetingAudioSource.captureSources)
    ] {
      let result = try await MeetingCoordinator.recoverRetainedTranscript(
        usesSoniox: usesSoniox,
        fullRecoverySources: sources,
        remote: { remoteCalls += 1; return [] },
        local: { ([], sources) }
      )
      #expect(result.method == "locally")
      #expect(result.asyncFallbackWarning == nil)
    }
    #expect(remoteCalls == 0)
  }

  // MARK: - Fixtures

  /// One short 16 kHz mono segment per capture source, like a retained meeting.
  private static func makeRetainedAudio() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SonioxV6WireTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = try #require(AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    ))
    for name in ["microphone-0001.caf", "system-0001.caf"] {
      let file = try AVAudioFile(
        forWriting: directory.appendingPathComponent(name),
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
      buffer.frameLength = 1_600
      if let channel = buffer.floatChannelData?.pointee {
        for index in 0..<1_600 { channel[index] = 0.1 * sin(Float(index) * 0.05) }
      }
      try file.write(from: buffer)
    }
    return directory
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() -> Int { lock.withLock { count += 1; return count } }
}

/// A fake Soniox async API: files, transcriptions, status, transcript and deletes.
final class SonioxAsyncStub: @unchecked Sendable {
  private let lock = NSLock()
  private let failCreate: Bool
  private var nextFile = 0
  private var bodies: [String: Data] = [:]
  private var files: [String] = []
  private var deletes: [String] = []
  private var auth: [String] = []

  init(failCreate: Bool = false) { self.failCreate = failCreate }

  var createBodies: [String: Data] { lock.withLock { bodies } }
  var uploadedFiles: [String] { lock.withLock { files } }
  var deletedPaths: [String] { lock.withLock { deletes } }
  var authorizations: [String] { lock.withLock { auth } }

  func respond(to request: URLRequest, body: Data?) -> (Int, Data) {
    let path = request.url?.path.replacingOccurrences(of: "/v1/", with: "") ?? ""
    let method = request.httpMethod ?? "GET"
    return lock.withLock {
      auth.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
      switch (method, path) {
      case ("POST", "files"):
        nextFile += 1
        let id = "file-\(nextFile)"
        files.append(id)
        return (200, Data(#"{"id":"\#(id)"}"#.utf8))
      case ("POST", "transcriptions"):
        if failCreate { return (500, Data(#"{"message":"create failed"}"#.utf8)) }
        let body = body ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let fileID = json?["file_id"] as? String ?? "unknown"
        bodies[fileID] = body
        return (200, Data(#"{"id":"tr-\#(fileID)"}"#.utf8))
      case ("DELETE", _):
        deletes.append(path)
        return (200, Data("{}".utf8))
      default:
        if path.hasSuffix("/transcript") {
          let fileID = path
            .replacingOccurrences(of: "transcriptions/tr-", with: "")
            .replacingOccurrences(of: "/transcript", with: "")
          return (200, Data(#"""
          {"tokens":[{"text":"\#(fileID)","start_ms":0,"end_ms":100,"speaker":"1"}]}
          """#.utf8))
        }
        if path.hasPrefix("transcriptions/") {
          return (200, Data(#"{"status":"completed"}"#.utf8))
        }
        return (404, Data(#"{"message":"not found"}"#.utf8))
      }
    }
  }
}

final class SonioxAsyncStubProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var stub: SonioxAsyncStub?

  static func install(_ stub: SonioxAsyncStub?) { lock.withLock { self.stub = stub } }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SonioxAsyncStubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let stub = Self.lock.withLock({ Self.stub }), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let (status, data) = stub.respond(to: request, body: Self.body(of: request))
    let response = HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )
    if let response {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func body(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
