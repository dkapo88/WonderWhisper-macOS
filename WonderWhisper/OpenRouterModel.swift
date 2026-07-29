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

// MARK: - Vercel AI Gateway catalog

/// Vercel's `/v1/models` uses different field names; decode and map into `OpenRouterModel`
/// so the browser, favorites, and pickers need no second model type. IDs are prefixed with
/// `AppConfig.vercelModelPrefix` at mapping time so the stored favorite carries its route.
struct VercelModelsResponse: Codable {
  struct Model: Codable {
    struct Pricing: Codable {
      let input: String?
      let output: String?
    }
    let id: String
    let name: String?
    let description: String?
    let contextWindow: Int?
    let type: String?
    let pricing: Pricing?

    enum CodingKeys: String, CodingKey {
      case id, name, description, type, pricing
      case contextWindow = "context_window"
    }
  }
  let data: [Model]

  var asOpenRouterModels: [OpenRouterModel] {
    data
      .filter { ($0.type ?? "language") == "language" }
      .map { model in
        OpenRouterModel(
          id: AppConfig.vercelModelPrefix + model.id,
          name: (model.name?.isEmpty == false ? model.name! : model.id) + " (Vercel)",
          description: model.description,
          contextLength: model.contextWindow ?? 0,
          pricing: .init(prompt: model.pricing?.input ?? "0",
                         completion: model.pricing?.output ?? "0")
        )
      }
  }
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
