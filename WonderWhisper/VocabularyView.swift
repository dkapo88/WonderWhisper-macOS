import SwiftUI

struct VocabularyView: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Boost accuracy by teaching WonderWhisper about proper nouns, acronyms, and spelling preferences. Changes apply to both Dictation and Command modes.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        editorCard(
          title: "Custom vocabulary",
          subtitle: "Use a comma-separated list (e.g., \"WonderWhisper, WW, Groq, Parakeet\").",
          text: $vm.vocabCustom,
          placeholder: "Product names, acronyms, or phrases to bias transcription toward."
        )

        editorCard(
          title: "Spelling corrections",
          subtitle: "One pair per line in the format \"spoken -> replacement\".",
          text: $vm.vocabSpelling,
          placeholder: "e.g.\ncolor -> colour\norganisation -> organization"
        )
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func editorCard(
    title: String,
    subtitle: String,
    text: Binding<String>,
    placeholder: String
  ) -> some View {
    GroupBox(title) {
      VStack(alignment: .leading, spacing: 8) {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)

        ZStack(alignment: .topLeading) {
          TextEditor(text: text)
            .font(.body.monospaced())
            .frame(minHeight: 160)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
              RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2))
            )

          if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(placeholder)
              .font(.callout)
              .foregroundStyle(.secondary.opacity(0.7))
              .padding(16)
          }
        }

        HStack {
          Spacer()
          Button("Clear") {
            text.wrappedValue = ""
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(8)
    }
  }
}

#Preview {
  VocabularyView(vm: DictationViewModel())
}
