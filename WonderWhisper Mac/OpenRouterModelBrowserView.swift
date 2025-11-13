import SwiftUI

struct OpenRouterModelBrowserView: View {
  @ObservedObject var vm: DictationViewModel
  @Environment(\.dismiss) private var dismiss
  
  @State private var searchText: String = ""
  @State private var models: [OpenRouterModel] = []
  @State private var isLoading: Bool = false
  @State private var errorMessage: String?
  @State private var sortOrder: SortOrder = .name
  
  enum SortOrder: String, CaseIterable {
    case name = "Name"
    case cost = "Cost"
    case contextLength = "Context"
    
    var displayName: String { rawValue }
  }
  
  var filteredModels: [OpenRouterModel] {
    let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var filtered = models
    
    if !search.isEmpty {
      filtered = models.filter { model in
        model.id.lowercased().contains(search) ||
        model.name.lowercased().contains(search) ||
        (model.description?.lowercased().contains(search) ?? false)
      }
    }
    
    switch sortOrder {
    case .name:
      filtered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .cost:
      filtered.sort { $0.pricing.promptCostPerMillion < $1.pricing.promptCostPerMillion }
    case .contextLength:
      filtered.sort { $0.contextLength > $1.contextLength }
    }
    
    return filtered
  }
  
  var body: some View {
    VStack(spacing: 0) {
      headerView
      
      Divider()
      
      if isLoading {
        loadingView
      } else if let error = errorMessage {
        errorView(error)
      } else {
        modelListView
      }
    }
    .frame(width: 700, height: 600)
    .onAppear {
      loadModels()
    }
  }
  
  private var headerView: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Browse OpenRouter Models")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary)
        TextField("Search models...", text: $searchText)
          .textFieldStyle(.plain)
        
        if !searchText.isEmpty {
          Button(action: { searchText = "" }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(8)
      .background(Color(nsColor: .controlBackgroundColor))
      .cornerRadius(6)
      
      HStack {
        Text("Sort by:")
          .font(.callout)
          .foregroundColor(.secondary)
        
        Picker("Sort", selection: $sortOrder) {
          ForEach(SortOrder.allCases, id: \.self) { order in
            Text(order.displayName).tag(order)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 250)
        
        Spacer()
        
        Text("\(filteredModels.count) models")
          .font(.callout)
          .foregroundColor(.secondary)
      }
    }
    .padding(20)
  }
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      Text("Loading models from OpenRouter...")
        .font(.callout)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private func errorView(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundColor(.orange)
      Text("Failed to load models")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      Button("Retry") {
        loadModels()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var modelListView: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(filteredModels) { model in
          modelRow(model)
          Divider()
        }
      }
    }
  }
  
  private func modelRow(_ model: OpenRouterModel) -> some View {
    let isFavorite = vm.favoriteOpenRouterModels.contains { $0.id == model.id }
    
    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(model.displayName)
          .font(.callout.weight(.semibold))
        
        Text(model.id)
          .font(.caption)
          .foregroundColor(.secondary)
        
        if let description = model.description {
          Text(description)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(2)
        }
        
        HStack(spacing: 12) {
          Label(model.costSummary, systemImage: "dollarsign.circle")
            .font(.caption2)
            .foregroundColor(.secondary)
          
          Label("\(model.contextLength.formatted()) tokens", systemImage: "text.alignleft")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
      
      Spacer()
      
      Button(action: {
        toggleFavorite(model)
      }) {
        HStack(spacing: 4) {
          Image(systemName: isFavorite ? "star.fill" : "star")
            .foregroundColor(isFavorite ? .yellow : .secondary)
          Text(isFavorite ? "Favorited" : "Add to Favorites")
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isFavorite ? Color.yellow.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .contentShape(Rectangle())
  }
  
  private func toggleFavorite(_ model: OpenRouterModel) {
    if vm.favoriteOpenRouterModels.contains(where: { $0.id == model.id }) {
      vm.removeFavoriteOpenRouterModel(id: model.id)
    } else {
      vm.addFavoriteOpenRouterModel(id: model.id, name: model.displayName)
    }
  }
  
  private func loadModels() {
    isLoading = true
    errorMessage = nil
    
    Task {
      do {
        let keychain = KeychainService()
        let apiKey = keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias)
        let client = OpenRouterHTTPClient(apiKeyProvider: { apiKey })
        let fetchedModels = try await client.fetchModels()
        
        await MainActor.run {
          self.models = fetchedModels
          self.isLoading = false
        }
      } catch {
        await MainActor.run {
          self.errorMessage = error.localizedDescription
          self.isLoading = false
        }
      }
    }
  }
}

#Preview {
  OpenRouterModelBrowserView(vm: DictationViewModel())
}
