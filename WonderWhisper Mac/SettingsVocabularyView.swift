import SwiftUI

struct SettingsVocabularyView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var newEntry: String = ""
  @State private var duplicateWarning: String? = nil

  var body: some View {
    ScrollView {
      HStack(alignment: .top, spacing: 16) {
        GroupBox("Custom vocabulary") {
          VStack(alignment: .leading, spacing: 10) {
            Text("Add words that the transcriber should treat as known vocabulary.")
              .font(.caption)
              .foregroundColor(.secondary)

            HStack(spacing: 8) {
              TextField("Add new word", text: $newEntry, onCommit: addEntry)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .onChange(of: newEntry) { _ in duplicateWarning = nil }
              Button(action: addEntry) {
                Label("Add", systemImage: "plus")
              }
              .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let warning = duplicateWarning {
              Text(warning)
                .font(.caption)
                .foregroundColor(.red)
            }

            if vocabularyItems.isEmpty {
              Text("No custom vocabulary yet. Add words above to build your list.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
            } else {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                  ForEach(vocabularyItems, id: \.self) { item in
                    HStack {
                      Text(item)
                        .font(.body)
                      Spacer()
                      Button(role: .destructive) { removeEntry(item) } label: {
                        Image(systemName: "trash")
                      }
                      .buttonStyle(.borderless)
                    }
                    Divider()
                  }
                }
              }
              .frame(minHeight: 220, maxHeight: 260)
            }
          }
          .padding(.top, 4)
        }
        .frame(minWidth: 280, maxWidth: .infinity)

        GroupBox("Text replacements") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Use one rule per line in the form from=to")
              .font(.caption)
            TextEditor(text: $vm.vocabSpelling)
              .frame(minHeight: 260)
              .border(Color.gray.opacity(0.2))
            Text("Examples: steven=Stephen\nEZY pay=Ezypay")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
          .padding(.top, 4)
        }
        .frame(minWidth: 280, maxWidth: .infinity)
      }
      .padding(16)
    }
  }

  private var vocabularyItems: [String] {
    let separators = CharacterSet(charactersIn: ",\n")
    return vm.vocabCustom
      .components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func addEntry() {
    let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let exists = vocabularyItems.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    if exists {
      duplicateWarning = "\"\(trimmed)\" is already in your vocabulary."
      return
    }
    duplicateWarning = nil
    persistEntries(vocabularyItems + [trimmed])
    newEntry = ""
  }

  private func removeEntry(_ entry: String) {
    var items = vocabularyItems
    if let index = items.firstIndex(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
      items.remove(at: index)
      persistEntries(items)
    }
  }

  private func persistEntries(_ entries: [String]) {
    var seen = Set<String>()
    var ordered: [String] = []
    for entry in entries {
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if seen.insert(trimmed.lowercased()).inserted {
        ordered.append(trimmed)
      }
    }
    vm.vocabCustom = ordered.joined(separator: "\n")
  }
}
