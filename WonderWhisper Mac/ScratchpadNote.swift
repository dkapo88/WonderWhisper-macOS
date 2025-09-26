import Foundation

struct ScratchpadNote: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var title: String
    var content: String

    init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date? = nil, title: String, content: String) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.title = title
        self.content = content
    }
}

extension ScratchpadNote {
    static let preview = ScratchpadNote(title: "Project Kickoff", content: "Discuss timeline, responsibilities, and next steps for WonderWhisper Mac launch.")

    var previewText: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 160)
        return trimmed[..<idx].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
