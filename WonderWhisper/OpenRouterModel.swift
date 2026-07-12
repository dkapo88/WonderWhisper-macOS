import Foundation

// MARK: - OpenRouter Model Data Structures

struct OpenRouterModel: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let description: String?
  let contextLength: Int
  let pricing: Pricing

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case contextLength = "context_length"
    case pricing
  }
  
  struct Pricing: Codable, Hashable {
    let prompt: String
    let completion: String
    
    var promptCostPerMillion: Double {
      (Double(prompt) ?? 0) * 1_000_000
    }
    
    var completionCostPerMillion: Double {
      (Double(completion) ?? 0) * 1_000_000
    }
  }
  
  var displayName: String {
    name
  }
  
  var costSummary: String {
    let promptCost = pricing.promptCostPerMillion
    let completionCost = pricing.completionCostPerMillion
    
    if promptCost == 0 && completionCost == 0 {
      return "Free"
    }
    
    return String(format: "$%.2f / $%.2f per 1M tokens", promptCost, completionCost)
  }
}

struct OpenRouterModelsResponse: Codable {
  let data: [OpenRouterModel]
}

// MARK: - Favorite Model

struct FavoriteOpenRouterModel: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var addedAt: Date
  
  init(id: String, name: String, addedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.addedAt = addedAt
  }
}
