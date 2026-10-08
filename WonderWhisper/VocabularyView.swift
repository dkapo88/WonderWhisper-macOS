import SwiftUI

struct VocabularyView: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    SettingsPage {
      editorSection(
        title: "Custom vocabulary",
        footer: "One term per line (commas also work), for example WonderWhisper, Groq, "
          + "Parakeet. Used by Dictation, Command, and on-device models.",
        text: $vm.vocabCustom,
        placeholder: "Product names, acronyms, or phrases",
        minHeight: 180
      )

      editorSection(
        title: "Spelling corrections",
        footer: "One pair per line as \"spoken -> replacement\", for example "
          + "\"organisation -> organization\".",
        text: $vm.vocabSpelling,
        placeholder: "colour -> color",
        minHeight: 140
      )
    }
  }

  private func editorSection(
    title: String,
    footer: String,
    text: Binding<String>,
    placeholder: String,
    minHeight: CGFloat
  ) -> some View {
    Section {
      ZStack(alignment: .topLeading) {
        TextEditor(text: text)
          .font(.body.monospaced())
          .scrollContentBackground(.hidden)
          .frame(minHeight: minHeight)
          .accessibilityLabel(title)

        if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(placeholder)
            .font(.body.monospaced())
            .foregroundStyle(.tertiary)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
    } header: {
      HStack {
        Text(title)
        Spacer()
        Button("Clear", role: .destructive) {
          text.wrappedValue = ""
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(text.wrappedValue.isEmpty)
        .accessibilityLabel("Clear \(title.lowercased())")
      }
    } footer: {
      Text(footer)
        .settingsFootnote()
    }
  }
}

#Preview {
  VocabularyView(vm: DictationViewModel())
}
