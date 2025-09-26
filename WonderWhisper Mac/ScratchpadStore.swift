import Foundation
import Combine

@MainActor
final class ScratchpadStore: ObservableObject {
  @Published private(set) var notes: [ScratchpadNote] = []

  private let fileURL: URL
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return encoder
  }()
  private let decoder = JSONDecoder()

  init() {
    let fm = FileManager.default
    let appSupport: URL
    do {
      appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    } catch {
      appSupport = URL(fileURLWithPath: "/tmp/WonderWhisper")
    }
    let root = appSupport.appendingPathComponent("WonderWhisper", isDirectory: true)
    let dir = root.appendingPathComponent("Scratchpad", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    fileURL = dir.appendingPathComponent("notes.json")
    load()
  }

  func load() {
    guard let data = try? Data(contentsOf: fileURL) else {
      notes = []
      return
    }
    if let decoded = try? decoder.decode([ScratchpadNote].self, from: data) {
      notes = decoded.sorted { $0.createdAt > $1.createdAt }
    } else {
      notes = []
    }
  }

  func createNote(title: String, content: String, createdAt: Date = Date()) {
    var note = ScratchpadNote(createdAt: createdAt, title: title, content: content)
    note.updatedAt = createdAt
    notes.insert(note, at: 0)
    persist()
  }

  func upsert(_ note: ScratchpadNote) {
    if let idx = notes.firstIndex(where: { $0.id == note.id }) {
      var updated = note
      updated.updatedAt = Date()
      notes[idx] = updated
    } else {
      notes.insert(note, at: 0)
    }
    notes.sort { $0.createdAt > $1.createdAt }
    persist()
  }

  func updateContent(id: UUID, content: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].content = content
    notes[idx].updatedAt = Date()
    persist()
  }

  func updateTitle(id: UUID, title: String) {
    guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[idx].title = title
    notes[idx].updatedAt = Date()
    persist()
  }

  func delete(_ note: ScratchpadNote) {
    notes.removeAll { $0.id == note.id }
    persist()
  }

  private func persist() {
    do {
      let data = try encoder.encode(notes.sorted { $0.createdAt > $1.createdAt })
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // Ignore persistence failures for now.
    }
  }
}
