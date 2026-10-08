import AppKit
import SwiftUI

/// Sheet for editing the meeting summary prompt.
struct MeetingSummaryPromptEditor: View {
  @Binding var prompt: String
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "text.document")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 30, height: 30)

        VStack(alignment: .leading, spacing: 3) {
          Text("Meeting summary prompt")
            .font(.title3.weight(.semibold))
          Text("Set the structure, emphasis, and level of detail used for generated notes.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(22)

      Divider()

      TextEditor(text: $prompt)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(18)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Meeting summary prompt")

      Divider()

      HStack(spacing: 10) {
        Button("Restore default") {
          prompt = MeetingNoteGenerator.defaultPrompt
        }

        Text("\(prompt.count.formatted()) characters")
          .font(.caption)
          .foregroundStyle(.tertiary)

        Spacer()

        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save prompt", action: onSave)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
      .background(Color(nsColor: .controlBackgroundColor))
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 560)
  }
}
