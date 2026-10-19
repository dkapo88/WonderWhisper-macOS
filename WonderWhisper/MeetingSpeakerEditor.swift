import Foundation

/// Renames, merges, and separates a meeting's speakers. Edits only `speakerNames` and
/// `speakerMerges`, so the transcript tokens stay as the providers produced them and every
/// edit can be undone.
enum MeetingSpeakerEditor {
  /// Names a speaker. An empty name restores the default. A name another speaker already
  /// has merges the two, since they are the same person.
  static func rename(
    _ key: MeetingSpeakerKey,
    to name: String,
    in session: inout MeetingSession,
    userName: String? = MeetingSpeakerDirectory.currentUserName()
  ) {
    let directory = MeetingSpeakerDirectory(session: session, userName: userName)
    let speaker = directory.canonical(key)
    session.speakerSuggestions.removeAll { $0.speakerKey.map(directory.canonical) == speaker }
    guard let cleaned = MeetingSpeakerDirectory.cleanedName(name) else {
      session.speakerNames.removeValue(forKey: speaker.rawValue)
      return
    }
    if let other = directory.speaker(named: cleaned), other != speaker {
      // Fold into the microphone when either side is the user; it never merges away.
      let (source, target) = speaker.isMicrophone ? (other, speaker) : (speaker, other)
      session.speakerMerges[source.rawValue] = target.rawValue
      session.speakerNames.removeValue(forKey: source.rawValue)
      session.speakerNames[target.rawValue] = cleaned
      return
    }
    session.speakerNames[speaker.rawValue] = cleaned
  }

  /// Folds `key` into `target`. The microphone is never folded away: merging it with a voice
  /// on the call folds that voice into the microphone instead.
  static func merge(
    _ key: MeetingSpeakerKey,
    into target: MeetingSpeakerKey,
    in session: inout MeetingSession,
    userName: String? = MeetingSpeakerDirectory.currentUserName()
  ) {
    let directory = MeetingSpeakerDirectory(session: session, userName: userName)
    var source = directory.canonical(key)
    var destination = directory.canonical(target)
    guard source != destination else { return }
    if source.isMicrophone {
      swap(&source, &destination)
    }
    session.speakerMerges[source.rawValue] = destination.rawValue
    if let name = session.speakerNames.removeValue(forKey: source.rawValue),
       session.speakerNames[destination.rawValue] == nil {
      session.speakerNames[destination.rawValue] = name
    }
    session.speakerSuggestions.removeAll { $0.speaker == source.rawValue }
  }

  /// Undoes every merge into `key`, so the voices it absorbed show on their own again.
  static func separate(
    _ key: MeetingSpeakerKey,
    in session: inout MeetingSession,
    userName: String? = MeetingSpeakerDirectory.currentUserName()
  ) {
    let directory = MeetingSpeakerDirectory(session: session, userName: userName)
    let speaker = directory.canonical(key)
    let absorbed = Set(directory.mergedSpeakers(into: speaker).map(\.rawValue))
    session.speakerMerges = session.speakerMerges.filter { !absorbed.contains($0.key) }
  }
}
