import Foundation

struct HermesChatMessage: Identifiable, Codable, Equatable {
  enum Role: String, Codable, Equatable {
    case user
    case assistant
    case error
  }

  let id: UUID
  let role: Role
  let text: String
  let createdAt: Date
  let contextLabels: [String]
  let clipboardText: String?

  init(id: UUID = UUID(),
       role: Role,
       text: String,
       createdAt: Date = Date(),
       contextLabels: [String] = [],
       clipboardText: String? = nil) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.contextLabels = contextLabels
    self.clipboardText = clipboardText
  }
}
