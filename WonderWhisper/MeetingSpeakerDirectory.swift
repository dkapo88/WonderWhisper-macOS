import Foundation

/// Who is who in one meeting's transcript. The microphone is the user ("Your name" in
/// Settings, or "You"); voices on the call keep their diarizer label ("Speaker 2") until they
/// are named, merged, or there is only one other attendee to be.
struct MeetingSpeakerDirectory: Equatable, Sendable {
  static let userNameDefaultsKey = "meeting.userName"
  static let defaultUserName = "You"
  static let maximumNameLength = 60

  /// Speakers after merges, in order of first appearance.
  let speakers: [MeetingSpeakerKey]
  let userName: String?
  private let names: [MeetingSpeakerKey: String]
  private let merges: [MeetingSpeakerKey: MeetingSpeakerKey]
  /// Every speaker heard before merges, in order of first appearance. Colours follow this
  /// order so a speaker keeps its colour when another is merged into it.
  private let heardSpeakers: [MeetingSpeakerKey]
  private let soleRemoteAttendee: String?

  init(
    tokens: [MeetingTranscriptToken],
    names: [String: String] = [:],
    merges: [String: String] = [:],
    attendees: [String] = [],
    userName: String? = Self.currentUserName()
  ) {
    let cleanedUserName = Self.cleanedName(userName ?? "")
    self.userName = cleanedUserName
    self.names = Dictionary(
      names.compactMap { rawKey, name in
        guard let key = MeetingSpeakerKey(rawValue: rawKey),
              let name = Self.cleanedName(name) else { return nil }
        return (key, name)
      },
      uniquingKeysWith: { first, _ in first }
    )
    self.merges = Dictionary(
      merges.compactMap { rawSource, rawTarget in
        guard let source = MeetingSpeakerKey(rawValue: rawSource),
              let target = MeetingSpeakerKey(rawValue: rawTarget),
              !source.isMicrophone,
              source != target else { return nil }
        return (source, target)
      },
      uniquingKeysWith: { first, _ in first }
    )

    var firstHeard: [MeetingSpeakerKey: (time: TimeInterval, order: Int)] = [:]
    for (order, token) in tokens.enumerated() where !token.text.isEmpty {
      let key = MeetingSpeakerKey(token: token)
      if let existing = firstHeard[key], existing.time <= token.startTime { continue }
      firstHeard[key] = (token.startTime, firstHeard[key]?.order ?? order)
    }
    heardSpeakers = firstHeard.sorted { lhs, rhs in
      if lhs.value.time != rhs.value.time { return lhs.value.time < rhs.value.time }
      return lhs.value.order < rhs.value.order
    }.map(\.key)

    // The user may be listed by full name while "Your name" is a first name, or the reverse.
    let userFirstName = cleanedUserName.flatMap(Self.firstName)
    let remoteAttendees = attendees.compactMap(Self.cleanedName).filter { attendee in
      guard let userFirstName else { return true }
      return Self.firstName(attendee)?.caseInsensitiveCompare(userFirstName) != .orderedSame
    }
    soleRemoteAttendee = remoteAttendees.count == 1 ? remoteAttendees.first : nil

    var resolved: [MeetingSpeakerKey] = []
    var seen: Set<MeetingSpeakerKey> = []
    let merges = self.merges
    for key in heardSpeakers {
      let canonical = Self.canonical(key, merges: merges)
      if seen.insert(canonical).inserted {
        resolved.append(canonical)
      }
    }
    speakers = resolved
  }

  init(session: MeetingSession, userName: String? = Self.currentUserName()) {
    self.init(
      tokens: session.transcriptTokens,
      names: session.speakerNames,
      merges: session.speakerMerges,
      attendees: session.attendees,
      userName: userName
    )
  }

  static func currentUserName(defaults: UserDefaults = AppConfig.defaults) -> String? {
    cleanedName(defaults.string(forKey: userNameDefaultsKey) ?? "")
  }

  /// A name as stored: trimmed, single-spaced, at most `maximumNameLength` characters. Nil
  /// when nothing is left.
  static func cleanedName(_ name: String) -> String? {
    let collapsed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(maximumNameLength))
  }

  private static func firstName(_ name: String) -> String? {
    name.split(separator: " ").first.map(String.init)
  }

  /// The speaker `key` resolves to after merges.
  func canonical(_ key: MeetingSpeakerKey) -> MeetingSpeakerKey {
    Self.canonical(key, merges: merges)
  }

  func name(for key: MeetingSpeakerKey) -> String {
    let canonical = canonical(key)
    if let name = names[canonical] { return name }
    return defaultName(for: canonical)
  }

  /// Whether the speaker has a name the user gave it (not a default).
  func hasCustomName(_ key: MeetingSpeakerKey) -> Bool {
    names[canonical(key)] != nil
  }

  /// Whether the speaker has a real name: the user, a name given to it, or the only other
  /// attendee. False for "Speaker 2" and "Others".
  func isIdentified(_ key: MeetingSpeakerKey) -> Bool {
    let canonical = canonical(key)
    return canonical.isMicrophone || names[canonical] != nil
      || soleRemoteAttendeeApplies(to: canonical)
  }

  /// Speakers on the call (everyone but the microphone) after merges.
  var remoteSpeakers: [MeetingSpeakerKey] {
    speakers.filter { !$0.isMicrophone }
  }

  /// Speakers merged into `key`, not counting `key` itself.
  func mergedSpeakers(into key: MeetingSpeakerKey) -> [MeetingSpeakerKey] {
    let canonical = canonical(key)
    return merges.keys.filter { $0 != canonical && self.canonical($0) == canonical }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// A stable colour slot for a speaker on the call; nil for the microphone.
  func colorIndex(for key: MeetingSpeakerKey) -> Int? {
    let canonical = canonical(key)
    guard !canonical.isMicrophone else { return nil }
    let remote = heardSpeakers.filter { !$0.isMicrophone }
    return remote.firstIndex(of: canonical) ?? remote.count
  }

  /// The canonical speaker already called `name`, if any.
  func speaker(named name: String) -> MeetingSpeakerKey? {
    speakers.first { self.name(for: $0).caseInsensitiveCompare(name) == .orderedSame }
  }

  private func defaultName(for key: MeetingSpeakerKey) -> String {
    switch key.source {
    case .microphone:
      return userName ?? Self.defaultUserName
    case .systemAudio:
      if let soleRemoteAttendee, soleRemoteAttendeeApplies(to: key) {
        return soleRemoteAttendee
      }
      return key.label.map { "Speaker \($0)" } ?? "Others"
    case .mixed:
      return key.label.map { "Speaker \($0)" } ?? MeetingAudioSource.mixed.displayName
    }
  }

  /// With one other attendee and one voice on the call, that voice is the attendee, unless
  /// the name was already given to someone else.
  private func soleRemoteAttendeeApplies(to key: MeetingSpeakerKey) -> Bool {
    guard let soleRemoteAttendee, key.source == .systemAudio, names[key] == nil else {
      return false
    }
    return remoteSpeakers == [key] && speaker(namedExactly: soleRemoteAttendee) == nil
  }

  /// A speaker whose custom name is `name`; ignores defaults so `defaultName` can't recurse.
  private func speaker(namedExactly name: String) -> MeetingSpeakerKey? {
    names.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
  }

  private static func canonical(
    _ key: MeetingSpeakerKey,
    merges: [MeetingSpeakerKey: MeetingSpeakerKey]
  ) -> MeetingSpeakerKey {
    var current = key
    var visited: Set<MeetingSpeakerKey> = [key]
    while let next = merges[current] {
      // A cycle can only come from a hand-edited file; stop where it started.
      guard visited.insert(next).inserted else { return key }
      current = next
    }
    return current
  }
}
