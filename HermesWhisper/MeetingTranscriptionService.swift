import Foundation
import AVFoundation
import FluidAudio

actor MeetingTranscriptionService {
  typealias TokenHandler = @Sendable ([MeetingTranscriptToken]) async -> Void
  typealias PreviewHandler = @Sendable (MeetingAudioSource, String) async -> Void

  private static let maximumPendingChunks = 6_000

  private let engine: MeetingTranscriptionEngine
  private let tokenHandler: TokenHandler
  private let previewHandler: PreviewHandler
  private var systemManager: StreamingUnifiedAsrManager?
  private var microphoneManager: StreamingUnifiedAsrManager?
  private var sonioxProviders: [MeetingAudioSource: SonioxStreamingProvider] = [:]
  private var sourceOffsets: [MeetingAudioSource: TimeInterval] = [:]
  private var sonioxEndTimes: [MeetingAudioSource: TimeInterval] = [:]
  private var pendingChunks: [MeetingAudioChunk] = []
  private var preparationFailure: String?
  private var sonioxFailures: [MeetingAudioSource: String] = [:]
  private var recoverySources: Set<MeetingAudioSource> = []
  private var fullRecoverySources: Set<MeetingAudioSource> = []
  private var isReady = false
  private var isFinishing = false

  init(
    engine: MeetingTranscriptionEngine = .parakeet,
    tokenHandler: @escaping TokenHandler,
    previewHandler: @escaping PreviewHandler = { _, _ in }
  ) {
    self.engine = engine
    self.tokenHandler = tokenHandler
    self.previewHandler = previewHandler
  }

  func prepare() async throws {
    guard !isReady else { return }
    do {
      switch engine {
      case .parakeet:
        try await prepareParakeet()
      case .soniox:
        try await prepareSoniox()
      }
      isReady = true
    } catch {
      preparationFailure = error.localizedDescription
      recoverySources.formUnion(MeetingAudioSource.allCases)
      fullRecoverySources.formUnion(MeetingAudioSource.allCases)
      pendingChunks.removeAll()
      throw error
    }
  }

  func ingest(_ chunk: MeetingAudioChunk) async throws {
    guard !isFinishing else { return }
    if let preparationFailure {
      throw ProviderError.networkError(preparationFailure)
    }
    if let sonioxFailure = sonioxFailures[chunk.source] {
      throw ProviderError.networkError(
        "\(chunk.source.displayName): \(sonioxFailure)"
      )
    }
    guard isReady else {
      if pendingChunks.count >= Self.maximumPendingChunks {
        recoverySources.formUnion(MeetingAudioSource.allCases)
        fullRecoverySources.formUnion(MeetingAudioSource.allCases)
        pendingChunks.removeFirst(min(500, pendingChunks.count))
        pendingChunks.append(chunk)
        throw ProviderError.networkError(
          "Transcription startup fell behind; earliest queued audio will require recovery from CAF."
        )
      }
      pendingChunks.append(chunk)
      return
    }
    do {
      try await drainPendingChunks()
      try await process(chunk)
    } catch {
      recoverySources.insert(chunk.source)
      fullRecoverySources.insert(chunk.source)
      throw error
    }
  }

  func finish() async throws {
    isFinishing = true
    guard isReady else { return }
    try await drainPendingChunks()

    switch engine {
    case .parakeet:
      try await finishParakeet()
    case .soniox:
      try await finishSoniox()
    }
  }

  func cleanup() async {
    if let systemManager { await systemManager.cleanup() }
    if let microphoneManager { await microphoneManager.cleanup() }
    for provider in sonioxProviders.values {
      await provider.abort()
    }
    systemManager = nil
    microphoneManager = nil
    sonioxProviders.removeAll()
    pendingChunks.removeAll()
    sourceOffsets.removeAll()
    sonioxEndTimes.removeAll()
    preparationFailure = nil
    sonioxFailures.removeAll()
    recoverySources.removeAll()
    fullRecoverySources.removeAll()
    isReady = false
    isFinishing = false
  }

  private func prepareParakeet() async throws {
    let system = StreamingUnifiedAsrManager()
    let microphone = StreamingUnifiedAsrManager()
    systemManager = system
    microphoneManager = microphone

    // Loading sequentially avoids two managers racing the same model download.
    try await system.loadModels(to: ParakeetManager.modelsDirectory)
    try await microphone.loadModels(to: ParakeetManager.modelsDirectory)
    AppLog.dictation.log("MeetingTranscription: two Parakeet Unified streams ready")
  }

  private func prepareSoniox() async throws {
    let system = await makeSonioxProvider(source: .systemAudio)
    let microphone = await makeSonioxProvider(source: .microphone)
    sonioxProviders = [
      .systemAudio: system,
      .microphone: microphone
    ]

    do {
      async let systemStart: Void = system.beginRealtime()
      async let microphoneStart: Void = microphone.beginRealtime()
      _ = try await (systemStart, microphoneStart)
      AppLog.dictation.log("MeetingTranscription: two Soniox V5 streams accepting audio")
    } catch {
      await system.abort()
      await microphone.abort()
      sonioxProviders.removeAll()
      throw error
    }
  }

  private func makeSonioxProvider(
    source: MeetingAudioSource
  ) async -> SonioxStreamingProvider {
    let provider = SonioxStreamingProvider(
      apiKeyProvider: {
        KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias)
      },
      vocabularyProvider: {
        let custom = UserDefaults.standard.string(forKey: "vocab.custom") ?? ""
        let spelling = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        var terms = VoiceVocabularyKeyterms.terms(
          customVocabulary: custom,
          spellingCorrections: spelling
        )
        terms.append(contentsOf: [
          "Hapana", "CORE", "OC", "BC", "INT", "Jira", "Linear", "Obsidian"
        ])
        return terms.joined(separator: ", ")
      },
      languageProvider: {
        UserDefaults.standard.string(forKey: "transcription.language") ?? "en"
      },
      realtimeOptions: .meeting
    )

    await provider.setInputSampleRate(16_000)
    await provider.setOnFinalTokens { [weak self] tokens in
      await self?.emitSoniox(tokens, source: source)
    }
    await provider.setOnNonFinalTokens { [weak self] tokens in
      await self?.emitSonioxPreview(tokens, source: source)
    }
    await provider.setOnStreamError { [weak self] message in
      await self?.recordSonioxFailure(message, source: source)
    }
    return provider
  }

  private func recordSonioxFailure(
    _ message: String,
    source: MeetingAudioSource
  ) {
    sonioxFailures[source] = message
    recoverySources.insert(source)
  }

  func sourcesNeedingRecovery() -> Set<MeetingAudioSource> {
    recoverySources
  }

  func sourcesNeedingFullRecovery() -> Set<MeetingAudioSource> {
    fullRecoverySources
  }

  func markRecoveryRequired(
    source: MeetingAudioSource,
    fullSource: Bool = false
  ) {
    recoverySources.insert(source)
    if fullSource {
      fullRecoverySources.insert(source)
    }
  }

  private func finishParakeet() async throws {
    var failures: [String] = []
    do {
      if let systemManager {
        _ = try await systemManager.finish()
        await emitParakeet(
          await systemManager.consumeTokenTimings(),
          source: .systemAudio
        )
      }
    } catch {
      recoverySources.insert(.systemAudio)
      failures.append("System audio: \(error.localizedDescription)")
    }
    do {
      if let microphoneManager {
        _ = try await microphoneManager.finish()
        await emitParakeet(
          await microphoneManager.consumeTokenTimings(),
          source: .microphone
        )
      }
    } catch {
      recoverySources.insert(.microphone)
      failures.append("Microphone: \(error.localizedDescription)")
    }
    if !failures.isEmpty {
      throw ProviderError.networkError(failures.joined(separator: "; "))
    }
  }

  private func finishSoniox() async throws {
    guard let system = sonioxProviders[.systemAudio],
          let microphone = sonioxProviders[.microphone] else { return }
    do {
      async let systemText = system.endRealtime()
      async let microphoneText = microphone.endRealtime()
      _ = try await (systemText, microphoneText)
    } catch {
      recoverySources.formUnion(MeetingAudioSource.allCases)
      throw error
    }
    let failures = MeetingAudioSource.allCases.compactMap { source in
      sonioxFailures[source].map { "\(source.displayName): \($0)" }
    }
    if !failures.isEmpty {
      throw ProviderError.networkError(failures.joined(separator: "; "))
    }
  }

  private func process(_ chunk: MeetingAudioChunk) async throws {
    if sourceOffsets[chunk.source] == nil {
      sourceOffsets[chunk.source] = chunk.startTime
    }
    switch engine {
    case .parakeet:
      try await processParakeet(chunk)
    case .soniox:
      guard sonioxFailures[chunk.source] == nil else { return }
      guard let provider = sonioxProviders[chunk.source] else { return }
      provider.enqueuePCM16(Self.pcm16Data(samples: chunk.samples))
    }
  }

  private func processParakeet(_ chunk: MeetingAudioChunk) async throws {
    let buffer = try Self.makeBuffer(samples: chunk.samples)
    switch chunk.source {
    case .systemAudio:
      guard let systemManager else { return }
      try await systemManager.appendAudio(buffer)
      try await systemManager.processBufferedAudio()
      await emitParakeet(
        await systemManager.consumeTokenTimings(),
        source: .systemAudio
      )
    case .microphone:
      guard let microphoneManager else { return }
      try await microphoneManager.appendAudio(buffer)
      try await microphoneManager.processBufferedAudio()
      await emitParakeet(
        await microphoneManager.consumeTokenTimings(),
        source: .microphone
      )
    }
  }

  private func drainPendingChunks() async throws {
    guard !pendingChunks.isEmpty else { return }
    let queued = pendingChunks.sorted { $0.startTime < $1.startTime }
    pendingChunks.removeAll(keepingCapacity: false)
    for (index, chunk) in queued.enumerated() {
      do {
        try await process(chunk)
      } catch {
        let affectedSources = Set(queued[index...].map(\.source))
        recoverySources.formUnion(affectedSources)
        fullRecoverySources.formUnion(affectedSources)
        throw error
      }
    }
  }

  private func emitParakeet(
    _ timings: [TokenTiming],
    source: MeetingAudioSource
  ) async {
    guard !timings.isEmpty else { return }
    let offset = sourceOffsets[source] ?? 0
    await tokenHandler(
      timings.map {
        MeetingTranscriptToken(
          source: source,
          startTime: offset + $0.startTime,
          endTime: offset + $0.endTime,
          text: $0.token
        )
      }
    )
  }

  private func emitSoniox(
    _ tokens: [SonioxRealtimeToken],
    source: MeetingAudioSource
  ) async {
    guard !tokens.isEmpty else { return }
    let offset = sourceOffsets[source] ?? 0
    var endTime = sonioxEndTimes[source] ?? offset
    let mapped = tokens.compactMap { token -> MeetingTranscriptToken? in
      guard !token.text.isEmpty,
            !SonioxStreamingProvider.isControlToken(token.text) else { return nil }
      let start = token.startMs.map { offset + Double($0) / 1_000 } ?? endTime
      let end = max(
        start,
        token.endMs.map { offset + Double($0) / 1_000 } ?? start
      )
      endTime = end
      return MeetingTranscriptToken(
        source: source,
        startTime: start,
        endTime: end,
        text: token.text
      )
    }
    sonioxEndTimes[source] = endTime
    if !mapped.isEmpty {
      await tokenHandler(mapped)
    }
  }

  private func emitSonioxPreview(
    _ tokens: [SonioxRealtimeToken],
    source: MeetingAudioSource
  ) async {
    await previewHandler(source, Self.previewText(tokens: tokens))
  }

  nonisolated static func previewText(tokens: [SonioxRealtimeToken]) -> String {
    tokens.compactMap { token in
      guard !token.isFinal,
            !token.text.isEmpty,
            !SonioxStreamingProvider.isControlToken(token.text) else { return nil }
      return token.text
    }.joined()
  }

  static func pcm16Data(samples: [Float]) -> Data {
    let values = samples.map { sample -> Int16 in
      let clamped = max(-1, min(1, sample))
      let scale: Float = clamped < 0 ? 32_768 : 32_767
      return Int16((clamped * scale).rounded()).littleEndian
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(samples.count)
    ),
    let channel = buffer.floatChannelData?.pointee else {
      throw ASRError.invalidAudioData
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      channel.update(from: baseAddress, count: samples.count)
    }
    return buffer
  }
}
