import Foundation
import AppKit
import CoreAudio
import Darwin

enum MeetingApplicationScope: Codable, Equatable, Hashable, Sendable {
  case knownFamily(String)
  case bundlePrefix(String)

  var stableID: String {
    switch self {
    case .knownFamily(let family):
      return "family:\(family.lowercased())"
    case .bundlePrefix(let prefix):
      return "bundle:\(prefix.lowercased())"
    }
  }

  var legacyFamily: String {
    switch self {
    case .knownFamily(let family): return family
    case .bundlePrefix(let prefix): return "bundle:\(prefix.lowercased())"
    }
  }

  func matches(bundleID: String, executablePath: String? = nil) -> Bool {
    switch self {
    case .knownFamily(let includedFamily):
      return MeetingDetector.familyMatches(
        processFamily: MeetingDetector.family(
          for: bundleID,
          executablePath: executablePath
        ),
        includedFamily: includedFamily
      )
    case .bundlePrefix(let prefix):
      let canonicalBundleID = MeetingDetector.canonicalApplicationBundleID(
        for: bundleID,
        executablePath: executablePath
      )
      return MeetingDetector.bundleIDMatches(bundleID, prefix: prefix)
        || MeetingDetector.bundleIDMatches(canonicalBundleID, prefix: prefix)
    }
  }
}

struct MeetingTriggerRule: Codable, Equatable, Identifiable, Sendable {
  enum DetectionMode: String, Codable, Sendable {
    case slackHuddle
    case googleMeet
    case microphone
  }

  static let defaultsKey = "meeting.autoDetection.triggerRules"
  static let legacyBundlePrefixesKey = "meeting.autoDetect.apps"

  static let defaultRules: [MeetingTriggerRule] = [
    MeetingTriggerRule(
      bundleIDPrefix: "com.tinyspeck.slackmacgap",
      displayName: "Slack",
      detectionMode: .slackHuddle,
      captureScope: .knownFamily("slack")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "com.google.Chrome",
      displayName: "Google Chrome",
      detectionMode: .googleMeet,
      captureScope: .knownFamily("chrome")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "company.thebrowser.dia",
      displayName: "Dia",
      detectionMode: .googleMeet,
      captureScope: .knownFamily("dia")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "company.thebrowser.browser",
      displayName: "Arc",
      detectionMode: .googleMeet,
      captureScope: .knownFamily("arc")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "com.apple.Safari",
      displayName: "Safari",
      detectionMode: .googleMeet,
      captureScope: .knownFamily("safari")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "us.zoom.xos",
      displayName: "Zoom",
      detectionMode: .microphone,
      captureScope: .bundlePrefix("us.zoom.xos")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "com.microsoft.teams2",
      displayName: "Microsoft Teams",
      detectionMode: .microphone,
      captureScope: .bundlePrefix("com.microsoft.teams2")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "com.apple.FaceTime",
      displayName: "FaceTime",
      detectionMode: .microphone,
      captureScope: .bundlePrefix("com.apple.FaceTime")
    ),
    MeetingTriggerRule(
      bundleIDPrefix: "net.imput.helium",
      displayName: "Helium",
      detectionMode: .microphone,
      captureScope: .bundlePrefix("net.imput.helium")
    )
  ]

  let bundleIDPrefix: String
  let displayName: String
  let detectionMode: DetectionMode
  let captureScope: MeetingApplicationScope

  var id: String {
    "\(detectionMode.rawValue):\(captureScope.stableID):\(bundleIDPrefix.lowercased())"
  }

  static func inferred(
    bundleID: String,
    displayName: String,
    executablePath: String? = nil
  ) -> MeetingTriggerRule? {
    let canonicalBundleID = MeetingDetector.canonicalApplicationBundleID(
      for: bundleID,
      executablePath: executablePath
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalBundleID.isEmpty else { return nil }

    let normalizedBundleID = canonicalBundleID.lowercased()
    let family = MeetingDetector.family(
      for: bundleID,
      executablePath: executablePath
    ) ?? MeetingDetector.family(for: canonicalBundleID)
    let mode: DetectionMode
    let scope: MeetingApplicationScope
    if normalizedBundleID == "company.thebrowser" {
      // Legacy Dia/Arc helpers used one vendor-wide prefix. Keep them behind strict
      // Google Meet evidence instead of treating browser microphone use as a call.
      mode = .googleMeet
      scope = .bundlePrefix("company.thebrowser")
    } else {
      switch family {
    case "slack":
      mode = .slackHuddle
      scope = .knownFamily("slack")
    case "chrome":
      mode = .googleMeet
      scope = .knownFamily("chrome")
    case "dia":
      mode = .googleMeet
      scope = .knownFamily("dia")
    case "arc":
      mode = .googleMeet
      scope = .knownFamily("arc")
    case "safari":
      mode = .googleMeet
      scope = .knownFamily("safari")
    case "thebrowser":
      // A shared Dia/Arc helper without an executable path cannot safely identify one
      // browser family. Keep strict Meet evidence and scope capture to the vendor prefix.
      mode = .googleMeet
      scope = .bundlePrefix("company.thebrowser")
    default:
      mode = .microphone
      scope = .bundlePrefix(canonicalBundleID)
      }
    }
    return MeetingTriggerRule(
      bundleIDPrefix: canonicalBundleID,
      displayName: displayName,
      detectionMode: mode,
      captureScope: scope
    )
  }

  static func load(defaults: UserDefaults = .standard) -> [MeetingTriggerRule] {
    if let data = defaults.data(forKey: defaultsKey),
       let decoded = try? JSONDecoder().decode([MeetingTriggerRule].self, from: data) {
      return deduplicated(decoded)
    }
    if let legacyPrefixes = defaults.stringArray(forKey: legacyBundlePrefixesKey) {
      let migrated = legacyPrefixes.compactMap {
        inferred(bundleID: $0, displayName: $0)
      }
      return deduplicated(migrated)
    }
    return defaultRules
  }

  static func save(
    _ rules: [MeetingTriggerRule],
    defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(deduplicated(rules)) else { return }
    defaults.set(data, forKey: defaultsKey)
  }

  static func deduplicated(_ rules: [MeetingTriggerRule]) -> [MeetingTriggerRule] {
    var seen: Set<String> = []
    return rules.filter { seen.insert($0.id).inserted }
  }
}

struct MeetingMicrophoneApplication: Identifiable, Equatable, Sendable {
  let bundleID: String
  let name: String
  let captureScope: MeetingApplicationScope

  var id: String { captureScope.stableID }
}

struct MeetingDetectionCandidate: Equatable, Sendable {
  let appName: String
  let bundleFamily: String
  let triggerID: String
  let captureScope: MeetingApplicationScope

  init(
    appName: String,
    bundleFamily: String,
    triggerID: String? = nil,
    captureScope: MeetingApplicationScope? = nil
  ) {
    let resolvedScope = captureScope ?? .knownFamily(bundleFamily)
    self.appName = appName
    self.bundleFamily = bundleFamily
    self.triggerID = triggerID ?? resolvedScope.stableID
    self.captureScope = resolvedScope
  }
}

@MainActor
final class MeetingDetector {
  private struct AudioProcessState {
    let bundleID: String
    let canonicalBundleID: String
    let executablePath: String?
    let name: String
    let family: String?
    let hasInput: Bool
    let hasOutput: Bool
  }

  private struct AudioFamilyState {
    var hasInput = false
    var hasOutput = false
  }

  private var lastDiagnostic: String?
  private var lastLivenessDiagnostic: String?

  func currentCandidate(
    triggerRules: [MeetingTriggerRule] = MeetingTriggerRule.defaultRules
  ) -> MeetingDetectionCandidate? {
    let rules = MeetingTriggerRule.deduplicated(triggerRules)
    let processes = audioProcesses()
    let states = activeAudioFamilies(processes: processes)

    if let slackRule = rules.first(where: {
      $0.detectionMode == .slackHuddle
        && Self.rule($0, enables: "slack", processes: processes)
    }),
    let slack = states["slack"], slack.hasInput, slack.hasOutput {
      logDiagnostic("Slack candidate input=true output=true")
      return MeetingDetectionCandidate(
        appName: "Slack Huddle",
        bundleFamily: "slack",
        triggerID: slackRule.id,
        captureScope: slackRule.captureScope
      )
    }

    let browserFamilies = googleMeetBrowserFamilies()
    let activeBrowserFamilies = Set(browserFamilies.filter { family in
      let browser = Self.audioState(for: family, states: states)
      return Self.meetAudioIsActive(
        hasInput: browser.hasInput,
        hasOutput: browser.hasOutput
      )
    })
    let browserMatch = browserFamilies.compactMap {
      browserFamily -> (String, MeetingTriggerRule)? in
      guard activeBrowserFamilies.contains(browserFamily),
            let rule = rules.first(where: {
              $0.detectionMode == .googleMeet
                && Self.rule($0, enables: browserFamily, processes: processes)
            }) else { return nil }
      return (browserFamily, rule)
    }.first
    if let (browserFamily, browserRule) = browserMatch {
      logDiagnostic("Google Meet candidate family=\(browserFamily) input=true output=true")
      return MeetingDetectionCandidate(
        appName: "Google Meet",
        bundleFamily: browserFamily,
        triggerID: "\(browserRule.id):\(browserFamily)",
        captureScope: .knownFamily(browserFamily)
      )
    }

    if !browserFamilies.isEmpty {
      let diagnostic = browserFamilies.map { family in
        let browser = Self.audioState(for: family, states: states)
        return "\(family):input=\(browser.hasInput),output=\(browser.hasOutput)"
      }.joined(separator: " ")
      logDiagnostic("Google Meet windows \(diagnostic)")
    }

    for rule in rules where rule.detectionMode == .microphone {
      guard let process = processes.first(where: {
        $0.hasInput
          && !Self.isStrictMeetingFamily($0.family)
          && rule.captureScope.matches(
            bundleID: $0.bundleID,
            executablePath: $0.executablePath
          )
      }) else { continue }
      logDiagnostic("Custom microphone candidate bundle=\(process.canonicalBundleID)")
      return MeetingDetectionCandidate(
        appName: rule.displayName.isEmpty ? process.name : rule.displayName,
        bundleFamily: rule.captureScope.legacyFamily,
        triggerID: rule.id,
        captureScope: rule.captureScope
      )
    }

    logDiagnostic("No supported active meeting window")
    return nil
  }

  func liveMicrophoneApplications() -> [MeetingMicrophoneApplication] {
    var seen: Set<String> = []
    return audioProcesses().compactMap { process in
      guard process.hasInput else { return nil }
      let scope = process.family.map(MeetingApplicationScope.knownFamily)
        ?? .bundlePrefix(process.canonicalBundleID)
      guard seen.insert(scope.stableID).inserted else { return nil }
      return MeetingMicrophoneApplication(
        bundleID: process.canonicalBundleID,
        name: process.name,
        captureScope: scope
      )
    }.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  func isMeetingStillActive(family: String) -> Bool {
    let processes = audioProcesses()
    if family.hasPrefix("bundle:") {
      let prefix = String(family.dropFirst("bundle:".count))
      return isMeetingStillActive(
        scope: .bundlePrefix(prefix),
        family: nil,
        processes: processes
      )
    }
    return isMeetingStillActive(
      scope: .knownFamily(family),
      family: family,
      processes: processes
    )
  }

  func isMeetingStillActive(candidate: MeetingDetectionCandidate) -> Bool {
    isMeetingStillActive(
      scope: candidate.captureScope,
      family: candidate.bundleFamily,
      processes: audioProcesses()
    )
  }

  private func isMeetingStillActive(
    scope: MeetingApplicationScope,
    family: String?,
    processes: [AudioProcessState]
  ) -> Bool {
    if case .bundlePrefix = scope {
      let matches = processes.filter {
        scope.matches(bundleID: $0.bundleID, executablePath: $0.executablePath)
      }
      let hasInput = matches.contains(where: \.hasInput)
      let hasOutput = matches.contains(where: \.hasOutput)
      let active = hasInput || hasOutput
      logLiveness(
        "scope=\(scope.stableID) window=false input=\(hasInput) "
          + "output=\(hasOutput) active=\(active)"
      )
      return active
    }

    guard let family else { return false }
    let states = activeAudioFamilies(processes: processes)
    let audio = Self.audioState(for: family, states: states)
    let hasMeetingWindow = family == "slack"
      ? false
      : googleMeetBrowserFamilies().contains(family)
    let active = family == "slack"
      ? audio.hasInput || audio.hasOutput
      : Self.meetingLikelyActive(
        hasMeetingWindow: hasMeetingWindow,
        hasInput: audio.hasInput,
        hasOutput: audio.hasOutput
      )
    logLiveness("family=\(family) window=\(hasMeetingWindow) "
      + "input=\(audio.hasInput) output=\(audio.hasOutput) active=\(active)"
    )
    return active
  }

  private func logLiveness(_ diagnostic: String) {
    guard diagnostic != lastLivenessDiagnostic else { return }
    lastLivenessDiagnostic = diagnostic
    AppLog.dictation.log("MeetingDetector: Liveness \(diagnostic, privacy: .public)")
  }

  private func logDiagnostic(_ message: String) {
    guard message != lastDiagnostic else { return }
    lastDiagnostic = message
    AppLog.dictation.log("MeetingDetector: \(message, privacy: .public)")
  }

  private func audioProcesses() -> [AudioProcessState] {
    var result: [AudioProcessState] = []
    let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()
    for objectID in Self.audioProcessObjectIDs() {
      guard let bundleID = Self.stringProperty(
        objectID: objectID,
        selector: kAudioProcessPropertyBundleID
      ),
      !bundleID.isEmpty,
      bundleID.lowercased() != ownBundleID else { continue }
      let executablePath = Self.executablePath(for: objectID)
      let canonicalBundleID = Self.canonicalApplicationBundleID(
        for: bundleID,
        executablePath: executablePath
      )
      let processID = pid_t(Self.uintProperty(
        objectID: objectID,
        selector: kAudioProcessPropertyPID
      ))
      let localizedName = processID > 0
        ? NSRunningApplication(processIdentifier: processID)?.localizedName
        : nil
      let fallbackName = Self.outermostApplicationURL(for: executablePath ?? "")?
        .deletingPathExtension().lastPathComponent
      result.append(
        AudioProcessState(
          bundleID: bundleID,
          canonicalBundleID: canonicalBundleID,
          executablePath: executablePath,
          name: localizedName ?? fallbackName ?? canonicalBundleID,
          family: Self.family(for: bundleID, executablePath: executablePath),
          hasInput: Self.boolProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningInput
          ),
          hasOutput: Self.boolProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput
          )
        )
      )
    }
    return result
  }

  nonisolated static func audioProcessIDs(
    matching scope: MeetingApplicationScope
  ) -> [NSNumber] {
    audioProcessObjectIDs().compactMap { objectID in
      guard let bundleID = stringProperty(
        objectID: objectID,
        selector: kAudioProcessPropertyBundleID
      ) else { return nil }
      let executablePath = executablePath(for: objectID)
      guard scope.matches(bundleID: bundleID, executablePath: executablePath) else {
        return nil
      }
      let processID = pid_t(uintProperty(
        objectID: objectID,
        selector: kAudioProcessPropertyPID
      ))
      return processID > 0 ? NSNumber(value: processID) : nil
    }
  }

  private func activeAudioFamilies(
    processes: [AudioProcessState]
  ) -> [String: AudioFamilyState] {
    var result: [String: AudioFamilyState] = [:]
    for process in processes {
      guard let family = process.family else { continue }

      var state = result[family] ?? AudioFamilyState()
      state.hasInput = state.hasInput || process.hasInput
      state.hasOutput = state.hasOutput || process.hasOutput
      result[family] = state
    }
    return result
  }

  private func googleMeetBrowserFamilies() -> [String] {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return []
    }
    var result: [String] = []
    var seen: Set<String> = []
    for window in windows {
      let owner = (window[kCGWindowOwnerName as String] as? String)?.lowercased() ?? ""
      let title = (window[kCGWindowName as String] as? String)?.lowercased() ?? ""
      guard title.contains("google meet") || title.contains("meet -") else { continue }
      let family: String?
      if owner.contains("google chrome") {
        family = "chrome"
      } else if owner == "dia" {
        family = "dia"
      } else if owner == "arc" {
        family = "arc"
      } else if owner == "safari" {
        family = "safari"
      } else {
        family = nil
      }
      if let family, seen.insert(family).inserted {
        result.append(family)
      }
    }
    return result
  }

  nonisolated static func family(
    for bundleID: String,
    executablePath: String? = nil
  ) -> String? {
    let normalized = bundleID.lowercased()
    let normalizedPath = executablePath?.lowercased() ?? ""
    if normalizedPath.contains("/dia.app/") { return "dia" }
    if normalizedPath.contains("/arc.app/") { return "arc" }
    if normalized.hasPrefix("com.tinyspeck.slackmacgap")
      || normalized.hasPrefix("com.slack") {
      return "slack"
    }
    if normalized.hasPrefix("com.google.chrome") { return "chrome" }
    if normalized.hasPrefix("company.thebrowser.dia") { return "dia" }
    if normalized.hasPrefix("company.thebrowser.browser.helper") {
      return "thebrowser"
    }
    if normalized.hasPrefix("company.thebrowser.browser") { return "arc" }
    if normalized.hasPrefix("com.apple.safari") { return "safari" }
    return nil
  }

  nonisolated static func bundleIDMatches(_ bundleID: String, prefix: String) -> Bool {
    let candidate = bundleID.lowercased()
    let normalizedPrefix = prefix
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedPrefix.isEmpty else { return false }
    return candidate == normalizedPrefix || candidate.hasPrefix(normalizedPrefix + ".")
  }

  nonisolated static func outermostApplicationURL(for executablePath: String) -> URL? {
    guard executablePath.hasPrefix("/") else { return nil }
    var url = URL(fileURLWithPath: "/", isDirectory: true)
    for component in URL(fileURLWithPath: executablePath).pathComponents
      where component != "/" {
      url.appendPathComponent(component)
      if component.lowercased().hasSuffix(".app") {
        return url
      }
    }
    return nil
  }

  nonisolated static func canonicalApplicationBundleID(
    for bundleID: String,
    executablePath: String? = nil
  ) -> String {
    guard let executablePath,
          let applicationURL = outermostApplicationURL(for: executablePath),
          let canonicalBundleID = Bundle(url: applicationURL)?.bundleIdentifier,
          !canonicalBundleID.isEmpty else {
      return bundleID
    }
    return canonicalBundleID
  }

  nonisolated static func meetAudioIsActive(hasInput: Bool, hasOutput: Bool) -> Bool {
    hasInput && hasOutput
  }

  nonisolated static func meetingLikelyActive(
    hasMeetingWindow: Bool,
    hasInput: Bool,
    hasOutput: Bool
  ) -> Bool {
    hasInput || (hasMeetingWindow && hasOutput)
  }

  nonisolated static func firstActiveMeetFamily(
    windowFamilies: [String],
    activeFamilies: Set<String>
  ) -> String? {
    windowFamilies.first(where: activeFamilies.contains)
  }

  nonisolated static func familyMatches(
    processFamily: String?,
    includedFamily: String
  ) -> Bool {
    guard let processFamily else { return false }
    if processFamily == includedFamily { return true }
    return processFamily == "thebrowser"
      && (includedFamily == "dia" || includedFamily == "arc")
  }

  private static func isStrictMeetingFamily(_ family: String?) -> Bool {
    guard let family else { return false }
    return ["slack", "chrome", "dia", "arc", "safari", "thebrowser"].contains(family)
  }

  private static func rule(
    _ rule: MeetingTriggerRule,
    enables family: String,
    processes: [AudioProcessState]
  ) -> Bool {
    switch rule.captureScope {
    case .knownFamily(let configuredFamily):
      return configuredFamily == family
    case .bundlePrefix:
      return processes.contains {
        familyMatches(processFamily: $0.family, includedFamily: family)
          && rule.captureScope.matches(
            bundleID: $0.bundleID,
            executablePath: $0.executablePath
          )
      }
    }
  }

  private static func audioState(
    for family: String,
    states: [String: AudioFamilyState]
  ) -> AudioFamilyState {
    var result = states[family] ?? AudioFamilyState()
    if family == "dia" || family == "arc", let shared = states["thebrowser"] {
      result.hasInput = result.hasInput || shared.hasInput
      result.hasOutput = result.hasOutput || shared.hasOutput
    }
    return result
  }

  nonisolated private static func audioProcessObjectIDs() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
          size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var objects = Array(repeating: AudioObjectID(0), count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
      return []
    }
    return objects
  }

  private static func boolProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
      return false
    }
    return value != 0
  }

  nonisolated private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let value else { return nil }
    return value as String
  }

  nonisolated private static func executablePath(for objectID: AudioObjectID) -> String? {
    let processID = pid_t(uintProperty(
      objectID: objectID,
      selector: kAudioProcessPropertyPID
    ))
    guard processID > 0 else { return nil }
    return executablePath(for: processID)
  }

  nonisolated static func executablePath(for processID: pid_t) -> String? {
    if let path = NSRunningApplication(
      processIdentifier: processID
    )?.executableURL?.path {
      return path
    }

    var buffer = [CChar](
      repeating: 0,
      count: 4_096
    )
    let length = buffer.withUnsafeMutableBytes { bytes in
      proc_pidpath(processID, bytes.baseAddress, UInt32(bytes.count))
    }
    guard length > 0 else { return nil }
    return String(cString: buffer)
  }

  nonisolated private static func uintProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(
      objectID,
      &address,
      0,
      nil,
      &size,
      &value
    ) == noErr else { return 0 }
    return value
  }
}
