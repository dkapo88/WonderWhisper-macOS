import Foundation
import Combine

@MainActor
final class ScratchpadViewModel: ObservableObject {
  @Published var draftText: String = ""
  @Published private(set) var notes: [ScratchpadNote] = []
  @Published var isSaving: Bool = false
  @Published var isProcessingPrompt: Bool = false
  @Published var errorMessage: String?

  private let store: ScratchpadStore
  private var cancellables = Set<AnyCancellable>()

  init(store: ScratchpadStore? = nil) {
    let resolvedStore = store ?? ScratchpadStore()
    self.store = resolvedStore
    resolvedStore.$notes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.notes = $0 }
      .store(in: &cancellables)
  }

  func clearDraft() {
    draftText = ""
  }

  func addNote(titleGenerator: (String) async throws -> String) async -> ScratchpadNote? {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    isSaving = true
    defer { isSaving = false }
    do {
      let title = try await titleGenerator(trimmed)
      store.createNote(title: title.isEmpty ? Self.fallbackTitle(for: trimmed) : title, content: trimmed)
      draftText = ""
      return store.notes.first
    } catch {
      errorMessage = error.localizedDescription
      store.createNote(title: Self.fallbackTitle(for: trimmed), content: trimmed)
      draftText = ""
      return store.notes.first
    }
  }

  func delete(note: ScratchpadNote) {
    store.delete(note)
  }

  func updateContent(for noteID: UUID, content: String) {
    store.updateContent(id: noteID, content: content)
  }

  func updateTitle(for noteID: UUID, title: String) {
    store.updateTitle(id: noteID, title: title)
  }

  func runPrompt(on note: ScratchpadNote, generator: (String) async throws -> String) async -> ScratchpadNote? {
    isProcessingPrompt = true
    defer { isProcessingPrompt = false }
    do {
      let result = try await generator(note.content)
      store.updateContent(id: note.id, content: result.trimmingCharacters(in: .whitespacesAndNewlines))
      return store.notes.first(where: { $0.id == note.id })
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func regenerateTitle(for note: ScratchpadNote, generator: (String) async throws -> String) async -> String? {
    isProcessingPrompt = true
    defer { isProcessingPrompt = false }
    do {
      let title = try await generator(note.content)
      let final = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !final.isEmpty else { return nil }
      store.updateTitle(id: note.id, title: final)
      return final
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private static func fallbackTitle(for content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Untitled Note" }
    let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
    if firstLine.count <= 32 { return firstLine }
    let idx = firstLine.index(firstLine.startIndex, offsetBy: 32, limitedBy: firstLine.endIndex) ?? firstLine.endIndex
    return String(firstLine[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
