import Foundation

/// A name proposed for an unnamed speaker from what was said in the meeting, shown until the
/// user accepts or dismisses it.
struct MeetingSpeakerSuggestion: Codable, Identifiable, Equatable, Sendable {
  /// The suggested speaker's `MeetingSpeakerKey.rawValue`.
  let speaker: String
  let name: String
  /// A short quote from the transcript that supports the name.
  let evidence: String

  var id: String { speaker }

  var speakerKey: MeetingSpeakerKey? {
    MeetingSpeakerKey(rawValue: speaker)
  }
}
