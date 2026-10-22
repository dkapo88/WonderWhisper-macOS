import Foundation
import AppKit
import Combine

enum MeetingIngestionBacklogPolicy {
  // Each source is framed into ten 100 ms chunks per second. Bound the shared
  // queue to roughly six seconds so live captions pause before visibly drifting.
  static let maximumBufferedChunks = 120

  static let warningMessage = "Live transcription paused because audio processing fell behind. "
    + "Recording is continuing and the final transcript will be recovered from saved audio."

  // The coordinator pauses the shared ingestion pipeline, so neither source
  // receives live tokens after a backlog regardless of transcription engine.
  static let recoverySources = Set(MeetingAudioSource.captureSources)
}

private final class MeetingIngestionBacklogGate: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !claimed else { return false }
    claimed = true
    return true
  }

  var wasClaimed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return claimed
  }
}

private final class MeetingAudioLevelGate: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    self.enabled = enabled
  }

  var isEnabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }
}

enum MeetingPreferences {
  static func automaticDetectionEnabled(
    defaults: UserDefaults = AppConfig.defaults
  ) -> Bool {
    defaults.bool(forKey: "meeting.autoDetection.enabled")
  }
}

enum MeetingObsidianPreferences {
  static let vaultRootKey = "meeting.obsidian.vaultRoot"
  static let exportFolderKey = "meeting.obsidian.exportFolder"
  static let legacyKeys = [
    "meeting.obsidian.folder",
    "meeting.vaultRoot",
    "meetings.obsidian.vaultPath"
  ]

  static func vaultRootPath(defaults: UserDefaults = AppConfig.defaults) -> String? {
    migrateIfNeeded(defaults: defaults)
    return defaults.string(forKey: vaultRootKey)?.nonEmpty
  }

  static func exportFolderPath(defaults: UserDefaults = AppConfig.defaults) -> String? {
    migrateIfNeeded(defaults: defaults)
    return defaults.string(forKey: exportFolderKey)?.nonEmpty
  }

  static func contains(_ folder: URL, in vaultRoot: URL) -> Bool {
    let rootPath = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
    return folderPath == rootPath || folderPath.hasPrefix(rootPath + "/")
  }

  private static func migrateIfNeeded(defaults: UserDefaults) {
    let legacyPath = legacyKeys.compactMap {
      defaults.string(forKey: $0)?.nonEmpty
    }.first

    if defaults.string(forKey: vaultRootKey)?.nonEmpty == nil,
       let legacyPath {
      let selectedURL = URL(fileURLWithPath: legacyPath, isDirectory: true)
      let root = MeetingVaultIndex.vaultRoot(containing: selectedURL)
      defaults.set(root.path, forKey: vaultRootKey)
    }

    if defaults.string(forKey: exportFolderKey)?.nonEmpty == nil,
       let legacyPath {
      defaults.set(legacyPath, forKey: exportFolderKey)
    }

    legacyKeys.forEach { defaults.removeObject(forKey: $0) }
  }
}

enum MeetingDetectionPolicy {
  static let idleFallbackInterval: TimeInterval = 5
  static let suspiciousPollInterval: TimeInterval = 3
  static let eventConfirmationDelay: TimeInterval = 1
  static let activeMeetingPollInterval: TimeInterval = 5
  static let endConfirmationDelay: TimeInterval = 30
  static let suppressionReleaseDelay: TimeInterval = 120

  static func nextPollInterval(
    automaticDetectionEnabled: Bool,
    activeMeetingIsAutomatic: Bool?,
    hasSuspiciousSignal: Bool
  ) -> TimeInterval? {
    guard automaticDetectionEnabled else { return nil }
    if let activeMeetingIsAutomatic {
      return activeMeetingIsAutomatic ? activeMeetingPollInterval : nil
    }
    return hasSuspiciousSignal ? suspiciousPollInterval : idleFallbackInterval
  }

  static func confirmsAutomaticStart(stableDuration: TimeInterval) -> Bool {
    stableDuration >= eventConfirmationDelay
  }

  static func releasesSuppression(
    detectedFamily: String?,
    suppressedFamily: String?,
    absentDuration: TimeInterval
  ) -> Bool {
    guard let suppressedFamily else { return true }
    if let detectedFamily {
      return detectedFamily != suppressedFamily
    }
    return absentDuration >= suppressionReleaseDelay
  }

  static func confirmsMeetingEnded(
    likelyStillActive: Bool,
    absentDuration: TimeInterval
  ) -> Bool {
    !likelyStillActive && absentDuration >= endConfirmationDelay
  }

  static var schedulingAllowed: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
  }
}

@MainActor
final class MeetingCoordinator: ObservableObject {
  @Published private(set) var sessions: [MeetingSession] = []
  @Published var selectedSessionID: UUID?
  @Published private(set) var activeSessionID: UUID?
  @Published private(set) var isLoadingSessions = true
  @Published private(set) var isStarting = false
  @Published private(set) var isStopping = false
  @Published private(set) var statusMessage = "Ready"
  @Published private(set) var lastError: String?
  @Published private(set) var noteGenerationSessionIDs: Set<UUID> = []
  @Published private(set) var contextCards: [MeetingContextCard] = []
  @Published private(set) var contextStatus = "Listening for useful topics…"
  @Published private(set) var contextError: String?
  @Published private(set) var isContextSearching = false
  @Published private(set) var liveTranscriptPreviews: [MeetingAudioSource: String] = [:]
  @Published private(set) var liveAudioLevels: [MeetingAudioSource: Float] = [:]
  @Published private(set) var triggerRules: [MeetingTriggerRule] = MeetingTriggerRule.load()
  @Published private(set) var liveMicrophoneApplications: [MeetingMicrophoneApplication] = []
  @Published private(set) var overlayMinimizedSessionID: UUID? {
    didSet {
      audioLevelGate.setEnabled(overlayMinimizedSessionID != nil)
    }
  }

  @Published var liveObsidianContextEnabled: Bool = {
    AppConfig.defaults.bool(forKey: "meeting.context.enabled")
  }() {
    didSet {
      AppConfig.defaults.set(liveObsidianContextEnabled, forKey: "meeting.context.enabled")
      if liveObsidianContextEnabled {
        contextError = nil
        contextStatus = obsidianVaultPath == nil
          ? "Choose an Obsidian vault in Settings → Meetings."
          : "Listening for useful topics…"
        refreshVaultIndexIfNeeded()
        if let activeSession {
          discoverContext(in: activeSession)
        }
      } else {
        cancelContextTasks()
        contextCards.removeAll()
        seenContextTerms.removeAll()
        lastContextAnalysisTokenCount = 0
        lastContextAnalysisAt = nil
        contextStatus = "Live context is off"
      }
    }
  }

  @Published var meetingOverlayEnabled: Bool = {
    if AppConfig.defaults.object(forKey: "meeting.overlay.enabled") == nil {
      return true
    }
    return AppConfig.defaults.bool(forKey: "meeting.overlay.enabled")
  }() {
    didSet {
      AppConfig.defaults.set(meetingOverlayEnabled, forKey: "meeting.overlay.enabled")
      if meetingOverlayEnabled {
        overlayMinimizedSessionID = nil
      }
    }
  }

  @Published var automaticDetectionEnabled: Bool = {
    MeetingPreferences.automaticDetectionEnabled()
  }() {
    didSet {
      AppConfig.defaults.set(
        automaticDetectionEnabled,
        forKey: "meeting.autoDetection.enabled"
      )
      suppressedAutomaticFamily = nil
      suppressedFamilyMissingSince = nil
      resetDetectionState()
      refreshDetectorScheduling()
    }
  }

  @Published var automaticallyExportToObsidian: Bool = {
    if AppConfig.defaults.object(forKey: "meeting.obsidian.autoExport") == nil {
      return true
    }
    return AppConfig.defaults.bool(forKey: "meeting.obsidian.autoExport")
  }() {
    didSet {
      AppConfig.defaults.set(
        automaticallyExportToObsidian,
        forKey: "meeting.obsidian.autoExport"
      )
    }
  }

  @Published var generateMeetingNotes: Bool = {
    if AppConfig.defaults.object(forKey: "meeting.notes.generate") == nil {
      return false
    }
    return AppConfig.defaults.bool(forKey: "meeting.notes.generate")
  }() {
    didSet {
      AppConfig.defaults.set(generateMeetingNotes, forKey: "meeting.notes.generate")
    }
  }

  @Published var noteModel: String = {
    AppConfig.defaults.string(forKey: "meeting.notes.model")
      ?? "openai/gpt-5.4-nano"
  }() {
    didSet {
      AppConfig.defaults.set(noteModel, forKey: "meeting.notes.model")
    }
  }

  @Published var notePrompt: String = {
    MeetingNoteGenerator.resolvedPrompt(
      AppConfig.defaults.string(forKey: MeetingNoteGenerator.promptDefaultsKey)
    )
  }() {
    didSet {
      AppConfig.defaults.set(
        MeetingNoteGenerator.resolvedPrompt(notePrompt),
        forKey: MeetingNoteGenerator.promptDefaultsKey
      )
    }
  }

  @Published var contextModel: String = {
    AppConfig.defaults.string(forKey: "meeting.context.model")
      ?? "openai/gpt-5.4-nano"
  }() {
    didSet {
      AppConfig.defaults.set(contextModel, forKey: "meeting.context.model")
    }
  }

  @Published private(set) var obsidianVaultPath: String? = {
    MeetingObsidianPreferences.vaultRootPath()
  }()

  @Published private(set) var obsidianExportFolderPath: String? = {
    MeetingObsidianPreferences.exportFolderPath()
  }()

  var effectiveObsidianExportFolderPath: String? {
    obsidianExportFolderPath ?? obsidianVaultPath
  }

  @Published var transcriptionEngine: MeetingTranscriptionEngine = {
    MeetingTranscriptionEngine.selected()
  }() {
    didSet {
      AppConfig.defaults.set(
        transcriptionEngine.rawValue,
        forKey: "meeting.transcription.engine"
      )
    }
  }

  /// What the microphone is called in transcripts and notes; "You" when empty.
  @Published var userName: String = {
    AppConfig.defaults.string(forKey: MeetingSpeakerDirectory.userNameDefaultsKey) ?? ""
  }() {
    didSet {
      AppConfig.defaults.set(userName, forKey: MeetingSpeakerDirectory.userNameDefaultsKey)
    }
  }

  @Published var localSpeakerPassEnabled: Bool = {
    MeetingSpeakerPassService.isEnabled()
  }() {
    didSet {
      AppConfig.defaults.set(
        localSpeakerPassEnabled,
        forKey: MeetingSpeakerPassService.enabledDefaultsKey
      )
    }
  }

  @Published var speakerNameSuggestionsEnabled: Bool = {
    MeetingSpeakerNameSuggester.isEnabled()
  }() {
    didSet {
      AppConfig.defaults.set(
        speakerNameSuggestionsEnabled,
        forKey: MeetingSpeakerNameSuggester.enabledDefaultsKey
      )
    }
  }

  @Published private(set) var speakerSuggestionSessionIDs: Set<UUID> = []

  /// How the meeting microphone is gated; applies from the next recording.
  @Published var microphoneGateMode: MeetingMicrophoneGateMode = {
    MeetingMicrophoneGateMode.selected()
  }() {
    didSet {
      AppConfig.defaults.set(
        microphoneGateMode.rawValue,
        forKey: MeetingMicrophoneGateMode.defaultsKey
      )
    }
  }

  /// The user muted the meeting microphone: what it hears is recorded but not transcribed.
  @Published private(set) var isMicrophoneMuted = false
  private var microphoneMuteRecorder: MeetingMicrophoneMuteRecorder?

  private let store = MeetingSessionStore()
  private let capture = MeetingCaptureService()
  private let detector = MeetingDetector()
  private let noteGenerator = MeetingNoteGenerator()
  private let vaultIndex = MeetingVaultIndex()
  private let contextSummarizer = MeetingContextSummarizer()
  // Unit tests never build the production recovery transcriber: it discovers the shared
  // Parakeet models outside the test scratch folder.
  private let transcriptRecovery = AppConfig.testScratchParakeetModels == nil
    ? MeetingTranscriptRecoveryService()
    : MeetingTranscriptRecoveryService { _ in "" }
  private let sonioxAsyncRecovery = MeetingSonioxAsyncRecoveryService()
  // Unit tests never download the diarizer models.
  private let speakerPass = AppConfig.testScratchParakeetModels == nil
    ? MeetingSpeakerPassService()
    : MeetingSpeakerPassService { _ in [] }
  private let speakerNameSuggester = MeetingSpeakerNameSuggester()
  private let audioLevelGate = MeetingAudioLevelGate()
  /// Webhook endpoints and deliveries. Its changes are forwarded to this object's
  /// `objectWillChange`, so views observing the coordinator also refresh on webhook updates.
  let webhooks = MeetingWebhookCenter()
  private var webhookChangeForwarding: AnyCancellable?

  private var transcriber: MeetingTranscriptionService?
  private var preparationTask: Task<Void, Error>?
  private var preparationMonitorTask: Task<Void, Never>?
  private var ingestionTask: Task<Void, Never>?
  private var finalizationTasks: [UUID: Task<Void, Never>] = [:]
  private var discardCleanupTasks: [UUID: Task<Void, Never>] = [:]
  private var transcriptionCleanupTasks: [UUID: Task<Void, Never>] = [:]
  private var audioContinuation: AsyncStream<MeetingAudioChunk>.Continuation?
  private var ingestionBacklogGate: MeetingIngestionBacklogGate?
  private var persistTask: Task<Void, Never>?
  private var dirtySessionIDs: Set<UUID> = []
  private var contextTasks: [UUID: Task<Void, Never>] = [:]
  private var contextAnalysisTask: Task<Void, Never>?
  private var contextAnalysisID: UUID?
  private var lastContextAnalysisTokenCount = 0
  private var lastContextAnalysisAt: Date?
  private var detectorTimer: Timer?
  private var detectorTimerGeneration = 0
  private var detectorEventTask: Task<Void, Never>?
  private var detectorEventPending = false
  private var detectorConfirmationTask: Task<Void, Never>?
  private var lastActiveMeetingPollAt: Date?
  private var candidate: MeetingDetectionCandidate?
  private var candidateDetectedAt: Date?
  private var automaticCandidate: MeetingDetectionCandidate?
  private var candidateMissingSince: Date?
  private var suppressedAutomaticFamily: String?
  private var suppressedFamilyMissingSince: Date?
  private var lastDetectedFamily: String?
  private var lastDetectedAt: Date?
  private var seenContextTerms: Set<String> = []
  private var generatedTitleEligibleSessionIDs: Set<UUID> = []
  private var resumedSessionIDs: Set<UUID> = []
  private var forcedFullRecoverySources: [UUID: Set<MeetingAudioSource>] = [:]
  private var manualNotesDrafts: [UUID: String] = [:]
  private var manualNotesRevisions: [UUID: Int] = [:]

  var activeSession: MeetingSession? {
    guard let activeSessionID else { return nil }
    return sessions.first(where: { $0.id == activeSessionID })
  }

  var selectedSession: MeetingSession? {
    let id = selectedSessionID ?? activeSessionID ?? sessions.first?.id
    return sessions.first(where: { $0.id == id })
  }

  var hasSonioxAPIKey: Bool {
    KeychainService().getSecret(forKey: AppConfig.sonioxAPIKeyAlias) != nil
  }

  var hasXAIAPIKey: Bool {
    KeychainService().getSecret(forKey: AppConfig.xaiAPIKeyAlias) != nil
  }

  init() {
    webhookChangeForwarding = webhooks.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    webhooks.onFinalFailure = { [weak self] message in
      self?.lastError = message
    }
    Task { [weak self] in
      guard let self else { return }
      let loaded = await store.loadAll()
      let currentIDs = Set(sessions.map(\.id))
      sessions.append(contentsOf: loaded.filter { !currentIDs.contains($0.id) })
      sessions.sort { $0.startedAt > $1.startedAt }
      if selectedSessionID == nil {
        selectedSessionID = sessions.first?.id
      }
      isLoadingSessions = false
      if MeetingDetectionPolicy.schedulingAllowed {
        await pollMeetingDetector()
      }
    }
    if MeetingDetectionPolicy.schedulingAllowed {
      detector.startMonitoring { [weak self] in
        self?.handleDetectorEvent()
      }
    }
    statusMessage = automaticDetectionEnabled ? "Watching for meetings" : "Ready"
  }

  deinit {
    SystemAudioController.shared.setMeetingCaptureActive(false)
    detectorTimer?.invalidate()
    detectorEventTask?.cancel()
    detectorConfirmationTask?.cancel()
    persistTask?.cancel()
    preparationTask?.cancel()
    preparationMonitorTask?.cancel()
    ingestionTask?.cancel()
    finalizationTasks.values.forEach { $0.cancel() }
    discardCleanupTasks.values.forEach { $0.cancel() }
    transcriptionCleanupTasks.values.forEach { $0.cancel() }
    audioContinuation?.finish()
    contextTasks.values.forEach { $0.cancel() }
    contextAnalysisTask?.cancel()
  }

  func startManualMeeting(title: String? = nil) async {
    await startMeeting(
      title: title,
      detectedApp: nil,
      automaticallyStarted: false,
      candidate: nil,
      resuming: nil
    )
  }

  func refreshLiveMicrophoneApplications() {
    let applications = detector.liveMicrophoneApplications()
    guard applications != liveMicrophoneApplications else { return }
    liveMicrophoneApplications = applications
  }

  func canResumeMeeting(_ session: MeetingSession) -> Bool {
    MeetingResumePlan.canResume(session)
      && activeSessionID == nil
      && !isLoadingSessions
      && !isStarting
      && !isStopping
      && finalizationTasks[session.id] == nil
      && !noteGenerationSessionIDs.contains(session.id)
  }

  func resumeMeeting(_ session: MeetingSession) async {
    guard var currentSession = self.session(withID: session.id),
          canResumeMeeting(currentSession) else { return }
    let retainedAudioFiles = await store.audioFiles(for: currentSession.id)
    if !retainedAudioFiles.isEmpty {
      currentSession.audioFiles = retainedAudioFiles
      replace(currentSession)
      await persist(currentSession)
    }
    await startMeeting(
      title: currentSession.title,
      detectedApp: currentSession.detectedApp,
      automaticallyStarted: false,
      candidate: nil,
      resuming: currentSession
    )
  }

  func minimizeMeetingOverlayForCurrentSession() {
    guard let activeSessionID else { return }
    overlayMinimizedSessionID = activeSessionID
    commitManualNotes(for: activeSessionID)
  }

  /// Mutes or unmutes the meeting microphone for transcription. The audio is still saved.
  func setMicrophoneMuted(_ muted: Bool) {
    guard let activeSessionID, let microphoneMuteRecorder else { return }
    microphoneMuteRecorder.setMuted(muted)
    isMicrophoneMuted = muted
    // Saved straight away, so a crash or quit mid-meeting cannot lose a mute.
    if var session = session(withID: activeSessionID) {
      session.microphoneMutedRanges = microphoneMuteRecorder.persistableRanges
      replace(session)
      schedulePersist(session)
    }
  }

  func toggleMicrophoneMute() {
    setMicrophoneMuted(!isMicrophoneMuted)
  }

  func restoreMeetingOverlayForCurrentSession() {
    guard overlayMinimizedSessionID == activeSessionID else { return }
    overlayMinimizedSessionID = nil
  }

  func stopMeeting(suppressCurrentAutomaticCall: Bool = true) async {
    guard !isStarting,
          !isStopping,
          let activeSessionID,
          var session = session(withID: activeSessionID) else {
      return
    }

    isStopping = true
    let recentlyDetectedFamily: String? = {
      guard let lastDetectedAt,
            Date().timeIntervalSince(lastDetectedAt) <= 30 else { return nil }
      return lastDetectedFamily
    }()
    let familyToSuppress = automaticCandidate?.bundleFamily
      ?? detector.currentCandidate(triggerRules: triggerRules)?.bundleFamily
      ?? recentlyDetectedFamily
    cancelContextTasks()
    statusMessage = "Stopping meeting…"

    let audioFiles = await capture.stop()
    SystemAudioController.shared.setMeetingCaptureActive(false)
    let liveTranscriptionBacklogged = ingestionBacklogGate?.wasClaimed == true
    ingestionBacklogGate = nil
    if liveTranscriptionBacklogged {
      forcedFullRecoverySources[activeSessionID, default: []].formUnion(
        MeetingAudioSource.captureSources
      )
    }

    audioContinuation?.finish()
    audioContinuation = nil
    var finalizingIngestionTask = ingestionTask
    var finalizingTranscriber = transcriber
    var finalizingPreparationTask = preparationTask
    var finalizingTranscriptionCleanupTask = transcriptionCleanupTasks[activeSessionID]
    if liveTranscriptionBacklogged {
      finalizingIngestionTask?.cancel()
      finalizingPreparationTask?.cancel()
      if finalizingTranscriptionCleanupTask == nil {
        let stalledIngestionTask = finalizingIngestionTask
        let stalledPreparationTask = finalizingPreparationTask
        let stalledTranscriber = finalizingTranscriber
        finalizingTranscriptionCleanupTask = Task {
          await stalledIngestionTask?.value
          _ = try? await stalledPreparationTask?.value
          await stalledTranscriber?.cleanup()
        }
      }
      finalizingIngestionTask = nil
      finalizingTranscriber = nil
      finalizingPreparationTask = nil
    }
    self.ingestionTask = nil
    self.transcriber = nil
    preparationTask = nil
    preparationMonitorTask?.cancel()
    preparationMonitorTask = nil

    session = self.session(withID: activeSessionID) ?? session
    if let updatedSession = await flushManualNotes(for: activeSessionID) {
      session = updatedSession
    }
    if liveTranscriptionBacklogged, session.errorMessage == nil {
      session.errorMessage = "Live transcription warning: "
        + MeetingIngestionBacklogPolicy.warningMessage
    }
    session.audioFiles = Array(Set(session.audioFiles + audioFiles)).sorted()
    if let microphoneMuteRecorder {
      session.microphoneMutedRanges = microphoneMuteRecorder.ranges
    }
    microphoneMuteRecorder = nil
    isMicrophoneMuted = false
    let endedAt = Date()
    if let recordingStartedAt = session.recordingStartedAt {
      session.recordedDuration = (session.recordedDuration ?? 0)
        + max(0, endedAt.timeIntervalSince(recordingStartedAt))
    }
    session.recordingStartedAt = nil
    session.endedAt = endedAt
    session.status = .processing
    replace(session)
    self.activeSessionID = nil
    automaticCandidate = nil
    suppressedAutomaticFamily = suppressCurrentAutomaticCall ? familyToSuppress : nil
    suppressedFamilyMissingSince = nil
    candidateMissingSince = nil
    seenContextTerms.removeAll()
    liveTranscriptPreviews.removeAll()
    liveAudioLevels.removeAll()
    overlayMinimizedSessionID = nil
    await persist(session)
    isStopping = false
    scheduleNextDetectorPoll()
    statusMessage = "Meeting stopped • finishing transcript…"

    let sessionID = session.id
    let shouldGenerateNotes = generateMeetingNotes || resumedSessionIDs.contains(sessionID)
    let selectedNoteModel = noteModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty ?? "openai/gpt-5.4-nano"
    let selectedNotePrompt = notePrompt
    let shouldAutoExport = automaticallyExportToObsidian
    let exportFolder = obsidianExportFolderURL
    finalizationTasks[sessionID] = Task { @MainActor [weak self] in
      guard let self else {
        await finalizingIngestionTask?.value
        _ = try? await finalizingPreparationTask?.value
        await finalizingTranscriptionCleanupTask?.value
        await finalizingTranscriber?.cleanup()
        return
      }
      await finalizeMeeting(
        sessionID: sessionID,
        transcriber: finalizingTranscriber,
        preparationTask: finalizingPreparationTask,
        ingestionTask: finalizingIngestionTask,
        transcriptionCleanupTask: finalizingTranscriptionCleanupTask,
        generateNotes: shouldGenerateNotes,
        noteModel: selectedNoteModel,
        notePrompt: selectedNotePrompt,
        autoExport: shouldAutoExport,
        exportFolder: exportFolder
      )
    }
  }

  func discardAutomaticMeeting(sessionID: UUID) async {
    guard !isStarting,
          !isStopping,
          activeSessionID == sessionID,
          var session = session(withID: sessionID),
          session.automaticallyStarted else { return }

    isStopping = true
    let familyToSuppress = automaticCandidate?.bundleFamily
      ?? detector.currentCandidate(triggerRules: triggerRules)?.bundleFamily
      ?? lastDetectedFamily
    cancelContextTasks()
    statusMessage = "Discarding automatic meeting…"

    let audioFiles = await capture.stop()
    // Kept in case the discard fails and the session is retained (it can be resumed).
    let mutedRanges = microphoneMuteRecorder?.ranges
    microphoneMuteRecorder = nil
    isMicrophoneMuted = false
    SystemAudioController.shared.setMeetingCaptureActive(false)
    audioContinuation?.finish()
    audioContinuation = nil
    ingestionBacklogGate = nil

    let abandonedIngestionTask = ingestionTask
    let abandonedPreparationTask = preparationTask
    let abandonedTranscriber = transcriber
    let existingTranscriptionCleanupTask = transcriptionCleanupTasks[sessionID]
    ingestionTask = nil
    preparationTask = nil
    transcriber = nil
    preparationMonitorTask?.cancel()
    preparationMonitorTask = nil

    activeSessionID = nil
    automaticCandidate = nil
    suppressedAutomaticFamily = familyToSuppress
    suppressedFamilyMissingSince = nil
    candidateMissingSince = nil
    liveTranscriptPreviews.removeAll()
    liveAudioLevels.removeAll()
    overlayMinimizedSessionID = nil
    seenContextTerms.removeAll()
    dirtySessionIDs.remove(sessionID)

    abandonedIngestionTask?.cancel()
    abandonedPreparationTask?.cancel()
    // Abort local managers/WebSockets before allowing another meeting to start.
    await abandonedTranscriber?.cleanup()
    await existingTranscriptionCleanupTask?.value
    discardCleanupTasks[sessionID] = Task { @MainActor [weak self] in
      await abandonedIngestionTask?.value
      _ = try? await abandonedPreparationTask?.value
      await abandonedTranscriber?.cleanup()
      self?.discardCleanupTasks.removeValue(forKey: sessionID)
    }

    do {
      try await store.delete(session)
      sessions.removeAll { $0.id == sessionID }
      forcedFullRecoverySources.removeValue(forKey: sessionID)
      generatedTitleEligibleSessionIDs.remove(sessionID)
      manualNotesDrafts.removeValue(forKey: sessionID)
      manualNotesRevisions.removeValue(forKey: sessionID)
      selectedSessionID = sessions.first?.id
      lastError = nil
      statusMessage = "Automatic meeting discarded"
    } catch {
      session.audioFiles = audioFiles
      if let mutedRanges {
        session.microphoneMutedRanges = mutedRanges
      }
      session.endedAt = Date()
      session.status = .failed
      session.errorMessage = "Meeting could not be discarded: \(error.localizedDescription)"
      replace(session)
      selectedSessionID = sessionID
      await persist(session)
      lastError = session.errorMessage
      statusMessage = "Meeting retained because discard failed"
    }
    isStopping = false
    scheduleNextDetectorPoll()
  }

  private func finalizeMeeting(
    sessionID: UUID,
    transcriber: MeetingTranscriptionService?,
    preparationTask: Task<Void, Error>?,
    ingestionTask: Task<Void, Never>?,
    transcriptionCleanupTask: Task<Void, Never>?,
    generateNotes: Bool,
    noteModel: String,
    notePrompt: String,
    autoExport: Bool,
    exportFolder: URL?
  ) async {
    var warning: String?

    await ingestionTask?.value
    await transcriptionCleanupTask?.value

    if let preparationTask {
      do {
        try await preparationTask.value
      } catch is CancellationError {
        warning = "Transcription finalization was cancelled."
      } catch {
        warning = "Transcription unavailable: \(error.localizedDescription)"
      }
    }

    if !Task.isCancelled, let transcriber {
      do {
        try await MeetingFinalizationTimeout.run(
          seconds: MeetingFinalizationTimeout.finishSeconds
        ) {
          try await transcriber.finish()
        }
      } catch is MeetingFinalizationTimeout.Expired {
        // The provider never completed its handshake. Fall through to transcript
        // recovery from retained audio instead of awaiting it forever.
        forcedFullRecoverySources[sessionID, default: []]
          .formUnion(MeetingAudioSource.captureSources)
        warning = warning
          ?? "Transcription finalization timed out; the transcript was recovered from audio."
        AppLog.dictation.error(
          "MeetingFinalize: transcriber.finish timed out; recovering from retained audio"
        )
      } catch {
        warning = warning
          ?? "Transcription finalization failed: \(error.localizedDescription)"
      }
    }
    let forcedRecovery = forcedFullRecoverySources.removeValue(forKey: sessionID) ?? []
    let recoverySources = (await transcriber?.sourcesNeedingRecovery() ?? [])
      .union(forcedRecovery)
    let fullRecoverySources = (await transcriber?.sourcesNeedingFullRecovery() ?? [])
      .union(forcedRecovery)
    await transcriber?.cleanup()

    if !Task.isCancelled,
       !recoverySources.isEmpty,
       var interruptedSession = session(withID: sessionID),
       !interruptedSession.audioFiles.isEmpty {
      do {
        let directory = try await store.directory(for: sessionID)
        var output: (
          tokens: [MeetingTranscriptToken],
          sources: Set<MeetingAudioSource>,
          method: String
        )?
        var asyncFallbackWarning: String?

        if interruptedSession.transcriptionEngine?.usesSoniox == true,
           fullRecoverySources.isSuperset(of: MeetingAudioSource.captureSources) {
          do {
            output = (
              try await sonioxAsyncRecovery.recover(
                sessionDirectory: directory,
                audioFilenames: interruptedSession.audioFiles,
                microphoneGate: MeetingMicrophoneGateSettings(session: interruptedSession)
              ),
              MeetingAudioSource.captureSources,
              "with Soniox async diarization"
            )
          } catch {
            let description = error.localizedDescription
            asyncFallbackWarning = "Soniox async diarization failed; local recovery was used: "
              + description
            AppLog.dictation.error(
              "MeetingTranscriptRecovery: Soniox async failed: \(description, privacy: .public)"
            )
          }
        }

        if output == nil {
          let result = try await transcriptRecovery.recover(
            sessionDirectory: directory,
            audioFilenames: interruptedSession.audioFiles,
            existingTokens: interruptedSession.transcriptTokens,
            sourcesNeedingRecovery: recoverySources,
            fullRecoverySources: fullRecoverySources,
            microphoneGate: MeetingMicrophoneGateSettings(session: interruptedSession)
          )
          output = (result.tokens, result.recoveredSources, "locally")
        }

        if let output {
          interruptedSession.transcriptTokens = output.tokens
          if interruptedSession.errorMessage?.hasPrefix("Live transcription warning:") == true {
            interruptedSession.errorMessage = nil
          }
          replace(interruptedSession)
          await persist(interruptedSession)
          if output.sources.isSuperset(of: recoverySources) {
            warning = asyncFallbackWarning
            let recoveryResult = "restored \(output.sources.count) source(s) \(output.method)"
            AppLog.dictation.log(
              "MeetingTranscriptRecovery: \(recoveryResult, privacy: .public)"
            )
          } else {
            let missing = recoverySources.subtracting(output.sources)
              .map(\.displayName)
              .sorted()
              .joined(separator: ", ")
            warning = "Transcript recovery had no retained audio for: \(missing)."
          }
        }
      } catch {
        warning = "Transcript recovery failed: \(error.localizedDescription)"
      }
    }

    if !Task.isCancelled, localSpeakerPassEnabled {
      await runSpeakerPass(for: sessionID)
    }
    if !Task.isCancelled, speakerNameSuggestionsEnabled, generateNotes {
      await suggestSpeakerNames(for: sessionID, model: noteModel)
    }

    guard let transcribedSession = session(withID: sessionID) else {
      finalizationTasks.removeValue(forKey: sessionID)
      return
    }
    let transcript = transcribedSession.transcriptPlainText
    let manualNotes = transcribedSession.manualNotesMarkdown?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ) ?? ""
    let titleBeforeGeneration = transcribedSession.title
    var generatedNotes: MeetingGeneratedNotes?
    var notesWarning: String?
    if !Task.isCancelled, generateNotes, (!transcript.isEmpty || !manualNotes.isEmpty) {
      do {
        generatedNotes = try await noteGenerator.generate(
          transcript: transcript,
          manualNotes: manualNotes,
          participants: MeetingNoteGenerator.participants(for: transcribedSession),
          model: noteModel,
          prompt: notePrompt
        )
      } catch {
        notesWarning = "Meeting notes were not generated: \(error.localizedDescription)"
      }
    }

    // Re-read after cloud work so title edits made while notes were generating are preserved.
    guard var session = session(withID: sessionID) else {
      finalizationTasks.removeValue(forKey: sessionID)
      return
    }
    session.errorMessage = session.errorMessage ?? warning ?? notesWarning
    if let generatedNotes {
      session.notesMarkdown = generatedNotes.markdown
      if generatedTitleEligibleSessionIDs.contains(sessionID),
         session.title == titleBeforeGeneration,
         let generatedTitle = generatedNotes.title {
        session.title = generatedTitle
      }
    }
    generatedTitleEligibleSessionIDs.remove(sessionID)
    session.status = .completed
    resumedSessionIDs.remove(sessionID)
    if !Task.isCancelled, autoExport, let exportFolder {
      do {
        let exported = try MeetingObsidianExporter.export(
          session: session,
          to: exportFolder
        )
        session.exportedMarkdownPath = exported.path
      } catch {
        let message = "Obsidian export failed: \(error.localizedDescription)"
        session.errorMessage = session.errorMessage ?? message
      }
    }

    replace(session)
    let persisted = await persist(session)
    if Self.shouldSendCompletedWebhook(persisted: persisted, isCancelled: Task.isCancelled) {
      // Enqueues background deliveries and returns at once, so a slow webhook never delays
      // "Meeting saved".
      webhooks.send(session, event: .noteCompleted)
    }
    finalizationTasks.removeValue(forKey: sessionID)
    if finalizationTasks.isEmpty,
       activeSessionID == nil,
       !isStarting,
       !isStopping {
      statusMessage = session.errorMessage == nil
        ? "Meeting saved"
        : "Meeting saved with warnings"
      if let error = session.errorMessage {
        lastError = error
      } else {
        lastError = nil
      }
    }
  }

  func chooseObsidianVault() {
    let panel = NSOpenPanel()
    panel.title = "Choose your Obsidian vault"
    panel.prompt = "Choose Vault"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if let vault = obsidianVaultURL {
      panel.directoryURL = vault
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let root = MeetingVaultIndex.vaultRoot(containing: url)
    cancelContextTasks()
    contextCards.removeAll()
    seenContextTerms.removeAll()
    obsidianVaultPath = root.path
    AppConfig.defaults.set(root.path, forKey: MeetingObsidianPreferences.vaultRootKey)
    if let exportFolder = obsidianExportFolderURL,
       !MeetingObsidianPreferences.contains(exportFolder, in: root) {
      clearObsidianExportFolder()
    }
    contextError = nil
    contextStatus = "Indexing \(root.lastPathComponent)…"
    refreshVaultIndexIfNeeded()
  }

  func clearObsidianVault() {
    obsidianVaultPath = nil
    obsidianExportFolderPath = nil
    AppConfig.defaults.removeObject(forKey: MeetingObsidianPreferences.vaultRootKey)
    AppConfig.defaults.removeObject(forKey: MeetingObsidianPreferences.exportFolderKey)
    MeetingObsidianPreferences.legacyKeys.forEach {
      AppConfig.defaults.removeObject(forKey: $0)
    }
    cancelContextTasks()
    contextCards.removeAll()
    seenContextTerms.removeAll()
    contextStatus = "Choose an Obsidian vault in Settings → Meetings."
  }

  func chooseObsidianExportFolder() {
    guard let vault = obsidianVaultURL else {
      chooseObsidianVault()
      return
    }
    let panel = NSOpenPanel()
    panel.title = "Choose a meeting-summary folder inside your Obsidian vault"
    panel.prompt = "Choose Export Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = obsidianExportFolderURL ?? vault
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard MeetingObsidianPreferences.contains(url, in: vault) else {
      lastError = "The meeting export folder must be inside your Obsidian vault."
      return
    }
    let folder = url.standardizedFileURL
    obsidianExportFolderPath = folder.path
    AppConfig.defaults.set(
      folder.path,
      forKey: MeetingObsidianPreferences.exportFolderKey
    )
    lastError = nil
  }

  func clearObsidianExportFolder() {
    obsidianExportFolderPath = nil
    AppConfig.defaults.removeObject(forKey: MeetingObsidianPreferences.exportFolderKey)
  }

  func addTriggerApplication(_ application: MeetingMicrophoneApplication) {
    guard let rule = MeetingTriggerRule.inferred(
      bundleID: application.bundleID,
      displayName: application.name
    ) else { return }
    updateTriggerRules(triggerRules + [rule])
  }

  func addTriggerBundleID(_ bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let rule = MeetingTriggerRule.inferred(
            bundleID: trimmed,
            displayName: trimmed
          ) else { return }
    updateTriggerRules(triggerRules + [rule])
  }

  func removeTriggerRule(_ rule: MeetingTriggerRule) {
    updateTriggerRules(triggerRules.filter { $0.id != rule.id })
  }

  func restoreDefaultTriggerRules() {
    updateTriggerRules(MeetingTriggerRule.defaultRules)
  }

  func isTriggerApplicationConfigured(
    _ application: MeetingMicrophoneApplication
  ) -> Bool {
    triggerRules.contains { rule in
      rule.captureScope.matches(bundleID: application.bundleID)
    }
  }

  /// iCloud settings sync wrote a newer trigger-app list; adopt it without re-saving a change.
  func reloadTriggerRulesFromDefaults() {
    let rules = MeetingTriggerRule.load(defaults: AppConfig.defaults)
    guard rules != triggerRules else { return }
    updateTriggerRules(rules)
  }

  private func updateTriggerRules(_ rules: [MeetingTriggerRule]) {
    triggerRules = MeetingTriggerRule.deduplicated(rules)
    MeetingTriggerRule.save(triggerRules)
    resetDetectionState()
    refreshDetectorScheduling()
  }

  func exportToObsidian(_ session: MeetingSession) async {
    guard let currentSession = self.session(withID: session.id),
          currentSession.status.isTerminal,
          finalizationTasks[session.id] == nil,
          !noteGenerationSessionIDs.contains(session.id) else {
      lastError = "Wait for the meeting transcript to finish saving before exporting it."
      return
    }
    guard let folder = obsidianExportFolderURL else {
      chooseObsidianVault()
      guard obsidianExportFolderURL != nil else { return }
      await exportToObsidian(currentSession)
      return
    }
    do {
      var updated = currentSession
      let url = try MeetingObsidianExporter.export(session: updated, to: folder)
      updated.exportedMarkdownPath = url.path
      replace(updated)
      await persist(updated)
      MeetingObsidianExporter.open(url)
      statusMessage = "Exported to Obsidian"
    } catch {
      lastError = "Obsidian export failed: \(error.localizedDescription)"
    }
  }

  func regenerateNotes(for session: MeetingSession) async {
    guard let currentSession = self.session(withID: session.id),
          currentSession.status.isTerminal,
          finalizationTasks[session.id] == nil,
          noteGenerationSessionIDs.insert(session.id).inserted else {
      return
    }
    defer { noteGenerationSessionIDs.remove(session.id) }

    let transcript = currentSession.transcriptPlainText
    let manualNotes = currentSession.manualNotesMarkdown?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ) ?? ""
    let titleBeforeGeneration = currentSession.title
    guard !transcript.isEmpty || !manualNotes.isEmpty else {
      lastError = "This meeting has no transcript or manual notes to summarize."
      return
    }

    updateNoteGenerationStatus(
      currentSession.notesMarkdown == nil
        ? "Generating meeting summary…"
        : "Regenerating meeting summary…",
      for: session.id
    )
    do {
      let generated = try await noteGenerator.generate(
        transcript: transcript,
        manualNotes: manualNotes,
        participants: MeetingNoteGenerator.participants(for: currentSession),
        model: noteModel,
        prompt: notePrompt
      )
      guard var updated = self.session(withID: session.id) else { return }
      updated.notesMarkdown = generated.markdown
      // The stall path never reached title generation, so a regenerate is the
      // user's only chance to replace the placeholder title.
      if let generatedTitle = generated.title,
         updated.title == titleBeforeGeneration,
         Self.isGeneratedTitleReplaceable(
           updated.title,
           detectedApp: updated.detectedApp
         ) {
        updated.title = generatedTitle
        generatedTitleEligibleSessionIDs.remove(session.id)
      }
      if updated.errorMessage?.hasPrefix("Meeting notes were not generated:") == true {
        updated.errorMessage = nil
      }
      do {
        try await store.save(updated)
      } catch {
        updateNoteGenerationStatus(
          "Meeting summary could not be saved",
          error: "Meeting summary could not be saved: \(error.localizedDescription)",
          for: session.id
        )
        return
      }
      replace(updated)
      updateNoteGenerationStatus(
        updated.exportedMarkdownPath == nil
          ? "Meeting summary generated"
          : "Meeting summary generated — re-export to update Obsidian",
        for: session.id
      )
    } catch {
      if MeetingNoteRetryPolicy.isCancellation(error) {
        updateNoteGenerationStatus("Meeting summary generation cancelled", for: session.id)
        return
      }
      let message = "Meeting notes were not generated: \(error.localizedDescription)"
      guard var updated = self.session(withID: session.id) else { return }
      if updated.errorMessage == nil
          || updated.errorMessage?.hasPrefix("Meeting notes were not generated:") == true {
        updated.errorMessage = message
        do {
          try await store.save(updated)
          replace(updated)
        } catch {
          updateNoteGenerationStatus(
            "Meeting summary failed and the warning could not be saved",
            error: message,
            for: session.id
          )
          return
        }
      }
      updateNoteGenerationStatus(
        "Meeting summary failed",
        error: message,
        for: session.id
      )
    }
  }

  func restoreDefaultNotePrompt() {
    notePrompt = MeetingNoteGenerator.defaultPrompt
  }

  private func updateNoteGenerationStatus(
    _ status: String,
    error: String? = nil,
    for sessionID: UUID
  ) {
    guard activeSessionID == nil, selectedSession?.id == sessionID else { return }
    statusMessage = status
    lastError = error
  }

  func canSendToWebhooks(_ session: MeetingSession) -> Bool {
    guard let current = self.session(withID: session.id) else { return false }
    return current.status.isTerminal
      && current.id != activeSessionID
      && finalizationTasks[current.id] == nil
      && !noteGenerationSessionIDs.contains(current.id)
  }

  /// Manually sends a finished note to one endpoint, or to every enabled endpoint when
  /// `endpointID` is nil.
  func sendToWebhooks(_ session: MeetingSession, endpointID: UUID? = nil) {
    guard canSendToWebhooks(session), let current = self.session(withID: session.id) else {
      lastError = "Wait for the meeting note to finish before sending it to a webhook."
      return
    }
    let targets = endpointID.map { [$0] }
    let started = webhooks.send(current, event: .noteResent, endpointIDs: targets)
    statusMessage = started == 0 ? "No webhook to send to" : "Sending to webhook"
  }

  /// Retries the send behind a delivery record. A failed part of the newest split send of a
  /// note resends only its missing parts; anything else resends the whole note.
  func retryWebhookDelivery(_ record: MeetingWebhookDeliveryRecord) {
    if record.event == .test {
      webhooks.sendTest(to: record.endpointID)
      return
    }
    guard let current = session(withID: record.noteID) else {
      lastError = "That meeting no longer exists."
      return
    }
    if record.supportsPartialResend,
       webhooks.resumableSend(noteID: record.noteID, endpointID: record.endpointID)?.sendID
         == record.sendKey {
      resendWebhookParts(current, endpointID: record.endpointID, selection: .missing)
      return
    }
    sendToWebhooks(current, endpointID: record.endpointID)
  }

  /// Whether "Resend Missing Parts" / "Resend Parts" can act on this note and endpoint.
  func canResendWebhookParts(_ session: MeetingSession, endpointID: UUID) -> Bool {
    guard canSendToWebhooks(session),
          let send = webhooks.resumableSend(noteID: session.id, endpointID: endpointID) else {
      return false
    }
    return send.splitRecord != nil && !send.isInFlight
  }

  /// Resends the parts typed into "Resend Parts..." (for example `3` or `2,3`).
  func resendWebhookParts(_ session: MeetingSession, endpointID: UUID, partsText: String) {
    guard let send = webhooks.resumableSend(noteID: session.id, endpointID: endpointID) else {
      lastError = "This note has no split send to that webhook to resume; use Send to Webhook."
      return
    }
    guard let parts = MeetingWebhookPartList.parse(partsText, total: send.total) else {
      lastError = "Type part numbers between 1 and \(send.total), for example 3 or 2,3."
      return
    }
    resendWebhookParts(session, endpointID: endpointID, selection: .parts(parts))
  }

  /// Resends some parts of the note's newest split send to one endpoint.
  func resendWebhookParts(
    _ session: MeetingSession,
    endpointID: UUID,
    selection: MeetingWebhookCenter.PartSelection
  ) {
    guard canSendToWebhooks(session), let current = self.session(withID: session.id) else {
      lastError = "Wait for the meeting note to finish before sending it to a webhook."
      return
    }
    switch webhooks.resendParts(current, endpointID: endpointID, selection: selection) {
    case let .started(parts):
      let list = parts.map(String.init).joined(separator: ", ")
      statusMessage = parts.count == 1 ? "Resending part \(list)" : "Resending parts \(list)"
    case let .refused(message):
      lastError = message
    }
  }

  func openExportedNote(_ session: MeetingSession) {
    guard let path = session.exportedMarkdownPath else { return }
    MeetingObsidianExporter.open(URL(fileURLWithPath: path))
  }

  func copyMarkdown(_ session: MeetingSession) {
    guard !noteGenerationSessionIDs.contains(session.id),
          let currentSession = self.session(withID: session.id) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      MeetingObsidianExporter.document(for: currentSession),
      forType: .string
    )
    statusMessage = "Meeting Markdown copied"
  }

  func revealAudio(_ session: MeetingSession) async {
    guard let currentSession = self.session(withID: session.id) else { return }
    do {
      let directory = try await store.directory(for: currentSession.id)
      let audioURLs = currentSession.audioFiles
        .map { directory.appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
      NSWorkspace.shared.activateFileViewerSelecting(
        audioURLs.isEmpty ? [directory] : audioURLs
      )
    } catch {
      lastError = "Could not reveal meeting audio: \(error.localizedDescription)"
    }
  }

  func delete(_ session: MeetingSession) async {
    guard session.id != activeSessionID else { return }
    guard finalizationTasks[session.id] == nil,
          !noteGenerationSessionIDs.contains(session.id) else {
      lastError = "Wait for meeting processing to finish before deleting it."
      return
    }
    do {
      try await store.delete(session)
      sessions.removeAll { $0.id == session.id }
      forcedFullRecoverySources.removeValue(forKey: session.id)
      generatedTitleEligibleSessionIDs.remove(session.id)
      manualNotesDrafts.removeValue(forKey: session.id)
      manualNotesRevisions.removeValue(forKey: session.id)
      selectedSessionID = sessions.first?.id
    } catch {
      lastError = "Could not delete meeting: \(error.localizedDescription)"
    }
  }

  func updateTitle(_ title: String, for sessionID: UUID) {
    guard var session = session(withID: sessionID) else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    session.title = trimmed.isEmpty ? "Meeting" : trimmed
    generatedTitleEligibleSessionIDs.remove(sessionID)
    replace(session)
    schedulePersist(session)
  }

  /// Saves the attendees typed as a comma separated list (trimmed, deduplicated).
  func updateAttendees(_ text: String, for sessionID: UUID) {
    guard var session = session(withID: sessionID) else { return }
    let attendees = MeetingAttendees.parse(text)
    guard attendees != session.attendees else { return }
    session.attendees = attendees
    replace(session)
    schedulePersist(session)
  }

  // MARK: - Speakers

  /// Names a speaker; an empty name restores its default. A name another speaker already
  /// has merges the two.
  func renameSpeaker(_ speaker: MeetingSpeakerKey, to name: String, in sessionID: UUID) {
    editSpeakers(in: sessionID) { session in
      MeetingSpeakerEditor.rename(speaker, to: name, in: &session)
    }
  }

  func mergeSpeaker(
    _ speaker: MeetingSpeakerKey,
    into target: MeetingSpeakerKey,
    in sessionID: UUID
  ) {
    editSpeakers(in: sessionID) { session in
      MeetingSpeakerEditor.merge(speaker, into: target, in: &session)
    }
  }

  func separateSpeakers(mergedInto speaker: MeetingSpeakerKey, in sessionID: UUID) {
    editSpeakers(in: sessionID) { session in
      MeetingSpeakerEditor.separate(speaker, in: &session)
    }
  }

  func acceptSpeakerSuggestion(_ suggestion: MeetingSpeakerSuggestion, in sessionID: UUID) {
    guard let speaker = suggestion.speakerKey else { return }
    renameSpeaker(speaker, to: suggestion.name, in: sessionID)
  }

  func dismissSpeakerSuggestion(_ suggestion: MeetingSpeakerSuggestion, in sessionID: UUID) {
    editSpeakers(in: sessionID) { session in
      session.speakerSuggestions.removeAll { $0.speaker == suggestion.speaker }
    }
  }

  /// Asks the summary model for names for the meeting's unnamed speakers.
  func requestSpeakerNameSuggestions(for sessionID: UUID) async {
    guard let session = session(withID: sessionID), session.status.isTerminal else { return }
    let model = noteModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? "openai/gpt-5.4-nano"
    await suggestSpeakerNames(for: sessionID, model: model)
    guard let updated = self.session(withID: sessionID) else { return }
    if updated.speakerSuggestions.isEmpty, activeSessionID == nil, !isStarting {
      statusMessage = "No speaker names found in the transcript"
    }
  }

  private func editSpeakers(in sessionID: UUID, _ edit: (inout MeetingSession) -> Void) {
    guard var session = session(withID: sessionID) else { return }
    let before = session
    edit(&session)
    guard session != before else { return }
    replace(session)
    schedulePersist(session)
  }

  /// Labels the call's voices with the on-Mac diarizer when the live engine didn't.
  private func runSpeakerPass(for sessionID: UUID) async {
    guard let session = session(withID: sessionID),
          !session.audioFiles.isEmpty,
          MeetingSpeakerPassService.needsPass(session.transcriptTokens) else { return }
    if activeSessionID == nil, !isStarting {
      statusMessage = "Telling speakers apart…"
    }
    do {
      let directory = try await store.directory(for: sessionID)
      guard let relabeled = try await speakerPass.relabel(
        sessionDirectory: directory,
        audioFilenames: session.audioFiles,
        tokens: session.transcriptTokens
      ), var updated = self.session(withID: sessionID) else { return }
      // Only labels change, so tokens that arrived meanwhile (none should) are left alone.
      let labels = Dictionary(
        relabeled.map { ($0.id, $0.speaker) },
        uniquingKeysWith: { first, _ in first }
      )
      updated.transcriptTokens = updated.transcriptTokens.map { token in
        guard token.source == .systemAudio, let label = labels[token.id] else { return token }
        return MeetingTranscriptToken(
          id: token.id,
          source: token.source,
          startTime: token.startTime,
          endTime: token.endTime,
          text: token.text,
          speaker: label
        )
      }
      replace(updated)
      await persist(updated)
    } catch {
      AppLog.dictation.error(
        "MeetingSpeakerPass: failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func suggestSpeakerNames(for sessionID: UUID, model: String) async {
    guard let session = session(withID: sessionID),
          !MeetingSpeakerNameSuggester.candidates(in: session.speakerDirectory).isEmpty,
          speakerSuggestionSessionIDs.insert(sessionID).inserted else { return }
    defer { speakerSuggestionSessionIDs.remove(sessionID) }
    do {
      let suggestions = try await speakerNameSuggester.suggest(for: session, model: model)
      guard var updated = self.session(withID: sessionID) else { return }
      // Re-check against edits made while the model was thinking.
      let candidates = Set(
        MeetingSpeakerNameSuggester.candidates(in: updated.speakerDirectory).map(\.rawValue)
      )
      updated.speakerSuggestions = suggestions.filter { candidates.contains($0.speaker) }
      replace(updated)
      await persist(updated)
    } catch {
      AppLog.dictation.error(
        "MeetingSpeakerNames: suggestion failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// The names cloud recognition is biased towards: the user, then the attendees.
  nonisolated static func participantNames(userName: String?, attendees: [String]) -> [String] {
    var seen: Set<String> = []
    return ([userName].compactMap { $0 } + attendees).compactMap { raw in
      guard let name = MeetingSpeakerDirectory.cleanedName(raw),
            seen.insert(name.lowercased()).inserted else { return nil }
      return name
    }
  }

  func updateManualNotes(_ notes: String, for sessionID: UUID) {
    guard !isStopping,
          sessionID == activeSessionID,
          session(withID: sessionID) != nil else { return }
    let savedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : notes
    manualNotesDrafts[sessionID] = savedNotes
    let revision = (manualNotesRevisions[sessionID] ?? 0) + 1
    manualNotesRevisions[sessionID] = revision
    Task { [weak self] in
      guard let self,
            self.activeSessionID == sessionID,
            self.session(withID: sessionID) != nil,
            self.manualNotesRevisions[sessionID] == revision else { return }
      do {
        try await self.store.saveManualNotes(
          savedNotes.isEmpty ? nil : savedNotes,
          for: sessionID,
          revision: revision
        )
      } catch {
        guard self.session(withID: sessionID) != nil else { return }
        self.lastError = "Manual notes could not be saved: \(error.localizedDescription)"
      }
    }
  }

  func commitManualNotes(for sessionID: UUID) {
    Task { [weak self] in
      await self?.flushManualNotes(for: sessionID)
    }
  }

  private func flushManualNotes(for sessionID: UUID) async -> MeetingSession? {
    guard var session = session(withID: sessionID),
          let draft = manualNotesDrafts.removeValue(forKey: sessionID) else {
      return session(withID: sessionID)
    }
    session.manualNotesMarkdown = draft.isEmpty ? nil : draft
    replace(session)
    let revision = (manualNotesRevisions[sessionID] ?? 0) + 1
    manualNotesRevisions[sessionID] = revision
    do {
      try await store.saveManualNotes(
        session.manualNotesMarkdown,
        for: sessionID,
        revision: revision
      )
    } catch {
      lastError = "Manual notes could not be saved: \(error.localizedDescription)"
    }
    if let latestSession = self.session(withID: sessionID) {
      await persist(latestSession)
      return latestSession
    }
    return session
  }

  private var obsidianVaultURL: URL? {
    guard let obsidianVaultPath, !obsidianVaultPath.isEmpty else { return nil }
    return URL(fileURLWithPath: obsidianVaultPath, isDirectory: true)
  }

  private var obsidianExportFolderURL: URL? {
    guard let path = effectiveObsidianExportFolderPath, !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private func startMeeting(
    title: String?,
    detectedApp: String?,
    automaticallyStarted: Bool,
    candidate: MeetingDetectionCandidate?,
    resuming resumedSession: MeetingSession?
  ) async {
    guard !isLoadingSessions,
          activeSessionID == nil,
          !isStarting,
          !isStopping else { return }
    let activeTranscriptionEngine = transcriptionEngine.normalized
    var missingKey: (error: String, status: String)?
    if activeTranscriptionEngine.usesSoniox, !hasSonioxAPIKey {
      missingKey = (
        error: "Add a Soniox API key in Settings → Transcription before using Soniox for meetings.",
        status: "Soniox API key required"
      )
    } else if activeTranscriptionEngine.usesXAI, !hasXAIAPIKey {
      missingKey = (
        error: "Add an xAI API key in Settings → Transcription before using Grok for meetings.",
        status: "xAI API key required"
      )
    }
    if let missingKey {
      if automaticallyStarted {
        suppressedAutomaticFamily = candidate?.bundleFamily
        suppressedFamilyMissingSince = nil
        resetDetectionState()
      }
      lastError = missingKey.error
      statusMessage = missingKey.status
      return
    }
    isStarting = true
    SystemAudioController.shared.setMeetingCaptureActive(true)
    lastError = nil
    statusMessage = "Starting meeting capture…"

    let defaultTitle = Self.defaultTitle(detectedApp: detectedApp)
    let resumePlan = resumedSession.map(MeetingResumePlan.init)
    let wasInterruptedResume = resumedSession?.status == .interrupted
    var session: MeetingSession
    if var resumedSession {
      if wasInterruptedResume {
        forcedFullRecoverySources[resumedSession.id, default: []]
          .formUnion(MeetingAudioSource.captureSources)
      }
      resumedSession.recordedDuration = resumedSession.duration
      resumedSession.recordingStartedAt = Date()
      resumedSession.endedAt = nil
      resumedSession.transcriptionEngine = activeTranscriptionEngine
      resumedSession.status = .recording
      resumedSession.errorMessage = nil
      // The saved audio keeps the mode it was recorded with (recovery re-reads all of it), so a
      // resume never changes it; meetings from before the gate stay ungated.
      session = resumedSession
      replace(session)
      resumedSessionIDs.insert(session.id)
    } else {
      let startedAt = Date()
      session = MeetingSession(
        title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaultTitle,
        startedAt: startedAt,
        recordedDuration: 0,
        recordingStartedAt: startedAt,
        detectedApp: detectedApp,
        automaticallyStarted: automaticallyStarted,
        transcriptionEngine: activeTranscriptionEngine,
        microphoneGateMode: microphoneGateMode
      )
      sessions.insert(session, at: 0)
    }
    let hasUserProvidedTitle = !automaticallyStarted
      && title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
    if !hasUserProvidedTitle {
      generatedTitleEligibleSessionIDs.insert(session.id)
    }
    cancelContextTasks()
    contextCards.removeAll()
    seenContextTerms.removeAll()
    lastContextAnalysisTokenCount = 0
    lastContextAnalysisAt = nil
    contextError = nil
    contextStatus = liveObsidianContextEnabled
      ? "Preparing Obsidian context…"
      : "Live context is off"
    selectedSessionID = session.id
    automaticCandidate = candidate
    liveTranscriptPreviews.removeAll()
    liveAudioLevels.removeAll()
    overlayMinimizedSessionID = nil
    // A mute still on when an earlier run ended (a crash) ends with that run.
    let earlierMutes = resumePlan.map {
      session.microphoneMutedRanges.ending(by: $0.timelineOffset)
    } ?? session.microphoneMutedRanges
    session.microphoneMutedRanges = earlierMutes
    replace(session)
    let muteRecorder = MeetingMicrophoneMuteRecorder(ranges: earlierMutes)
    microphoneMuteRecorder = muteRecorder
    isMicrophoneMuted = false
    await persist(session)

    do {
      let directory = try await store.directory(for: session.id)
      let sessionID = session.id
      let timelineOffset = resumePlan?.timelineOffset ?? 0
      let transcriber = MeetingTranscriptionService(
        engine: activeTranscriptionEngine,
        timelineOffset: timelineOffset,
        participantNames: Self.participantNames(
          userName: MeetingSpeakerDirectory.currentUserName(),
          attendees: session.attendees
        ),
        microphoneGateMode: session.microphoneGateMode ?? .off,
        microphoneMuteRecorder: muteRecorder,
        tokenHandler: { [weak self] tokens in
          await self?.receive(tokens: tokens, for: sessionID)
        },
        previewHandler: { [weak self] source, text in
          await self?.receivePreview(text, source: source, for: sessionID)
        },
        correctionHandler: { [weak self] corrections in
          await self?.receive(corrections: corrections, for: sessionID)
        }
      )
      self.transcriber = transcriber
      let task = Task {
        try await transcriber.prepare()
      }
      preparationTask = task

      // Keep live work close to real time. If this buffer ever fills, raw CAF capture
      // continues and final transcription is recovered locally rather than ending the meeting.
      let backlogGate = MeetingIngestionBacklogGate()
      ingestionBacklogGate = backlogGate
      let (audioStream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream(
        bufferingPolicy: .bufferingNewest(
          MeetingIngestionBacklogPolicy.maximumBufferedChunks
        )
      )
      audioContinuation = continuation
      ingestionTask = Task.detached(priority: .userInitiated) { [weak self] in
        for await chunk in audioStream {
          guard !Task.isCancelled else { break }
          do {
            try await transcriber.ingest(chunk)
          } catch {
            await self?.recordIngestionWarning(error, for: sessionID)
          }
        }
      }

      let audioLevelGate = self.audioLevelGate
      try await capture.start(
        directory: directory,
        includedApplicationScope: automaticallyStarted ? candidate?.captureScope : nil,
        initialSegmentIndexes: resumePlan?.initialSegmentIndexes ?? [:],
        timelineOffset: timelineOffset,
        onChunk: { [weak self] chunk in
          let timelineChunk = MeetingAudioChunk(
            source: chunk.source,
            samples: chunk.samples,
            startTime: timelineOffset + chunk.startTime,
            duration: chunk.duration
          )
          if chunk.source == .microphone {
            muteRecorder.observe(
              start: timelineChunk.startTime,
              end: timelineChunk.startTime + timelineChunk.duration
            )
          }
          if audioLevelGate.isEnabled {
            let level = MeetingAudioMeter.level(from: chunk.samples)
            Task { @MainActor [weak self] in
              self?.receiveAudioLevel(
                level,
                source: chunk.source,
                for: sessionID
              )
            }
          }
          if case .dropped = continuation.yield(timelineChunk),
             backlogGate.claim() {
            continuation.finish()
            Task { @MainActor [weak self] in
              guard let self else { return }
              self.pauseLiveTranscriptionForBacklog(
                sessionID: sessionID,
                recoverySources: MeetingIngestionBacklogPolicy.recoverySources
              )
            }
          }
        },
        onError: { [weak self] error in
          Task { @MainActor [weak self] in
            self?.handleCaptureError(error)
          }
        }
      )
      activeSessionID = session.id
      refreshVaultIndexIfNeeded()
      statusMessage = "Recording meeting • \(activeTranscriptionEngine.recordingLabel)"
      isStarting = false
      scheduleNextDetectorPoll()
      preparationMonitorTask = Task { @MainActor [weak self] in
        do {
          try await task.value
        } catch is CancellationError {
          return
        } catch {
          guard let self, activeSessionID == sessionID else { return }
          lastError = "Live transcription unavailable: \(error.localizedDescription)"
          statusMessage = "Recording audio • transcription unavailable"
        }
      }
    } catch {
      audioContinuation?.finish()
      audioContinuation = nil
      ingestionBacklogGate = nil
      ingestionTask?.cancel()
      if let ingestionTask {
        await ingestionTask.value
      }
      self.ingestionTask = nil
      preparationTask?.cancel()
      if let preparationTask {
        _ = try? await preparationTask.value
      }
      preparationTask = nil
      preparationMonitorTask?.cancel()
      if let transcriber = self.transcriber {
        await transcriber.cleanup()
      }
      session.status = wasInterruptedResume ? .interrupted : .failed
      let endedAt = Date()
      if let recordingStartedAt = session.recordingStartedAt {
        session.recordedDuration = (session.recordedDuration ?? 0)
          + max(0, endedAt.timeIntervalSince(recordingStartedAt))
      }
      session.recordingStartedAt = nil
      session.endedAt = endedAt
      session.errorMessage = error.localizedDescription
      resumedSessionIDs.remove(session.id)
      if !wasInterruptedResume {
        forcedFullRecoverySources.removeValue(forKey: session.id)
      }
      generatedTitleEligibleSessionIDs.remove(session.id)
      replace(session)
      await persist(session)
      activeSessionID = nil
      transcriber = nil
      microphoneMuteRecorder = nil
      isMicrophoneMuted = false
      preparationTask = nil
      preparationMonitorTask = nil
      automaticCandidate = nil
      if automaticallyStarted {
        suppressedAutomaticFamily = candidate?.bundleFamily
        suppressedFamilyMissingSince = nil
      }
      liveTranscriptPreviews.removeAll()
      liveAudioLevels.removeAll()
      overlayMinimizedSessionID = nil
      SystemAudioController.shared.setMeetingCaptureActive(false)
      isStarting = false
      scheduleNextDetectorPoll()
      lastError = "Meeting capture could not start: \(error.localizedDescription)"
      statusMessage = "Meeting capture failed"
    }
  }

  private func receive(tokens: [MeetingTranscriptToken], for sessionID: UUID) {
    guard var session = session(withID: sessionID),
          !tokens.isEmpty else { return }
    let incoming = MeetingTranscriptFormatter.chronologicalTokens(tokens)
    let existingLastStartTime = session.transcriptTokens.last?.startTime
    session.transcriptTokens.append(contentsOf: incoming)
    if let existingLastStartTime,
       let incomingFirstStartTime = incoming.first?.startTime,
       incomingFirstStartTime < existingLastStartTime {
      session.transcriptTokens = MeetingTranscriptFormatter.chronologicalTokens(
        session.transcriptTokens
      )
    }
    replace(session)
    schedulePersist(session)
    if activeSessionID == sessionID {
      discoverContext(in: session)
    }
  }

  /// Apply Parakeet vocabulary corrections to tokens already received live.
  private func receive(corrections: [MeetingTokenCorrection], for sessionID: UUID) {
    guard var session = session(withID: sessionID), !corrections.isEmpty else { return }
    let corrected = MeetingVocabularyCorrector.apply(corrections, to: session.transcriptTokens)
    guard corrected != session.transcriptTokens else { return }
    session.transcriptTokens = corrected
    replace(session)
    schedulePersist(session)
  }

  private func receivePreview(
    _ text: String,
    source: MeetingAudioSource,
    for sessionID: UUID
  ) {
    guard activeSessionID == sessionID else { return }
    if text.isEmpty {
      liveTranscriptPreviews.removeValue(forKey: source)
    } else {
      liveTranscriptPreviews[source] = text
    }
  }

  private func receiveAudioLevel(
    _ level: Float,
    source: MeetingAudioSource,
    for sessionID: UUID
  ) {
    guard activeSessionID == sessionID,
          overlayMinimizedSessionID == sessionID else { return }
    liveAudioLevels[source] = min(max(level, 0), 1)
  }

  private func discoverContext(in session: MeetingSession) {
    guard liveObsidianContextEnabled,
          let folder = obsidianVaultURL,
          let sessionID = activeSessionID else { return }
    let text = session.transcriptTokens.suffix(40).map(\.text).joined()
    guard !text.isEmpty else { return }
    for term in MeetingVaultIndex.extractIdentifiers(from: text) {
      surfaceContext(term: term, transcript: text, folder: folder, sessionID: sessionID)
    }
    scheduleTopicAnalysisIfNeeded(for: sessionID)
  }

  private func scheduleTopicAnalysisIfNeeded(for sessionID: UUID) {
    guard liveObsidianContextEnabled,
          activeSessionID == sessionID,
          contextAnalysisTask == nil,
          let session = session(withID: sessionID),
          session.transcriptTokens.count - lastContextAnalysisTokenCount
            >= (lastContextAnalysisAt == nil ? 24 : 80) else {
      return
    }
    let delay = lastContextAnalysisAt.map {
      max(0, 30 - Date().timeIntervalSince($0))
    } ?? 30
    let analysisID = UUID()
    contextAnalysisID = analysisID
    contextAnalysisTask = Task { [weak self] in
      do {
        try await Task.sleep(
          nanoseconds: UInt64(delay * 1_000_000_000)
        )
      } catch {
        return
      }
      await self?.analyzeLatestContext(
        for: sessionID,
        analysisID: analysisID
      )
    }
  }

  private func analyzeLatestContext(
    for sessionID: UUID,
    analysisID: UUID
  ) async {
    defer {
      if contextAnalysisID == analysisID {
        contextAnalysisTask = nil
        contextAnalysisID = nil
        scheduleTopicAnalysisIfNeeded(for: sessionID)
      }
    }
    guard liveObsidianContextEnabled,
          let folder = obsidianVaultURL,
          let session = session(withID: sessionID),
          activeSessionID == sessionID else { return }

    let recentTokens = MeetingTranscriptFormatter.recentTokens(
      session.transcriptTokens,
      duration: 30
    )
    let transcript = MeetingTranscriptFormatter.plainText(
      tokens: recentTokens,
      speakers: session.speakerDirectory
    )
    guard transcript.count >= 40 else { return }
    lastContextAnalysisTokenCount = session.transcriptTokens.count
    lastContextAnalysisAt = Date()
    isContextSearching = true
    contextStatus = "Analyzing the conversation…"

    let model = contextModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty ?? "openai/gpt-5.4-nano"
    let topics: [String]
    do {
      topics = try await contextSummarizer.extractTopics(
        transcript: transcript,
        model: model
      )
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }
      contextError = nil
    } catch {
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }
      topics = []
      contextError = "Topic extraction failed: \(error.localizedDescription)"
      AppLog.dictation.error(
        "MeetingContext: topic extraction failed: \(error.localizedDescription, privacy: .public)"
      )
    }

    await surfaceTopics(
      topics,
      transcript: transcript,
      folder: folder,
      sessionID: sessionID,
      model: model
    )
    guard !Task.isCancelled,
          liveObsidianContextEnabled,
          activeSessionID == sessionID else { return }
    isContextSearching = false
    if topics.isEmpty {
      contextStatus = "Listening for a specific subject…"
    } else if contextCards.isEmpty {
      contextStatus = "No relevant Obsidian notes found yet."
    } else {
      contextStatus = "Context updated"
    }
  }

  private func surfaceTopics(
    _ topics: [String],
    transcript: String,
    folder: URL,
    sessionID: UUID,
    model: String
  ) async {
    var found: [(
      id: UUID,
      term: String,
      matches: [MeetingContextMatch],
      externalURL: URL?
    )] = []

    for term in topics {
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }
      let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedTerm.isEmpty,
            seenContextTerms.insert(normalizedTerm.lowercased()).inserted else { continue }

      let matches: [MeetingContextMatch]
      do {
        matches = try await vaultIndex.search(query: normalizedTerm, from: folder)
      } catch {
        guard !Task.isCancelled,
              liveObsidianContextEnabled,
              activeSessionID == sessionID else { return }
        seenContextTerms.remove(normalizedTerm.lowercased())
        contextError = error.localizedDescription
        contextStatus = "Could not search the Obsidian vault."
        continue
      }
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }

      let externalURL = MeetingTicketLink.url(for: normalizedTerm)
      guard externalURL != nil || !matches.isEmpty else { continue }
      let cardID = UUID()
      insertContextCard(
        MeetingContextCard(
          id: cardID,
          term: normalizedTerm,
          summary: matches.first.map { String($0.excerpt.prefix(420)) }
            ?? "Open the referenced ticket for live details.",
          matches: matches,
          externalURL: externalURL
        )
      )
      found.append((cardID, normalizedTerm, matches, externalURL))
    }

    let summarizable = found.filter { !$0.matches.isEmpty }
    guard !summarizable.isEmpty,
          !Task.isCancelled,
          liveObsidianContextEnabled,
          activeSessionID == sessionID else { return }
    do {
      let summaries = try await contextSummarizer.summarizeBatch(
        topics: summarizable.map { ($0.term, $0.matches) },
        transcript: transcript,
        model: model
      )
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }
      for (index, item) in summarizable.enumerated() {
        guard summaries.indices.contains(index), let summary = summaries[index] else { continue }
        replaceContextCard(
          MeetingContextCard(
            id: item.id,
            term: item.term,
            summary: summary,
            matches: item.matches,
            externalURL: item.externalURL
          )
        )
      }
    } catch {
      guard !Task.isCancelled,
            liveObsidianContextEnabled,
            activeSessionID == sessionID else { return }
      contextError = "Could not summarize live context: \(error.localizedDescription)"
      AppLog.dictation.error(
        "MeetingContext: batch summary failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func surfaceContext(
    term: String,
    transcript: String,
    folder: URL,
    sessionID: UUID
  ) {
    let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard liveObsidianContextEnabled,
          activeSessionID == sessionID,
          !normalizedTerm.isEmpty,
          seenContextTerms.insert(normalizedTerm.lowercased()).inserted else { return }

    let model = contextModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty ?? "openai/gpt-5.4-nano"
    let taskID = UUID()
    contextTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      defer { self.contextTasks[taskID] = nil }
      let matches: [MeetingContextMatch]
      do {
        matches = try await vaultIndex.search(query: normalizedTerm, from: folder)
      } catch {
        self.seenContextTerms.remove(normalizedTerm.lowercased())
        guard !Task.isCancelled, self.liveObsidianContextEnabled else { return }
        self.contextError = error.localizedDescription
        self.contextStatus = "Could not search the Obsidian vault."
        return
      }
      let externalURL = MeetingTicketLink.url(for: normalizedTerm)
      guard !Task.isCancelled,
            self.liveObsidianContextEnabled,
            self.activeSessionID == sessionID else { return }
      guard externalURL != nil || !matches.isEmpty else {
        if self.contextCards.isEmpty {
          self.contextStatus = "No relevant Obsidian notes found yet."
        }
        return
      }

      let cardID = UUID()
      let immediateSummary = matches.first.map {
        String($0.excerpt.prefix(420))
      } ?? "Open the referenced ticket for live details."
      let initialCard = MeetingContextCard(
        id: cardID,
        term: normalizedTerm,
        summary: immediateSummary,
        matches: matches,
        externalURL: externalURL
      )
      self.insertContextCard(initialCard)
      self.contextStatus = "Context updated"

      guard !matches.isEmpty else { return }
      do {
        let summary = try await contextSummarizer.summarize(
          term: normalizedTerm,
          matches: matches,
          transcript: transcript,
          model: model
        )
        guard !Task.isCancelled,
              self.liveObsidianContextEnabled,
              self.activeSessionID == sessionID else { return }
        self.replaceContextCard(
          MeetingContextCard(
            id: cardID,
            term: normalizedTerm,
            summary: summary,
            matches: matches,
            externalURL: externalURL
          )
        )
      } catch {
        guard !Task.isCancelled,
              self.liveObsidianContextEnabled,
              self.activeSessionID == sessionID else { return }
        self.contextError = "Could not summarize \(normalizedTerm): \(error.localizedDescription)"
        let details = "\(normalizedTerm): \(error.localizedDescription)"
        AppLog.dictation.error(
          "MeetingContext: summary failed: \(details, privacy: .public)"
        )
      }
    }
  }

  private func replaceContextCard(_ card: MeetingContextCard) {
    guard let index = contextCards.firstIndex(where: { $0.id == card.id }) else { return }
    contextCards[index] = card
  }

  private func insertContextCard(_ card: MeetingContextCard) {
    contextCards.insert(card, at: 0)
    if contextCards.count > 10 {
      contextCards.removeLast(contextCards.count - 10)
    }
  }

  private func refreshVaultIndexIfNeeded() {
    guard liveObsidianContextEnabled else {
      contextStatus = "Live context is off"
      return
    }
    guard let folder = obsidianVaultURL else {
      contextStatus = "Choose an Obsidian vault in Settings → Meetings."
      return
    }
    isContextSearching = true
    contextStatus = "Indexing \(MeetingVaultIndex.vaultRoot(containing: folder).lastPathComponent)…"
    let taskID = UUID()
    contextTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      defer { self.contextTasks[taskID] = nil }
      do {
        let count = try await vaultIndex.refresh(from: folder)
        guard !Task.isCancelled,
              self.liveObsidianContextEnabled,
              self.obsidianVaultURL == folder else { return }
        self.contextError = nil
        self.isContextSearching = false
        self.contextStatus = "Listening for useful topics across \(count) notes…"
      } catch {
        guard !Task.isCancelled,
              self.liveObsidianContextEnabled,
              self.obsidianVaultURL == folder else { return }
        self.contextError = error.localizedDescription
        self.isContextSearching = false
        self.contextStatus = "Could not index the Obsidian vault."
        AppLog.dictation.error(
          "MeetingContext: vault indexing failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func cancelContextTasks() {
    contextAnalysisTask?.cancel()
    contextAnalysisTask = nil
    contextAnalysisID = nil
    contextTasks.values.forEach { $0.cancel() }
    contextTasks.removeAll()
    isContextSearching = false
  }

  private func handleCaptureError(_ error: Error) {
    guard !isStopping,
          let activeSessionID,
          var session = session(withID: activeSessionID) else { return }
    let message = "Meeting capture stopped: \(error.localizedDescription)"
    lastError = message
    session.errorMessage = message
    replace(session)
    schedulePersist(session)
    Task { [weak self] in
      await self?.stopMeeting()
    }
  }

  private func recordIngestionWarning(_ error: Error, for sessionID: UUID) {
    let message = "Live transcription warning: \(error.localizedDescription)"
    if var session = session(withID: sessionID), session.errorMessage == nil {
      session.errorMessage = message
      replace(session)
      schedulePersist(session)
    }
    guard activeSessionID == sessionID else { return }
    lastError = message
    statusMessage = "Recording audio • transcription warning"
  }

  private func pauseLiveTranscriptionForBacklog(
    sessionID: UUID,
    recoverySources: Set<MeetingAudioSource>
  ) {
    guard !isStopping, activeSessionID == sessionID else { return }
    forcedFullRecoverySources[sessionID, default: []].formUnion(recoverySources)
    audioContinuation?.finish()
    audioContinuation = nil

    let stalledIngestionTask = ingestionTask
    let stalledPreparationTask = preparationTask
    let stalledTranscriber = transcriber
    ingestionTask = nil
    preparationTask = nil
    transcriber = nil
    preparationMonitorTask?.cancel()
    preparationMonitorTask = nil
    stalledIngestionTask?.cancel()
    stalledPreparationTask?.cancel()

    let message = "Live transcription warning: "
      + MeetingIngestionBacklogPolicy.warningMessage
    if var session = session(withID: sessionID), session.errorMessage == nil {
      session.errorMessage = message
      replace(session)
      schedulePersist(session)
    }
    lastError = message
    statusMessage = "Recording audio • live transcript paused"
    AppLog.dictation.error(
      "MeetingTranscription: backlog paused live transcription; raw capture continues"
    )

    transcriptionCleanupTasks[sessionID]?.cancel()
    transcriptionCleanupTasks[sessionID] = Task { @MainActor [weak self] in
      await stalledIngestionTask?.value
      _ = try? await stalledPreparationTask?.value
      await stalledTranscriber?.cleanup()
      self?.transcriptionCleanupTasks.removeValue(forKey: sessionID)
    }
  }

  private func schedulePersist(_ session: MeetingSession) {
    dirtySessionIDs.insert(session.id)
    guard persistTask == nil else { return }
    persistTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
          break
        }
        let pendingIDs = self.dirtySessionIDs
        self.dirtySessionIDs.removeAll()
        for sessionID in pendingIDs {
          if let latestSession = self.session(withID: sessionID) {
            await self.persist(latestSession)
          }
        }
        if self.dirtySessionIDs.isEmpty {
          self.persistTask = nil
          return
        }
      }
      self.persistTask = nil
    }
  }

  /// Saves the session, reporting failures through `lastError`. Returns whether it was saved.
  @discardableResult
  private func persist(_ session: MeetingSession) async -> Bool {
    do {
      try await store.save(session)
      return true
    } catch {
      lastError = "Meeting could not be saved: \(error.localizedDescription)"
      return false
    }
  }

  /// The completed-note webhook only goes out for a note that is actually on disk, and never
  /// from a cancelled finalization.
  nonisolated static func shouldSendCompletedWebhook(persisted: Bool, isCancelled: Bool) -> Bool {
    persisted && !isCancelled
  }

  private func replace(_ session: MeetingSession) {
    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[index] = session
    } else {
      sessions.insert(session, at: 0)
    }
  }

  private func session(withID id: UUID) -> MeetingSession? {
    sessions.first(where: { $0.id == id })
  }

  private func pollMeetingDetector() async {
    guard !isLoadingSessions,
          automaticDetectionEnabled,
          !isStarting,
          !isStopping else {
      scheduleNextDetectorPoll()
      return
    }

    if let activeSession {
      guard activeSession.automaticallyStarted else {
        scheduleNextDetectorPoll()
        return
      }
      let now = Date()
      if let lastActiveMeetingPollAt,
         now.timeIntervalSince(lastActiveMeetingPollAt)
           < MeetingDetectionPolicy.activeMeetingPollInterval {
        let elapsed = now.timeIntervalSince(lastActiveMeetingPollAt)
        scheduleNextDetectorPoll(
          after: MeetingDetectionPolicy.activeMeetingPollInterval - elapsed
        )
        return
      }
      lastActiveMeetingPollAt = now
    } else {
      lastActiveMeetingPollAt = nil
      refreshLiveMicrophoneApplications()
    }
    defer {
      scheduleNextDetectorPoll()
      scheduleDetectorConfirmationIfNeeded()
    }

    let detected = detector.currentCandidate(triggerRules: triggerRules)
    if let detected {
      lastDetectedFamily = detected.bundleFamily
      lastDetectedAt = Date()
    }

    if let suppressedAutomaticFamily {
      let now = Date()
      let observedFamily: String? = if let detected {
        detected.bundleFamily
      } else if detector.isMeetingStillActive(family: suppressedAutomaticFamily) {
        suppressedAutomaticFamily
      } else {
        nil
      }
      if observedFamily == nil, suppressedFamilyMissingSince == nil {
        suppressedFamilyMissingSince = now
      } else if observedFamily != nil {
        suppressedFamilyMissingSince = nil
      }
      let absentDuration = suppressedFamilyMissingSince.map {
        now.timeIntervalSince($0)
      } ?? 0
      if MeetingDetectionPolicy.releasesSuppression(
        detectedFamily: observedFamily,
        suppressedFamily: suppressedAutomaticFamily,
        absentDuration: absentDuration
      ) {
        self.suppressedAutomaticFamily = nil
        suppressedFamilyMissingSince = nil
      } else {
        resetDetectionState()
        statusMessage = "Waiting for the current call to end"
        return
      }
    }

    if let active = activeSession, active.automaticallyStarted {
      let likelyStillActive = automaticCandidate.map { activeCandidate in
        detected?.triggerID == activeCandidate.triggerID
          || detector.isMeetingStillActive(candidate: activeCandidate)
      } ?? false
      if likelyStillActive {
        candidateMissingSince = nil
      } else if candidateMissingSince == nil {
        candidateMissingSince = Date()
      } else if let missingSince = candidateMissingSince,
                MeetingDetectionPolicy.confirmsMeetingEnded(
                  likelyStillActive: false,
                  absentDuration: Date().timeIntervalSince(missingSince)
                ) {
        AppLog.dictation.log(
          "MeetingDetector: auto-stop confirmed after stable call absence"
        )
        await stopMeeting(suppressCurrentAutomaticCall: false)
      }
      return
    }

    guard activeSessionID == nil else { return }
    guard let detected else {
      resetDetectionState()
      return
    }

    if candidate?.triggerID != detected.triggerID {
      cancelDetectorConfirmation()
      candidate = detected
      candidateDetectedAt = Date()
      statusMessage = "Possible \(detected.appName) detected…"
      return
    }

    candidate = detected
    let latency = candidateDetectedAt.map { Date().timeIntervalSince($0) } ?? 0
    guard MeetingDetectionPolicy.confirmsAutomaticStart(
      stableDuration: latency
    ) else { return }
    AppLog.dictation.log(
      "MeetingDetector: auto-start confirmed after \(latency, format: .fixed(precision: 2))s"
    )
    resetDetectionState()
    await startMeeting(
      title: detected.appName,
      detectedApp: detected.appName,
      automaticallyStarted: true,
      candidate: detected,
      resuming: nil
    )
  }

  private func handleDetectorEvent() {
    guard automaticDetectionEnabled else { return }
    detectorEventPending = true
    guard detectorEventTask == nil else { return }
    detectorEventTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { detectorEventTask = nil }
      repeat {
        detectorEventPending = false
        await pollMeetingDetector()
      } while detectorEventPending && automaticDetectionEnabled
    }
  }

  private func scheduleDetectorConfirmationIfNeeded() {
    guard let candidate,
          let candidateDetectedAt,
          activeSessionID == nil,
          detectorConfirmationTask == nil else { return }
    let elapsed = Date().timeIntervalSince(candidateDetectedAt)
    let delay = max(0, MeetingDetectionPolicy.eventConfirmationDelay - elapsed)
    let triggerID = candidate.triggerID
    detectorConfirmationTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(
          nanoseconds: UInt64(delay * 1_000_000_000)
        )
      } catch {
        return
      }
      guard let self,
            self.candidate?.triggerID == triggerID,
            self.candidateDetectedAt == candidateDetectedAt else { return }
      self.detectorConfirmationTask = nil
      await self.pollMeetingDetector()
    }
  }

  private func cancelDetectorConfirmation() {
    detectorConfirmationTask?.cancel()
    detectorConfirmationTask = nil
  }

  private func refreshDetectorScheduling() {
    detectorTimerGeneration &+= 1
    detectorTimer?.invalidate()
    detectorTimer = nil
    guard MeetingDetectionPolicy.schedulingAllowed else { return }
    if automaticDetectionEnabled, !isLoadingSessions {
      handleDetectorEvent()
    } else if !automaticDetectionEnabled {
      detectorEventPending = false
      cancelDetectorConfirmation()
      liveMicrophoneApplications = []
    }
  }

  private func scheduleNextDetectorPoll(after overrideInterval: TimeInterval? = nil) {
    detectorTimerGeneration &+= 1
    let generation = detectorTimerGeneration
    detectorTimer?.invalidate()
    detectorTimer = nil
    guard MeetingDetectionPolicy.schedulingAllowed else { return }

    let interval = overrideInterval ?? MeetingDetectionPolicy.nextPollInterval(
      automaticDetectionEnabled: automaticDetectionEnabled,
      activeMeetingIsAutomatic: activeSession?.automaticallyStarted,
      hasSuspiciousSignal: candidate != nil || suppressedAutomaticFamily != nil
    )
    guard let interval else { return }

    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
              self.detectorTimerGeneration == generation else { return }
        self.detectorTimer = nil
        await self.pollMeetingDetector()
      }
    }
    timer.tolerance = min(10, interval * 0.1)
    RunLoop.main.add(timer, forMode: .common)
    detectorTimer = timer
  }

  private func resetDetectionState() {
    cancelDetectorConfirmation()
    candidate = nil
    candidateDetectedAt = nil
    candidateMissingSince = nil
    if activeSessionID == nil {
      statusMessage = automaticDetectionEnabled ? "Watching for meetings" : "Ready"
    }
  }

  private static func defaultTitle(detectedApp: String?) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, d MMM • h:mm a"
    if let detectedApp {
      return "\(detectedApp) — \(formatter.string(from: Date()))"
    }
    return "Meeting — \(formatter.string(from: Date()))"
  }

  /// True when a title is still a placeholder and may be replaced by a generated one.
  ///
  /// Covers the dated defaults from `defaultTitle(detectedApp:)` plus the bare
  /// detector name (for example "Google Meet") used when a meeting starts
  /// automatically. A user-edited title never matches, so it is preserved.
  nonisolated static func isGeneratedTitleReplaceable(
    _ title: String,
    detectedApp: String?
  ) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    if trimmed == "Meeting" { return true }
    if let detectedApp,
       trimmed.caseInsensitiveCompare(detectedApp) == .orderedSame {
      return true
    }
    // Dated defaults: "<app> — Mon, 27 Jul • 5:49 pm" or "Meeting — ...".
    guard let separator = trimmed.range(of: " — ") else { return false }
    let prefix = String(trimmed[trimmed.startIndex..<separator.lowerBound])
    if prefix == "Meeting" { return true }
    if let detectedApp {
      return prefix.caseInsensitiveCompare(detectedApp) == .orderedSame
    }
    return false
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
