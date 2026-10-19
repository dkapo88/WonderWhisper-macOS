import Foundation
import AVFoundation
import FluidAudio

/// Feeds the Grok engine's single two-channel stream. Capture delivers each source on its own
/// path, so chunks are aligned into stereo frames here before they are sent.
private actor MeetingStereoStreamIngress {
  private static let maximumPendingChunks = 6_000

  private var aligner = MeetingStereoAligner()
  private var provider: XAIMeetingStreamingProvider?
  private var pendingChunks: [MeetingAudioChunk] = []
  private var preparationFailure: String?
  private var streamFailure: String?
  private var recoveryRequired = false
  private var isFinishing = false
  private var latestInputEndTime: TimeInterval = 0
  private var latestOutputEndTime: TimeInterval = 0
  private var lastMetricsLogTime = Date()

  func install(provider: XAIMeetingStreamingProvider) {
    guard !isFinishing else { return }
    self.provider = provider
    let queued = pendingChunks.sorted { lhs, rhs in
      if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
      return lhs.source.rawValue < rhs.source.rawValue
    }
    pendingChunks.removeAll(keepingCapacity: false)
    for chunk in queued {
      process(chunk)
    }
  }

  func markPreparationFailure(_ message: String) {
    preparationFailure = message
    recoveryRequired = true
    pendingChunks.removeAll()
  }

  func markStreamFailure(_ message: String) {
    streamFailure = message
    recoveryRequired = true
  }

  func ingest(_ chunk: MeetingAudioChunk) throws {
    guard !isFinishing, streamFailure == nil else { return }
    if let preparationFailure {
      throw ProviderError.networkError(preparationFailure)
    }
    guard provider != nil else {
      if pendingChunks.count >= Self.maximumPendingChunks {
        recoveryRequired = true
        pendingChunks.removeFirst(min(500, pendingChunks.count))
        pendingChunks.append(chunk)
        throw ProviderError.networkError(
          "Transcription startup fell behind; earliest queued audio will require recovery from CAF."
        )
      }
      pendingChunks.append(chunk)
      return
    }
    process(chunk)
  }

  func finish() {
    isFinishing = true
    guard streamFailure == nil, let provider else { return }
    for frame in aligner.finish() {
      provider.enqueuePCM16(frame.interleavedPCM16)
      latestOutputEndTime = max(latestOutputEndTime, frame.startTime + frame.duration)
    }
  }

  func needsRecovery() -> Bool {
    recoveryRequired
  }

  func reset() {
    aligner = MeetingStereoAligner()
    provider = nil
    pendingChunks.removeAll()
    preparationFailure = nil
    streamFailure = nil
    recoveryRequired = false
    isFinishing = false
    latestInputEndTime = 0
    latestOutputEndTime = 0
    lastMetricsLogTime = Date()
  }

  private func process(_ chunk: MeetingAudioChunk) {
    guard let provider else { return }
    latestInputEndTime = max(latestInputEndTime, chunk.startTime + chunk.duration)
    let hadDiscardedLateAudio = aligner.hasDiscardedLateAudio
    let frames = aligner.ingest(chunk)
    if !hadDiscardedLateAudio, aligner.hasDiscardedLateAudio {
      recoveryRequired = true
      AppLog.dictation.error(
        "MeetingTranscription: a source arrived after its timeline was sent; raw recovery required"
      )
    }
    for frame in frames {
      provider.enqueuePCM16(frame.interleavedPCM16)
      latestOutputEndTime = max(latestOutputEndTime, frame.startTime + frame.duration)
    }
    logMetricsIfNeeded()
  }

  private func logMetricsIfNeeded() {
    let now = Date()
    guard now.timeIntervalSince(lastMetricsLogTime) >= 10 else { return }
    lastMetricsLogTime = now
    let input = String(format: "%.1f", latestInputEndTime)
    let output = String(format: "%.1f", latestOutputEndTime)
    let lag = String(format: "%.1f", max(0, latestInputEndTime - latestOutputEndTime))
    AppLog.dictation.log(
      "MeetingIngress: input=\(input, privacy: .public)s output=\(output, privacy: .public)s lag=\(lag, privacy: .public)s"
    )
  }
}

/// The parts of FluidAudio's `StreamingUnifiedAsrManager` the meeting service
/// drives per source. A protocol so finalization ordering is testable with
/// fake streams.
protocol MeetingParakeetStream: Actor {
  func appendAudio(_ buffer: AVAudioPCMBuffer) throws
  func processBufferedAudio() async throws
  func finish() async throws -> String
  func consumeTokenTimings() -> [TokenTiming]
  func cleanup() async
}

extension StreamingUnifiedAsrManager: MeetingParakeetStream {}

actor MeetingTranscriptionService {
  typealias TokenHandler = @Sendable ([MeetingTranscriptToken]) async -> Void
  typealias PreviewHandler = @Sendable (MeetingAudioSource, String) async -> Void
  typealias CorrectionHandler = @Sendable ([MeetingTokenCorrection]) async -> Void

  private static let maximumPendingChunks = 6_000

  /// Terms every cloud meeting stream is biased towards, after the user's vocabulary.
  static let meetingTerms = ["Hapana", "CORE", "OC", "BC", "INT", "Jira", "Linear", "Obsidian"]

  nonisolated private let engine: MeetingTranscriptionEngine
  nonisolated private let timelineOffset: TimeInterval
  nonisolated private let stereoIngress = MeetingStereoStreamIngress()
  private let participantNames: [String]
  private let tokenHandler: TokenHandler
  private let previewHandler: PreviewHandler
  private let correctionHandler: CorrectionHandler
  private var systemManager: (any MeetingParakeetStream)?
  private var microphoneManager: (any MeetingParakeetStream)?
  // Parakeet sources with vocabulary boosting configured, and the live tokens
  // emitted for them (kept so the rescored text can be mapped back at finish).
  private var boostedSources: Set<MeetingAudioSource> = []
  private var boostedTokens: [MeetingAudioSource: [MeetingTranscriptToken]] = [:]
  private var sonioxProviders: [MeetingAudioSource: SonioxStreamingProvider] = [:]
  private var xaiProvider: XAIMeetingStreamingProvider?
  private var xaiFailure: String?
  private var sourceOffsets: [MeetingAudioSource: TimeInterval] = [:]
  private var sonioxEndTimes: [MeetingAudioSource: TimeInterval] = [:]
  private var pendingChunks: [MeetingAudioChunk] = []
  private var preparationFailure: String?
  private var sonioxFailures: [MeetingAudioSource: String] = [:]
  private var recoverySources: Set<MeetingAudioSource> = []
  private var fullRecoverySources: Set<MeetingAudioSource> = []
  private var isReady = false
  private var isFinishing = false

  /// `participantNames` (the user and the attendees) bias cloud recognition towards the
  /// names people will say.
  init(
    engine: MeetingTranscriptionEngine = .parakeet,
    timelineOffset: TimeInterval = 0,
    participantNames: [String] = [],
    tokenHandler: @escaping TokenHandler,
    previewHandler: @escaping PreviewHandler = { _, _ in },
    correctionHandler: @escaping CorrectionHandler = { _ in }
  ) {
    self.engine = engine.normalized
    self.timelineOffset = max(0, timelineOffset)
    self.participantNames = participantNames
    self.tokenHandler = tokenHandler
    self.previewHandler = previewHandler
    self.correctionHandler = correctionHandler
  }

  func prepare() async throws {
    guard !isReady else { return }
    do {
      switch engine {
      case .parakeet:
        try await prepareParakeet()
      case .soniox, .sonioxSeparate:
        try await prepareSeparateSoniox()
      case .xaiGrok:
        try await prepareGrok()
      }
      isReady = true
    } catch {
      preparationFailure = error.localizedDescription
      if engine == .xaiGrok {
        await stereoIngress.markPreparationFailure(error.localizedDescription)
      }
      recoverySources.formUnion(MeetingAudioSource.captureSources)
      fullRecoverySources.formUnion(MeetingAudioSource.captureSources)
      pendingChunks.removeAll()
      throw error
    }
  }

  nonisolated func ingest(_ chunk: MeetingAudioChunk) async throws {
    if engine == .xaiGrok {
      try await stereoIngress.ingest(Self.streamLocalChunk(
        chunk,
        timelineOffset: timelineOffset
      ))
      return
    }
    try await ingestSourceSpecific(chunk)
  }

  /// A chunk on the stream's own clock: a resumed meeting's stream starts at zero.
  nonisolated static func streamLocalChunk(
    _ chunk: MeetingAudioChunk,
    timelineOffset: TimeInterval
  ) -> MeetingAudioChunk {
    MeetingAudioChunk(
      source: chunk.source,
      samples: chunk.samples,
      startTime: max(0, chunk.startTime - max(0, timelineOffset)),
      duration: chunk.duration
    )
  }

  private func ingestSourceSpecific(_ chunk: MeetingAudioChunk) async throws {
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
        recoverySources.formUnion(MeetingAudioSource.captureSources)
        fullRecoverySources.formUnion(MeetingAudioSource.captureSources)
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
    case .soniox, .sonioxSeparate:
      try await finishSeparateSoniox()
    case .xaiGrok:
      try await finishGrok()
    }
  }

  /// Test seam: install ready Parakeet streams (skipping model loading) and
  /// mark which sources have vocabulary boosting.
  func installParakeetStreamsForTesting(
    system: any MeetingParakeetStream,
    microphone: any MeetingParakeetStream,
    boostedSources: Set<MeetingAudioSource>
  ) {
    systemManager = system
    microphoneManager = microphone
    self.boostedSources = boostedSources
    isReady = true
  }

  func cleanup() async {
    if let systemManager { await systemManager.cleanup() }
    if let microphoneManager { await microphoneManager.cleanup() }
    for provider in sonioxProviders.values {
      await provider.abort()
    }
    await xaiProvider?.abort()
    await stereoIngress.reset()
    systemManager = nil
    microphoneManager = nil
    boostedSources.removeAll()
    boostedTokens.removeAll()
    sonioxProviders.removeAll()
    xaiProvider = nil
    xaiFailure = nil
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
    await configureVocabularyBoosting(system: system, microphone: microphone)
    AppLog.dictation.log("MeetingTranscription: two Parakeet Unified streams ready")
  }

  /// Best-effort: configure both streams before any audio is appended so the
  /// rescored transcript covers the whole meeting. Any failure leaves the
  /// meeting unboosted; it never fails preparation.
  private func configureVocabularyBoosting(
    system: StreamingUnifiedAsrManager,
    microphone: StreamingUnifiedAsrManager
  ) async {
    let terms = ParakeetVocabularyBoosting.currentTermsToBoost()
    guard !terms.isEmpty else { return }
    guard let ctcModels = await ParakeetCtcModelStore.shared.modelsIfAvailable() else {
      AppLog.dictation.log("MeetingTranscription: CTC model unavailable; meeting not boosted")
      return
    }
    let vocabulary = ParakeetVocabularyBoosting.vocabularyContext(for: terms)
    for (source, manager) in [(MeetingAudioSource.systemAudio, system), (.microphone, microphone)] {
      do {
        try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctcModels)
        boostedSources.insert(source)
      } catch {
        AppLog.dictation.error(
          "MeetingTranscription: \(source.displayName) boosting failed: \(error.localizedDescription)"
        )
      }
    }
    AppLog.dictation.log(
      "MeetingTranscription: vocabulary boosting terms=\(terms.count) sources=\(self.boostedSources.count)"
    )
  }

  /// Map a boosted source's rescored final text back onto its live tokens.
  private func emitVocabularyCorrections(rescoredText: String, source: MeetingAudioSource) async {
    guard boostedSources.contains(source),
          let tokens = boostedTokens[source], !tokens.isEmpty else { return }
    let corrections = MeetingVocabularyCorrector.corrections(
      rawTokens: tokens,
      rescoredText: rescoredText
    )
    AppLog.dictation.log(
      "MeetingTranscription: \(source.displayName) vocabulary corrections=\(corrections.count)"
    )
    guard !corrections.isEmpty else { return }
    await correctionHandler(corrections)
  }

  private func prepareSeparateSoniox() async throws {
    // Only the call is split into speakers: everything on the microphone is the user.
    let system = await makeSonioxProvider(source: .systemAudio, realtimeOptions: .remoteMeeting)
    let microphone = await makeSonioxProvider(source: .microphone, realtimeOptions: .meeting)
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

  /// Names first so the provider's term limit never drops them, then the user's
  /// vocabulary, then the fixed meeting terms; case-insensitive duplicates removed.
  nonisolated static func vocabularyTerms(
    participantNames: [String],
    customVocabulary: String,
    spellingCorrections: String
  ) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    let vocabulary = VoiceVocabularyKeyterms.terms(
      customVocabulary: customVocabulary,
      spellingCorrections: spellingCorrections
    )
    for raw in participantNames + vocabulary + meetingTerms {
      let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty,
            term.count <= VoiceVocabularyKeyterms.maxCharactersPerTerm,
            seen.insert(term.lowercased()).inserted else { continue }
      result.append(term)
      if result.count >= VoiceVocabularyKeyterms.maxTerms { break }
    }
    return result
  }

  private func currentVocabularyTerms() -> [String] {
    Self.vocabularyTerms(
      participantNames: participantNames,
      customVocabulary: AppConfig.defaults.string(forKey: "vocab.custom") ?? "",
      spellingCorrections: AppConfig.defaults.string(forKey: "vocab.spelling") ?? ""
    )
  }

  private func makeSonioxProvider(
    source: MeetingAudioSource,
    realtimeOptions: SonioxStreamingProvider.RealtimeOptions
  ) async -> SonioxStreamingProvider {
    let terms = currentVocabularyTerms().joined(separator: ", ")
    let provider = SonioxStreamingProvider(
      apiKeyProvider: {
        KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias)
      },
      vocabularyProvider: { terms },
      languageProvider: {
        AppConfig.defaults.string(forKey: "transcription.language") ?? "en"
      },
      realtimeOptions: realtimeOptions
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
  ) async {
    sonioxFailures[source] = message
    recoverySources.insert(source)
  }

  private func prepareGrok() async throws {
    let language = AppConfig.defaults.string(forKey: "transcription.language") ?? "en"
    let provider = XAIMeetingStreamingProvider(
      apiKeyProvider: {
        KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias)
      },
      keyterms: currentVocabularyTerms(),
      language: language
    )
    await provider.setHandlers(
      onWords: { [weak self] channel, words in
        await self?.emitGrok(words, channel: channel)
      },
      onPreview: { [weak self] channel, text in
        await self?.emitGrokPreview(text, channel: channel)
      },
      onStreamError: { [weak self] message in
        await self?.recordGrokFailure(message)
      }
    )
    xaiProvider = provider
    do {
      try await provider.beginRealtime()
      await stereoIngress.install(provider: provider)
      AppLog.dictation.log("MeetingTranscription: one two-channel Grok stream accepting audio")
    } catch {
      await stereoIngress.markPreparationFailure(error.localizedDescription)
      await provider.abort()
      xaiProvider = nil
      throw error
    }
  }

  /// Grok channel 0 carries the microphone and channel 1 the call.
  nonisolated static func grokSource(channel: Int) -> MeetingAudioSource? {
    switch channel {
    case 0: return .microphone
    case 1: return .systemAudio
    default: return nil
    }
  }

  private func recordGrokFailure(_ message: String) async {
    xaiFailure = message
    await stereoIngress.markStreamFailure(message)
    recoverySources.formUnion(MeetingAudioSource.captureSources)
  }

  private func emitGrokPreview(_ text: String, channel: Int) async {
    guard let source = Self.grokSource(channel: channel) else { return }
    await previewHandler(source, text)
  }

  private func emitGrok(_ words: [XAIMeetingWord], channel: Int) async {
    guard let source = Self.grokSource(channel: channel) else { return }
    let tokens = Self.grokTokens(words, source: source, timelineOffset: timelineOffset)
    guard !tokens.isEmpty else { return }
    await tokenHandler(tokens)
  }

  /// Grok words as transcript tokens on the meeting timeline. Words carry no spacing, so
  /// each gets a leading space like Soniox tokens; the microphone keeps no speaker label.
  nonisolated static func grokTokens(
    _ words: [XAIMeetingWord],
    source: MeetingAudioSource,
    timelineOffset: TimeInterval
  ) -> [MeetingTranscriptToken] {
    words.map { word in
      MeetingTranscriptToken(
        source: source,
        startTime: timelineOffset + word.start,
        endTime: timelineOffset + max(word.start, word.end),
        text: " " + word.text.trimmingCharacters(in: .whitespacesAndNewlines),
        speaker: source == .microphone ? nil : word.speaker
      )
    }
  }

  private func finishGrok() async throws {
    guard let provider = xaiProvider else { return }
    await stereoIngress.finish()
    do {
      try await provider.endRealtime()
    } catch {
      recoverySources.formUnion(MeetingAudioSource.captureSources)
      throw error
    }
    if let xaiFailure {
      recoverySources.formUnion(MeetingAudioSource.captureSources)
      throw ProviderError.networkError("Grok: \(xaiFailure)")
    }
  }

  func sourcesNeedingRecovery() async -> Set<MeetingAudioSource> {
    var sources = recoverySources
    if await stereoIngress.needsRecovery() {
      sources.formUnion(MeetingAudioSource.captureSources)
    }
    return sources
  }

  func sourcesNeedingFullRecovery() async -> Set<MeetingAudioSource> {
    var sources = fullRecoverySources
    if await stereoIngress.needsRecovery() {
      sources.formUnion(MeetingAudioSource.captureSources)
    }
    return sources
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
    var rescoredTexts: [(source: MeetingAudioSource, text: String)] = []
    let streams: [(MeetingAudioSource, (any MeetingParakeetStream)?)] = [
      (.systemAudio, systemManager),
      (.microphone, microphoneManager),
    ]
    // Finish and drain EVERY source before mapping any vocabulary correction:
    // the speaker-crossing guard in MeetingVocabularyCorrector.apply can only
    // see the other source's final tokens once they have all been emitted.
    for (source, stream) in streams {
      guard let stream else { continue }
      do {
        let finalText = try await stream.finish()
        await emitParakeet(await stream.consumeTokenTimings(), source: source)
        rescoredTexts.append((source, finalText))
      } catch {
        recoverySources.insert(source)
        failures.append("\(source.displayName): \(error.localizedDescription)")
      }
    }
    for (source, text) in rescoredTexts {
      await emitVocabularyCorrections(rescoredText: text, source: source)
    }
    if !failures.isEmpty {
      throw ProviderError.networkError(failures.joined(separator: "; "))
    }
  }

  private func finishSeparateSoniox() async throws {
    guard let system = sonioxProviders[.systemAudio],
          let microphone = sonioxProviders[.microphone] else { return }
    do {
      async let systemText = system.endRealtime()
      async let microphoneText = microphone.endRealtime()
      _ = try await (systemText, microphoneText)
    } catch {
      recoverySources.formUnion(MeetingAudioSource.captureSources)
      throw error
    }
    let failures = MeetingAudioSource.captureSources.compactMap { source in
      sonioxFailures[source].map { "\(source.displayName): \($0)" }
    }
    if !failures.isEmpty {
      throw ProviderError.networkError(failures.joined(separator: "; "))
    }
  }

  private func process(_ chunk: MeetingAudioChunk) async throws {
    switch engine {
    case .parakeet:
      if sourceOffsets[chunk.source] == nil {
        sourceOffsets[chunk.source] = chunk.startTime
      }
      try await processParakeet(chunk)
    case .xaiGrok:
      return
    case .soniox, .sonioxSeparate:
      if sourceOffsets[chunk.source] == nil {
        sourceOffsets[chunk.source] = chunk.startTime
      }
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
    case .mixed:
      return
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
    let tokens = timings.map {
      MeetingTranscriptToken(
        source: source,
        startTime: offset + $0.startTime,
        endTime: offset + $0.endTime,
        text: $0.token
      )
    }
    if boostedSources.contains(source) {
      boostedTokens[source, default: []].append(contentsOf: tokens)
    }
    await tokenHandler(tokens)
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
        text: token.text,
        speaker: source == .microphone ? nil : token.speaker
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
