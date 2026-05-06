import Foundation

struct HermesChatMessage: Identifiable, Equatable {
  enum Role: String, Equatable {
    case user
    case assistant
    case error
  }

  let id: UUID
  let role: Role
  let text: String
  let createdAt: Date
  let contextLabels: [String]

  init(id: UUID = UUID(),
       role: Role,
       text: String,
       createdAt: Date = Date(),
       contextLabels: [String] = []) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.contextLabels = contextLabels
  }
}
