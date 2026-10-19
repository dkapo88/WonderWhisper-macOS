import SwiftUI

/// A speaker's name that opens the speaker actions: rename, pick an attendee's name, mark as
/// the same person as another speaker, separate merged speakers, or reset the name.
struct MeetingSpeakerMenu<Label: View>: View {
  let speaker: MeetingSpeakerKey
  let directory: MeetingSpeakerDirectory
  let attendees: [String]
  let onRename: () -> Void
  let onName: (String) -> Void
  let onMerge: (MeetingSpeakerKey) -> Void
  let onSeparate: () -> Void
  @ViewBuilder let label: () -> Label

  var body: some View {
    Menu {
      Button("Rename…", systemImage: "pencil", action: onRename)
      if !attendeeNames.isEmpty {
        Menu("Name As") {
          ForEach(attendeeNames, id: \.self) { name in
            Button(name) { onName(name) }
          }
        }
      }
      if !mergeTargets.isEmpty {
        Menu("Same Person As") {
          ForEach(mergeTargets, id: \.rawValue) { target in
            Button(directory.name(for: target)) { onMerge(target) }
          }
        }
      }
      if !mergedSpeakers.isEmpty {
        Button(
          mergedSpeakers.count == 1 ? "Separate Merged Speaker" : "Separate Merged Speakers",
          systemImage: "arrow.triangle.branch",
          action: onSeparate
        )
      }
      if directory.hasCustomName(speaker) {
        Divider()
        Button("Reset Name", systemImage: "arrow.uturn.backward") { onName("") }
      }
    } label: {
      label()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Rename or merge \(directory.name(for: speaker))")
    .accessibilityLabel("Speaker \(directory.name(for: speaker))")
    .accessibilityHint("Rename or merge this speaker")
  }

  private var canonical: MeetingSpeakerKey {
    directory.canonical(speaker)
  }

  /// Attendees nobody else is called yet. The microphone is named in Settings instead.
  private var attendeeNames: [String] {
    guard !canonical.isMicrophone else { return [] }
    return attendees.filter { directory.speaker(named: $0) == nil }
  }

  private var mergeTargets: [MeetingSpeakerKey] {
    directory.speakers.filter { $0 != canonical }
  }

  private var mergedSpeakers: [MeetingSpeakerKey] {
    directory.mergedSpeakers(into: canonical)
  }
}
