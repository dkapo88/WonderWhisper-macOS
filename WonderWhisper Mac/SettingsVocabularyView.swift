import SwiftUI

struct SettingsVocabularyView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var newEntry: String = ""
  @State private var duplicateWarning: String? = nil
  @State private var replaceSource: String = ""
  @State private var replaceTarget: String = ""
  @State private var replacementWarning: String? = nil

  var body: some View {
    ScrollView {
      if #available(macOS 13.0, *) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            customVocabularySection
            textReplacementSection
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(spacing: 16) {
            customVocabularySection
            textReplacementSection
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
      } else {
        VStack(spacing: 16) {
          customVocabularySection
          textReplacementSection
        }
        .padding(16)
      }
    }
  }

  private var customVocabularySection: some View {
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
          .frame(minHeight: 220, maxHeight: .infinity)
        }
      }
      .padding(.top, 4)
    }
    .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
  }

  private var textReplacementSection: some View {
    GroupBox("Text replacements") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Automatically substitute spoken phrases with your preferred wording.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack(spacing: 8) {
          TextField("Heard phrase", text: $replaceSource, onCommit: addReplacement)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160)
            .onChange(of: replaceSource) { _ in replacementWarning = nil }
          Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
          TextField("Replace with", text: $replaceTarget, onCommit: addReplacement)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160)
            .onChange(of: replaceTarget) { _ in replacementWarning = nil }
          Button(action: addReplacement) {
            Label("Add", systemImage: "plus")
          }
          .disabled(replaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replaceTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if let warning = replacementWarning {
          Text(warning)
            .font(.caption)
            .foregroundColor(.red)
        }

        if replacementItems.isEmpty {
          Text("No text replacements yet. Add a phrase above to get started.")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(replacementItems, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(item.from)
                    .font(.body)
                  Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                  Text(item.to)
                    .font(.body)
                  Spacer()
                  Button(role: .destructive) { removeReplacement(item) } label: {
                    Image(systemName: "trash")
                  }
                  .buttonStyle(.borderless)
                }
                Divider()
              }
            }
          }
          .frame(minHeight: 220, maxHeight: .infinity)
        }

        Text("Tip: rules are case-insensitive and applied before LLM post-processing.")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)
    }
    .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
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

  private var replacementItems: [ReplacementItem] {
    vm.vocabSpelling
      .components(separatedBy: CharacterSet.newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .compactMap { line in
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return ReplacementItem(from: parts[0], to: parts[1])
      }
  }

  private func addReplacement() {
    let from = replaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
    let to = replaceTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !from.isEmpty, !to.isEmpty else { return }
    let duplicate = replacementItems.contains { $0.from.caseInsensitiveCompare(from) == .orderedSame }
    if duplicate {
      replacementWarning = "\"\(from)\" already has a replacement."
      return
    }
    replacementWarning = nil
    persistReplacements(replacementItems + [ReplacementItem(from: from, to: to)])
    replaceSource = ""
    replaceTarget = ""
  }

  private func removeReplacement(_ entry: ReplacementItem) {
    var items = replacementItems
    if let index = items.firstIndex(of: entry) {
      items.remove(at: index)
      persistReplacements(items)
    }
  }

  private func persistReplacements(_ entries: [ReplacementItem]) {
    let unique = entries.reduce(into: [ReplacementItem]()) { result, item in
      let exists = result.contains { $0.from.caseInsensitiveCompare(item.from) == .orderedSame }
      if !exists {
        result.append(ReplacementItem(from: item.from, to: item.to))
      }
    }
    let serialized = unique.map { "\($0.from)=\($0.to)" }.joined(separator: "\n")
    vm.vocabSpelling = serialized
  }

  private struct ReplacementItem: Hashable {
    let from: String
    let to: String
  }
}
