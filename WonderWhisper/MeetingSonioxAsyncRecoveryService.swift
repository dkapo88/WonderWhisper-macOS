import AVFoundation
import Foundation

actor MeetingSonioxAsyncRecoveryService {
  enum RecoveryError: LocalizedError {
    case failed(String)
    case http(Int, String)

    var errorDescription: String? {
      switch self {
      case .failed(let message): return message
      case .http(let status, let message): return "Soniox HTTP \(status): \(message)"
      }
    }
  }

  private struct RawSegment: Sendable {
    let filename: String
    let source: MeetingAudioSource
    let index: Int
  }

  private struct IdentifierResponse: Decodable {
    let id: String
  }

  private struct StatusResponse: Decodable {
    let status: String
    let errorType: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
      case status
      case errorType = "error_type"
      case errorMessage = "error_message"
    }
  }

  private struct TranscriptResponse: Decodable {
    let tokens: [TranscriptToken]
  }

  private struct TranscriptToken: Decodable {
    let text: String
    let startMs: Int?
    let endMs: Int?
    let speaker: String?

    enum CodingKeys: String, CodingKey {
      case text
      case startMs = "start_ms"
      case endMs = "end_ms"
      case speaker
    }
  }

  private struct CreateRequest: Encodable {
    let model = "stt-async-v5"
    let fileID: String
    let languageHints: [String]?
    let enableSpeakerDiarization: Bool

    enum CodingKeys: String, CodingKey {
      case model
      case fileID = "file_id"
      case languageHints = "language_hints"
      case enableSpeakerDiarization = "enable_speaker_diarization"
    }
  }

  private let apiKeyProvider: @Sendable () -> String?
  private let session: URLSession

  init(
    apiKeyProvider: @escaping @Sendable () -> String? = {
      KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias)
    },
    session: URLSession? = nil
  ) {
    self.apiKeyProvider = apiKeyProvider
    if let session {
      self.session = session
    } else {
      let configuration = NetworkConfiguration.createConfiguration(
        timeout: 300,
        maxConnections: 2
      )
      configuration.timeoutIntervalForResource = 3_600
      self.session = URLSession(configuration: configuration)
    }
  }

  func recover(
    sessionDirectory: URL,
    audioFilenames: [String]
  ) async throws -> [MeetingTranscriptToken] {
    guard let rawKey = apiKeyProvider() else {
      throw RecoveryError.failed("A Soniox API key is required for async recovery.")
    }
    let apiKey = KeychainService.normalizedSecret(rawKey)
    guard !apiKey.isEmpty else {
      throw RecoveryError.failed("A Soniox API key is required for async recovery.")
    }

    let segments = try Self.orderedSegments(audioFilenames: audioFilenames)
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("WonderWhisper-Soniox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    async let microphoneTokens = recover(
      source: .microphone,
      segments: segments[.microphone] ?? [],
      sessionDirectory: sessionDirectory,
      temporaryDirectory: temporaryDirectory,
      apiKey: apiKey
    )
    async let systemTokens = recover(
      source: .systemAudio,
      segments: segments[.systemAudio] ?? [],
      sessionDirectory: sessionDirectory,
      temporaryDirectory: temporaryDirectory,
      apiKey: apiKey
    )
    let (microphone, system) = try await (microphoneTokens, systemTokens)
    return MeetingTranscriptFormatter.chronologicalTokens(microphone + system)
  }

  nonisolated static func orderedSegmentFilenames(
    audioFilenames: [String]
  ) throws -> [MeetingAudioSource: [String]] {
    Dictionary(
      uniqueKeysWithValues: try orderedSegments(audioFilenames: audioFilenames).map {
        ($0.key, $0.value.map(\.filename))
      }
    )
  }

  nonisolated static func transcriptTokens(
    from data: Data,
    source: MeetingAudioSource
  ) throws -> [MeetingTranscriptToken] {
    let response = try JSONDecoder().decode(TranscriptResponse.self, from: data)
    var previousEnd: TimeInterval = 0
    return response.tokens.compactMap { token in
      guard !token.text.isEmpty,
            !SonioxStreamingProvider.isControlToken(token.text) else { return nil }
      let start = token.startMs.map { Double($0) / 1_000 } ?? previousEnd
      let end = max(start, token.endMs.map { Double($0) / 1_000 } ?? start)
      previousEnd = end
      return MeetingTranscriptToken(
        source: source,
        startTime: start,
        endTime: end,
        text: token.text,
        speaker: source == .systemAudio ? token.speaker : nil
      )
    }
  }

  private func recover(
    source: MeetingAudioSource,
    segments: [RawSegment],
    sessionDirectory: URL,
    temporaryDirectory: URL,
    apiKey: String
  ) async throws -> [MeetingTranscriptToken] {
    let wavURL = temporaryDirectory.appendingPathComponent("\(source.filenamePrefix).wav")
    let multipartURL = temporaryDirectory
      .appendingPathComponent("\(source.filenamePrefix).multipart")
    var fileID: String?
    var transcriptionID: String?

    do {
      try concatenate(
        segments: segments,
        sessionDirectory: sessionDirectory,
        outputURL: wavURL
      )
      let boundary = "WonderWhisper-\(UUID().uuidString)"
      try makeMultipartBody(
        audioURL: wavURL,
        outputURL: multipartURL,
        boundary: boundary
      )
      fileID = try await upload(
        bodyURL: multipartURL,
        boundary: boundary,
        apiKey: apiKey
      )
      transcriptionID = try await createTranscription(
        fileID: fileID ?? "",
        diarize: source == .systemAudio,
        apiKey: apiKey
      )
      try await waitUntilComplete(transcriptionID: transcriptionID ?? "", apiKey: apiKey)
      let data = try await request(
        method: "GET",
        path: "transcriptions/\(transcriptionID ?? "")/transcript",
        apiKey: apiKey
      )
      let tokens = try Self.transcriptTokens(from: data, source: source)
      await cleanup(fileID: fileID, transcriptionID: transcriptionID, apiKey: apiKey)
      return tokens
    } catch {
      await cleanup(fileID: fileID, transcriptionID: transcriptionID, apiKey: apiKey)
      throw error
    }
  }

  private nonisolated static func orderedSegments(
    audioFilenames: [String]
  ) throws -> [MeetingAudioSource: [RawSegment]] {
    let parsed = audioFilenames.compactMap { filename -> RawSegment? in
      guard let segment = MeetingTranscriptRecoveryService.segment(
        filename: filename,
        duration: 1
      ), MeetingAudioSource.captureSources.contains(segment.source) else { return nil }
      return RawSegment(
        filename: segment.filename,
        source: segment.source,
        index: segment.index
      )
    }
    var result: [MeetingAudioSource: [RawSegment]] = [:]
    for source in MeetingAudioSource.captureSources {
      let segments = parsed.filter { $0.source == source }.sorted { $0.index < $1.index }
      guard !segments.isEmpty else {
        throw RecoveryError.failed("Retained \(source.displayName.lowercased()) audio is missing.")
      }
      let expectedIndexes = Array(1...segments.count)
      guard segments.map(\.index) == expectedIndexes else {
        throw RecoveryError.failed(
          "Retained \(source.displayName.lowercased()) audio has missing or duplicate segments."
        )
      }
      result[source] = segments
    }
    return result
  }

  private func concatenate(
    segments: [RawSegment],
    sessionDirectory: URL,
    outputURL: URL
  ) throws {
    guard let processingFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ) else {
      throw RecoveryError.failed("Could not create the Soniox recovery audio format.")
    }
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )

    for segment in segments {
      let inputURL = sessionDirectory.appendingPathComponent(segment.filename)
      let input = try AVAudioFile(
        forReading: inputURL,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      guard input.processingFormat.sampleRate == processingFormat.sampleRate,
            input.processingFormat.channelCount == processingFormat.channelCount else {
        throw RecoveryError.failed("Meeting audio format changed during async recovery.")
      }
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: 16_000
      ) else {
        throw RecoveryError.failed("Could not allocate a Soniox recovery audio buffer.")
      }
      while input.framePosition < input.length {
        let remaining = min(16_000, input.length - input.framePosition)
        try input.read(into: buffer, frameCount: AVAudioFrameCount(remaining))
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
      }
    }
  }

  private func makeMultipartBody(
    audioURL: URL,
    outputURL: URL,
    boundary: String
  ) throws {
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw RecoveryError.failed("Could not create the Soniox upload body.")
    }
    let output = try FileHandle(forWritingTo: outputURL)
    let input = try FileHandle(forReadingFrom: audioURL)
    defer {
      try? input.close()
      try? output.close()
    }
    let header = "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"file\"; "
        + "filename=\"\(audioURL.lastPathComponent)\"\r\n"
        + "Content-Type: audio/wav\r\n\r\n"
    try output.write(contentsOf: Data(header.utf8))
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
      try output.write(contentsOf: chunk)
    }
    try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
  }

  private func upload(
    bodyURL: URL,
    boundary: String,
    apiKey: String
  ) async throws -> String {
    var request = try authorizedRequest(method: "POST", path: "files", apiKey: apiKey)
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
    try validate(response: response, data: data)
    return try JSONDecoder().decode(IdentifierResponse.self, from: data).id
  }

  private func createTranscription(
    fileID: String,
    diarize: Bool,
    apiKey: String
  ) async throws -> String {
    var request = try authorizedRequest(
      method: "POST",
      path: "transcriptions",
      apiKey: apiKey
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(CreateRequest(
      fileID: fileID,
      languageHints: Self.languageHint().map { [$0] },
      enableSpeakerDiarization: diarize
    ))
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    return try JSONDecoder().decode(IdentifierResponse.self, from: data).id
  }

  private func waitUntilComplete(transcriptionID: String, apiKey: String) async throws {
    var lastPollingError: Error?
    for _ in 0..<900 {
      let status: StatusResponse
      do {
        let data = try await request(
          method: "GET",
          path: "transcriptions/\(transcriptionID)",
          apiKey: apiKey
        )
        status = try JSONDecoder().decode(StatusResponse.self, from: data)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        if let recoveryError = error as? RecoveryError,
           case .http(let status, _) = recoveryError,
           status != 429,
           !(500...599).contains(status) {
          throw recoveryError
        }
        lastPollingError = error
        try await Task.sleep(nanoseconds: 2_000_000_000)
        continue
      }
      switch status.status.lowercased() {
      case "completed": return
      case "error", "failed":
        throw RecoveryError.failed(
          status.errorMessage ?? status.errorType ?? "Soniox async transcription failed."
        )
      default:
        try await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
    if let lastPollingError {
      throw RecoveryError.failed(
        "Soniox async status remained unavailable: \(lastPollingError.localizedDescription)"
      )
    }
    throw RecoveryError.failed("Soniox async transcription did not finish within 30 minutes.")
  }

  private func cleanup(
    fileID: String?,
    transcriptionID: String?,
    apiKey: String
  ) async {
    let deleted = await deleteResources(
      fileID: fileID,
      transcriptionID: transcriptionID,
      apiKey: apiKey
    )
    guard !deleted else { return }
    Task { [weak self] in
      await self?.retryCleanup(
        fileID: fileID,
        transcriptionID: transcriptionID,
        apiKey: apiKey
      )
    }
  }

  private func retryCleanup(
    fileID: String?,
    transcriptionID: String?,
    apiKey: String
  ) async {
    for _ in 0..<360 {
      if await transcriptionIsTerminal(transcriptionID, apiKey: apiKey),
         await deleteResources(
           fileID: fileID,
           transcriptionID: transcriptionID,
           apiKey: apiKey
         ) {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
    AppLog.dictation.error("MeetingTranscriptRecovery: Soniox cleanup did not complete")
  }

  private func transcriptionIsTerminal(_ id: String?, apiKey: String) async -> Bool {
    guard let id else { return true }
    do {
      let data = try await request(
        method: "GET",
        path: "transcriptions/\(id)",
        apiKey: apiKey
      )
      let status = try JSONDecoder().decode(StatusResponse.self, from: data)
      return ["completed", "error", "failed"].contains(status.status.lowercased())
    } catch RecoveryError.http(let status, _) where status == 404 {
      return true
    } catch {
      return false
    }
  }

  private func deleteResources(
    fileID: String?,
    transcriptionID: String?,
    apiKey: String
  ) async -> Bool {
    if let transcriptionID {
      let deleted = await delete(
        path: "transcriptions/\(transcriptionID)",
        apiKey: apiKey
      )
      if !deleted { return false }
    }
    guard let fileID else { return true }
    return await delete(path: "files/\(fileID)", apiKey: apiKey)
  }

  private func delete(path: String, apiKey: String) async -> Bool {
    do {
      _ = try await request(method: "DELETE", path: path, apiKey: apiKey)
      return true
    } catch RecoveryError.http(let status, _) where status == 404 {
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  private func request(method: String, path: String, apiKey: String) async throws -> Data {
    let request = try authorizedRequest(method: method, path: path, apiKey: apiKey)
    let (data, response) = try await session.data(for: request)
    try validate(response: response, data: data)
    return data
  }

  private func authorizedRequest(
    method: String,
    path: String,
    apiKey: String
  ) throws -> URLRequest {
    guard let url = URL(string: "https://api.soniox.com/v1/\(path)") else {
      throw RecoveryError.failed("Could not create the Soniox API URL.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw RecoveryError.failed("Soniox returned no HTTP response.")
    }
    guard (200...299).contains(http.statusCode) else {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        .flatMap { ($0["message"] ?? $0["error_message"]) as? String }
        ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      throw RecoveryError.http(http.statusCode, message)
    }
  }

  private nonisolated static func languageHint() -> String? {
    let value = UserDefaults.standard.string(forKey: "transcription.language")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return value.isEmpty || value == "auto" ? nil : value
  }
}
