import Foundation
import AppKit

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

enum MeetingPreferences {
  static func automaticDetectionEnabled(
    defaults: UserDefaults = .standard
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

  static func vaultRootPath(defaults: UserDefaults = .standard) -> String? {
    migrateIfNeeded(defaults: defaults)
    return defaults.string(forKey: vaultRootKey)?.nonEmpty
  }

  static func exportFolderPath(defaults: UserDefaults = .standard) -> String? {
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
  static let pollInterval: TimeInterval = 1
  static let requiredConsecutiveMatches = 2
  static let endConfirmationDelay: TimeInterval = 120
  static let suppressionReleaseDelay: TimeInterval = 120

  static var maximumConfirmationDelay: TimeInterval {
    pollInterval * Double(requiredConsecutiveMatches)
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
  @Published private(set) var contextCards: [MeetingContextCard] = []
  @Published private(set) var contextStatus = "Listening for useful topics…"
  @Published private(set) var contextError: String?
  @Published private(set) var isContextSearching = false
  @Published private(set) var liveTranscriptPreviews: [MeetingAudioSource: String] = [:]
  @Published private(set) var liveAudioLevels: [MeetingAudioSource: Float] = [:]
  @Published private(set) var triggerRules: [MeetingTriggerRule] = MeetingTriggerRule.load()
  @Published private(set) var liveMicrophoneApplications: [MeetingMicrophoneApplication] = []
  @Published private(set) var overlayMinimizedSessionID: UUID?

  @Published var liveObsidianContextEnabled: Bool = {
    UserDefaults.standard.bool(forKey: "meeting.context.enabled")
  }() {
    didSet {
      UserDefaults.standard.set(liveObsidianContextEnabled, forKey: "meeting.context.enabled")
      if liveObsidianContextEnabled {
        contextError = nil
        contextStatus = obsidianVaultPath == nil
          ? "Choose an Obsidian vault in Meetings."
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
    if UserDefaults.standard.object(forKey: "meeting.overlay.enabled") == nil {
      return true
    }
    return UserDefaults.standard.bool(forKey: "meeting.overlay.enabled")
  }() {
    didSet {
      UserDefaults.standard.set(meetingOverlayEnabled, forKey: "meeting.overlay.enabled")
      if meetingOverlayEnabled {
        overlayMinimizedSessionID = nil
      }
    }
  }

  @Published var automaticDetectionEnabled: Bool = {
    MeetingPreferences.automaticDetectionEnabled()
  }() {
    didSet {
      UserDefaults.standard.set(
        automaticDetectionEnabled,
        forKey: "meeting.autoDetection.enabled"
      )
      suppressedAutomaticFamily = nil
      suppressedFamilyMissingSince = nil
      resetDetectionState()
    }
  }

  @Published var automaticallyExportToObsidian: Bool = {
    if UserDefaults.standard.object(forKey: "meeting.obsidian.autoExport") == nil {
      return true
    }
    return UserDefaults.standard.bool(forKey: "meeting.obsidian.autoExport")
  }() {
    didSet {
      UserDefaults.standard.set(
        automaticallyExportToObsidian,
        forKey: "meeting.obsidian.autoExport"
      )
    }
  }

  @Published var generateMeetingNotes: Bool = {
    if UserDefaults.standard.object(forKey: "meeting.notes.generate") == nil {
      return false
    }
    return UserDefaults.standard.bool(forKey: "meeting.notes.generate")
  }() {
    didSet {
      UserDefaults.standard.set(generateMeetingNotes, forKey: "meeting.notes.generate")
    }
  }

  @Published var noteModel: String = {
    UserDefaults.standard.string(forKey: "meeting.notes.model")
      ?? "openai/gpt-5.4-nano"
  }() {
    didSet {
      UserDefaults.standard.set(noteModel, forKey: "meeting.notes.model")
    }
  }

  @Published var contextModel: String = {
    UserDefaults.standard.string(forKey: "meeting.context.model")
      ?? "openai/gpt-5.4-nano"
  }() {
    didSet {
      UserDefaults.standard.set(contextModel, forKey: "meeting.context.model")
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
      UserDefaults.standard.set(
        transcriptionEngine.rawValue,
        forKey: "meeting.transcription.engine"
      )
    }
  }

  private let store = MeetingSessionStore()
  private let capture = MeetingCaptureService()
  private let detector = MeetingDetector()
  private let noteGenerator = MeetingNoteGenerator()
  private let vaultIndex = MeetingVaultIndex()
  private let contextSummarizer = MeetingContextSummarizer()
  private let transcriptRecovery = MeetingTranscriptRecoveryService()

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
  private var candidate: MeetingDetectionCandidate?
  private var candidateMatchCount = 0
  private var candidateDetectedAt: Date?
  private var automaticCandidate: MeetingDetectionCandidate?
  private var candidateMissingSince: Date?
  private var suppressedAutomaticFamily: String?
  private var suppressedFamilyMissingSince: Date?
  private var lastDetectedFamily: String?
  private var lastDetectedAt: Date?
  private var seenContextTerms: Set<String> = []
  private var generatedTitleEligibleSessionIDs: Set<UUID> = []
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

  init() {
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
      let timer = Timer(timeInterval: MeetingDetectionPolicy.pollInterval, repeats: true) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.pollMeetingDetector()
        }
      }
      timer.tolerance = 0.1
      RunLoop.main.add(timer, forMode: .common)
      detectorTimer = timer
    }
    statusMessage = automaticDetectionEnabled ? "Watching for meetings" : "Ready"
  }

  deinit {
    SystemAudioController.shared.setMeetingCaptureActive(false)
    detectorTimer?.invalidate()
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
      candidate: nil
    )
  }

  func minimizeMeetingOverlayForCurrentSession() {
    guard let activeSessionID else { return }
    overlayMinimizedSessionID = activeSessionID
    commitManualNotes(for: activeSessionID)
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
    session.audioFiles = audioFiles
    session.endedAt = Date()
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
    statusMessage = "Meeting stopped • finishing transcript…"

    let sessionID = session.id
    let shouldGenerateNotes = generateMeetingNotes
    let selectedNoteModel = noteModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty ?? "openai/gpt-5.4-nano"
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
  }

  private func finalizeMeeting(
    sessionID: UUID,
    transcriber: MeetingTranscriptionService?,
    preparationTask: Task<Void, Error>?,
    ingestionTask: Task<Void, Never>?,
    transcriptionCleanupTask: Task<Void, Never>?,
    generateNotes: Bool,
    noteModel: String,
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
        try await transcriber.finish()
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
        let result = try await transcriptRecovery.recover(
          sessionDirectory: directory,
          audioFilenames: interruptedSession.audioFiles,
          existingTokens: interruptedSession.transcriptTokens,
          sourcesNeedingRecovery: recoverySources,
          fullRecoverySources: fullRecoverySources
        )
        interruptedSession.transcriptTokens = result.tokens
        if interruptedSession.errorMessage?.hasPrefix("Live transcription warning:") == true {
          interruptedSession.errorMessage = nil
        }
        replace(interruptedSession)
        await persist(interruptedSession)
        if result.recoveredSources == recoverySources {
          warning = nil
          AppLog.dictation.log(
            "MeetingTranscriptRecovery: restored \(result.recoveredSources.count) source(s) locally"
          )
        } else {
          let missing = recoverySources.subtracting(result.recoveredSources)
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
          warning = "Local transcript recovery had no retained audio for: \(missing)."
        }
      } catch {
        warning = "Local transcript recovery failed: \(error.localizedDescription)"
      }
    }

    guard let transcribedSession = session(withID: sessionID) else {
      finalizationTasks.removeValue(forKey: sessionID)
      return
    }
    let transcript = MeetingTranscriptFormatter.plainText(
      tokens: transcribedSession.transcriptTokens
    )
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
          model: noteModel
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
    await persist(session)
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
    UserDefaults.standard.set(root.path, forKey: MeetingObsidianPreferences.vaultRootKey)
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
    UserDefaults.standard.removeObject(forKey: MeetingObsidianPreferences.vaultRootKey)
    UserDefaults.standard.removeObject(forKey: MeetingObsidianPreferences.exportFolderKey)
    MeetingObsidianPreferences.legacyKeys.forEach {
      UserDefaults.standard.removeObject(forKey: $0)
    }
    cancelContextTasks()
    contextCards.removeAll()
    seenContextTerms.removeAll()
    contextStatus = "Choose an Obsidian vault in Meetings."
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
    UserDefaults.standard.set(
      folder.path,
      forKey: MeetingObsidianPreferences.exportFolderKey
    )
    lastError = nil
  }

  func clearObsidianExportFolder() {
    obsidianExportFolderPath = nil
    UserDefaults.standard.removeObject(forKey: MeetingObsidianPreferences.exportFolderKey)
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

  private func updateTriggerRules(_ rules: [MeetingTriggerRule]) {
    triggerRules = MeetingTriggerRule.deduplicated(rules)
    MeetingTriggerRule.save(triggerRules)
    resetDetectionState()
  }

  func exportToObsidian(_ session: MeetingSession) async {
    guard let currentSession = self.session(withID: session.id),
          currentSession.status.isTerminal,
          finalizationTasks[session.id] == nil else {
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

  func openExportedNote(_ session: MeetingSession) {
    guard let path = session.exportedMarkdownPath else { return }
    MeetingObsidianExporter.open(URL(fileURLWithPath: path))
  }

  func copyMarkdown(_ session: MeetingSession) {
    guard let currentSession = self.session(withID: session.id) else { return }
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
    guard finalizationTasks[session.id] == nil else {
      lastError = "Wait for the meeting transcript to finish saving before deleting it."
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
    candidate: MeetingDetectionCandidate?
  ) async {
    guard !isLoadingSessions,
          activeSessionID == nil,
          !isStarting,
          !isStopping else { return }
    let activeTranscriptionEngine = transcriptionEngine
    if activeTranscriptionEngine.usesSoniox, !hasSonioxAPIKey {
      if automaticallyStarted {
        suppressedAutomaticFamily = candidate?.bundleFamily
        suppressedFamilyMissingSince = nil
        resetDetectionState()
      }
      lastError = "Add a Soniox API key in Settings before using Soniox for meetings."
      statusMessage = "Soniox API key required"
      return
    }
    isStarting = true
    SystemAudioController.shared.setMeetingCaptureActive(true)
    lastError = nil
    statusMessage = "Starting meeting capture…"

    let defaultTitle = Self.defaultTitle(detectedApp: detectedApp)
    var session = MeetingSession(
      title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaultTitle,
      detectedApp: detectedApp,
      automaticallyStarted: automaticallyStarted,
      transcriptionEngine: activeTranscriptionEngine
    )
    sessions.insert(session, at: 0)
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
    await persist(session)

    do {
      let directory = try await store.directory(for: session.id)
      let sessionID = session.id
      let transcriber = MeetingTranscriptionService(
        engine: activeTranscriptionEngine,
        tokenHandler: { [weak self] tokens in
          await self?.receive(tokens: tokens, for: sessionID)
        },
        previewHandler: { [weak self] source, text in
          await self?.receivePreview(text, source: source, for: sessionID)
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
      ingestionTask = Task { [weak self] in
        for await chunk in audioStream {
          guard !Task.isCancelled else { break }
          do {
            try await transcriber.ingest(chunk)
          } catch {
            self?.recordIngestionWarning(error, for: sessionID)
          }
        }
      }

      try await capture.start(
        directory: directory,
        includedApplicationScope: automaticallyStarted ? candidate?.captureScope : nil,
        onChunk: { [weak self] chunk in
          let level = MeetingAudioMeter.level(from: chunk.samples)
          Task { @MainActor [weak self] in
            self?.receiveAudioLevel(
              level,
              source: chunk.source,
              for: sessionID
            )
          }
          if case .dropped = continuation.yield(chunk),
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
      session.status = .failed
      session.endedAt = Date()
      session.errorMessage = error.localizedDescription
      forcedFullRecoverySources.removeValue(forKey: session.id)
      generatedTitleEligibleSessionIDs.remove(session.id)
      replace(session)
      await persist(session)
      activeSessionID = nil
      transcriber = nil
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
      lastError = "Meeting capture could not start: \(error.localizedDescription)"
      statusMessage = "Meeting capture failed"
    }
  }

  private func receive(tokens: [MeetingTranscriptToken], for sessionID: UUID) {
    guard var session = session(withID: sessionID),
          !tokens.isEmpty else { return }
    session.transcriptTokens.append(contentsOf: tokens)
    session.transcriptTokens = MeetingTranscriptFormatter.chronologicalTokens(
      session.transcriptTokens
    )
    replace(session)
    schedulePersist(session)
    if activeSessionID == sessionID {
      discoverContext(in: session)
    }
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
    guard activeSessionID == sessionID else { return }
    liveAudioLevels[source] = min(max(level, 0), 1)
  }

  private func discoverContext(in session: MeetingSession) {
    guard liveObsidianContextEnabled,
          let folder = obsidianVaultURL,
          let sessionID = activeSessionID else { return }
    let recentTokens = Array(session.transcriptTokens.suffix(260))
    let text = MeetingTranscriptFormatter.plainText(tokens: recentTokens)
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
    let intervalRemaining = lastContextAnalysisAt.map {
      max(0, 30 - Date().timeIntervalSince($0))
    } ?? 0
    let delay = max(6, intervalRemaining)
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

    let recentTokens = Array(session.transcriptTokens.suffix(360))
    let transcript = MeetingTranscriptFormatter.plainText(tokens: recentTokens)
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
      topics = MeetingTopicExtractor.fallbackTopics(from: transcript)
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
      contextStatus = "Choose an Obsidian vault in Meetings."
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
          try await Task.sleep(nanoseconds: 2_000_000_000)
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

  private func persist(_ session: MeetingSession) async {
    do {
      try await store.save(session)
    } catch {
      lastError = "Meeting could not be saved: \(error.localizedDescription)"
    }
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
    liveMicrophoneApplications = detector.liveMicrophoneApplications()
    guard !isLoadingSessions,
          automaticDetectionEnabled,
          !isStarting,
          !isStopping else { return }
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
      candidate = detected
      candidateMatchCount = 1
      candidateDetectedAt = Date()
      statusMessage = "Possible \(detected.appName) detected…"
      return
    }

    candidate = detected
    candidateMatchCount += 1
    if candidateMatchCount >= MeetingDetectionPolicy.requiredConsecutiveMatches {
      let latency = candidateDetectedAt.map { Date().timeIntervalSince($0) } ?? 0
      AppLog.dictation.log(
        "MeetingDetector: auto-start confirmed after \(latency, format: .fixed(precision: 2))s"
      )
      resetDetectionState()
      await startMeeting(
        title: detected.appName,
        detectedApp: detected.appName,
        automaticallyStarted: true,
        candidate: detected
      )
    }
  }

  private func resetDetectionState() {
    candidate = nil
    candidateMatchCount = 0
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
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
