import SwiftUI
import Combine

struct ScratchpadView: View {
  @ObservedObject var vm: DictationViewModel
  var openPromptSettings: () -> Void
  @StateObject private var scratchpad = ScratchpadViewModel()
  @State private var path: [UUID] = []
  @State private var presentedError: String?

  var body: some View {
    NavigationStack(path: $path) {
      ScratchpadMainView(vm: vm, scratchpad: scratchpad) { note in
        path.append(note.id)
      }
      .navigationDestination(for: UUID.self) { noteID in
        ScratchpadNoteEditorView(vm: vm, scratchpad: scratchpad, noteID: noteID, openPromptSettings: openPromptSettings)
      }
    }
    .alert("Error", isPresented: Binding(get: { presentedError != nil }, set: { if !$0 { presentedError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(presentedError ?? "")
    }
    .onReceive(scratchpad.$errorMessage.compactMap { $0 }) { message in
      presentedError = message
      scratchpad.errorMessage = nil
    }
  }
}

private struct ScratchpadMainView: View {
  @ObservedObject var vm: DictationViewModel
  @ObservedObject var scratchpad: ScratchpadViewModel
  var openNote: (ScratchpadNote) -> Void

  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("New Note")
          .font(.headline)
        ZStack(alignment: .topLeading) {
          TextEditor(text: $scratchpad.draftText)
            .font(.body)
            .focused($inputFocused)
            .frame(minHeight: 120)
            .padding(.top, 12)
            .padding(.leading, 8)
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
            )
          if scratchpad.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Scratchpad — type or use the dictation shortcut to capture a note…")
              .foregroundColor(.secondary)
              .padding(.top, 12)
              .padding(.leading, 8)
          }
        }
        HStack(spacing: 12) {
          Button("Clear") { scratchpad.clearDraft() }
            .disabled(scratchpad.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          Button {
            Task {
              if let note = await scratchpad.addNote(titleGenerator: { text in
                try await vm.generateScratchpadTitle(for: text)
              }) {
                openNote(note)
              }
            }
          } label: {
            Label("Add Note", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .disabled(scratchpad.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scratchpad.isSaving)
        }
        if scratchpad.isSaving {
          ProgressView("Saving note…")
            .progressViewStyle(.linear)
        }
      }

      Divider()

      if scratchpad.notes.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "note.text")
            .font(.largeTitle)
            .foregroundColor(.secondary)
          Text("No notes yet")
            .font(.title3)
            .foregroundColor(.primary)
          Text("Capture ideas with the input above, or dictate directly into the scratchpad.")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(scratchpad.notes) { note in
              Button {
                openNote(note)
              } label: {
                ScratchpadNoteCardView(note: note)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button(role: .destructive) {
                  scratchpad.delete(note: note)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
          .padding(.vertical, 8)
        }
      }
    }
    .padding(20)
  }
}

private struct ScratchpadNoteCardView: View {
  let note: ScratchpadNote

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(note.title.isEmpty ? "Untitled Note" : note.title)
        .font(.headline)
      HStack(spacing: 8) {
        Text(note.createdAt, format: .dateTime.month().day().year())
        Text("·")
        Text(note.createdAt, format: .dateTime.hour().minute())
      }
      .font(.caption)
      .foregroundColor(.secondary)
      Text(note.previewText)
        .font(.body)
        .foregroundColor(.primary)
        .lineLimit(3)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(Color(nsColor: .textBackgroundColor))
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.secondary.opacity(0.15))
    )
  }
}

private struct ScratchpadNoteEditorView: View {
  @ObservedObject var vm: DictationViewModel
  @ObservedObject var scratchpad: ScratchpadViewModel
  let noteID: UUID
  var openPromptSettings: () -> Void
  @State private var selectedPromptID: UUID?

  var body: some View {
    if let note = scratchpad.notes.first(where: { $0.id == noteID }) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          TextField("Title", text: Binding(
            get: { note.title },
            set: { scratchpad.updateTitle(for: note.id, title: $0) }
          ))
          .font(.title2.weight(.semibold))
          .textFieldStyle(.plain)

          Text("Created \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Divider()

        ZStack(alignment: .topLeading) {
          TextEditor(text: Binding(
            get: { note.content },
            set: { scratchpad.updateContent(for: note.id, content: $0) }
          ))
          .font(.body)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.top, 12)
          .padding(.leading, 4)
          if note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Start writing or dictate to capture the full note…")
              .foregroundColor(.secondary)
              .padding(.top, 12)
              .padding(.leading, 4)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Picker("Prompt", selection: Binding(
              get: { selectedPromptID ?? vm.selectedPromptID ?? vm.prompts.first?.id },
              set: { selectedPromptID = $0 }
            )) {
              ForEach(vm.prompts) { prompt in
                Text(prompt.name).tag(Optional(prompt.id))
              }
            }
            .pickerStyle(.menu)

            Button {
              openPromptSettings()
            } label: {
              Label("Manage Prompts", systemImage: "slider.horizontal.3")
            }

            Spacer()

            Button {
              Task {
                guard let promptID = selectedPromptID ?? vm.selectedPromptID ?? vm.prompts.first?.id,
                      let prompt = vm.prompts.first(where: { $0.id == promptID }) else { return }
                _ = await scratchpad.runPrompt(on: note) { content in
                  try await vm.runScratchpadPrompt(content: content, prompt: prompt)
                }
              }
            } label: {
              Label("Run Prompt", systemImage: "sparkles")
            }
            .disabled(vm.prompts.isEmpty || note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
              Task {
                _ = await scratchpad.regenerateTitle(for: note) { content in
                  try await vm.generateScratchpadTitle(for: content)
                }
              }
            } label: {
              Label("Regenerate Title", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }

          if scratchpad.isProcessingPrompt {
            ProgressView("Processing with AI…")
          }
        }
      }
      .padding(20)
      .navigationTitle(note.title.isEmpty ? "Untitled Note" : note.title)
      .onAppear {
        if selectedPromptID == nil {
          selectedPromptID = vm.selectedPromptID ?? vm.prompts.first?.id
        }
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundColor(.secondary)
        Text("Note unavailable")
          .font(.headline)
        Text("This note may have been deleted.")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

#Preview {
  ScratchpadView(vm: DictationViewModel(), openPromptSettings: {})
}
