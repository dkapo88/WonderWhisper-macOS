import SwiftUI

struct OpenRouterModelBrowserView: View {
  @ObservedObject var vm: DictationViewModel
  @Environment(\.dismiss) private var dismiss
  
  @State private var searchText: String = ""
  @State private var models: [OpenRouterModel] = []
  @State private var isLoading: Bool = false
  @State private var errorMessage: String?
  @State private var sortOrder: SortOrder = .name
  @State private var catalog: Catalog = .openRouter

  enum Catalog: String, CaseIterable {
    case openRouter = "OpenRouter"
    case vercel = "Vercel AI Gateway"
  }
  
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
    VStack(spacing: DesignTokens.Spacing.small) {
      HStack {
        Text("Browse Models")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }

      Picker("Catalog", selection: $catalog) {
        ForEach(Catalog.allCases, id: \.self) { source in
          Text(source.rawValue).tag(source)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .onChange(of: catalog) { _, _ in loadModels() }
      
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary)
        TextField("Search models", text: $searchText)
          .textFieldStyle(.plain)
          .accessibilityLabel("Search models")
        
        if !searchText.isEmpty {
          Button(action: { searchText = "" }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(DesignTokens.Spacing.xSmall)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
      )
      
      HStack {
        Text("Sort by:")
          .font(.callout)
          .foregroundColor(.secondary)
        
        Picker("Sort by", selection: $sortOrder) {
          ForEach(SortOrder.allCases, id: \.self) { order in
            Text(order.displayName).tag(order)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Sort models by")
        .frame(maxWidth: 250)
        
        Spacer()
        
        Text("\(filteredModels.count) models")
          .foregroundStyle(.secondary)
      }
    }
    .padding(DesignTokens.Spacing.medium)
  }
  
  private var loadingView: some View {
    ProgressView("Loading models from \(catalog.rawValue)…")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn't load models", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Retry") { loadModels() }
    }
  }

  private var modelListView: some View {
    List(filteredModels) { model in
      modelRow(model)
    }
    .listStyle(.inset)
    .overlay {
      if filteredModels.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  private func modelRow(_ model: OpenRouterModel) -> some View {
    let isFavorite = vm.favoriteOpenRouterModels.contains { $0.id == model.id }

    return HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
        Text(model.displayName)
          .font(.body.weight(.semibold))

        Text(model.id)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)

        if let description = model.description {
          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        HStack(spacing: DesignTokens.Spacing.small) {
          Label(model.costSummary, systemImage: "dollarsign.circle")
          Label("\(model.contextLength.formatted()) tokens", systemImage: "text.alignleft")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        toggleFavorite(model)
      } label: {
        Label(
          isFavorite ? "Favorite" : "Add to Favorites",
          systemImage: isFavorite ? "star.fill" : "star"
        )
      }
      .buttonStyle(.bordered)
      .tint(isFavorite ? .yellow : nil)
      .accessibilityLabel(
        isFavorite ? "Remove \(model.displayName) from favorites" : "Add \(model.displayName) to favorites"
      )
    }
    .padding(.vertical, DesignTokens.Spacing.xxSmall)
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
    let source = catalog

    Task {
      do {
        let keychain = KeychainService()
        let apiKey = keychain.getSecret(forKey: source == .vercel
          ? AppConfig.vercelGatewayAPIKeyAlias
          : AppConfig.openrouterAPIKeyAlias)
        let client = OpenRouterHTTPClient(apiKeyProvider: { apiKey })
        let fetchedModels = source == .vercel
          ? try await client.fetchVercelModels()
          : try await client.fetchModels()

        await MainActor.run {
          guard source == self.catalog else { return }  // stale response after a toggle
          self.models = fetchedModels
          self.isLoading = false
        }
      } catch {
        await MainActor.run {
          guard source == self.catalog else { return }
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
