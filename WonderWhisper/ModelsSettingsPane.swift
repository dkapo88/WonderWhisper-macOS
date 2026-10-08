import SwiftUI

/// Settings → Models: LLM post-processing, favorite models, gateway keys, and OpenRouter
/// request options.
struct ModelsSettingsPane: View {
  @ObservedObject var vm: DictationViewModel
  @State private var showModelBrowser = false

  var body: some View {
    SettingsPage {
      Section {
        Toggle(isOn: $vm.simpleLLMEnabled) {
          Text("Clean up transcripts with an LLM")
          Text("Turn off to insert the raw transcription without formatting.")
        }
      } header: {
        Text("Post-processing")
      }

      favoritesSection
      gatewaysSection
      openRouterOptionsSection
    }
    .sheet(isPresented: $showModelBrowser) {
      OpenRouterModelBrowserView(vm: vm)
    }
  }

  private var favoritesSection: some View {
    Section {
      if vm.favoriteOpenRouterModels.isEmpty {
        Text("No favorites yet. Browse a catalog to add models.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(vm.favoriteOpenRouterModels) { favorite in
          favoriteRow(favorite)
        }
      }
      HStack {
        Spacer()
        Button("Browse Models…") { showModelBrowser = true }
      }
    } header: {
      Text("Favorite models")
    } footer: {
      Text("The active model is used for dictation and command cleanup. Favorites also appear "
        + "in the meeting model pickers.")
        .settingsFootnote()
    }
  }

  private func favoriteRow(_ favorite: FavoriteOpenRouterModel) -> some View {
    let isActive = vm.simpleSelectedModel == favorite.id
    return LabeledContent {
      HStack(spacing: DesignTokens.Spacing.small) {
        if isActive {
          StatusBadge(.ok, "Active")
        } else {
          Button("Use") { vm.setActiveOpenRouterModel(id: favorite.id) }
            .accessibilityLabel("Use \(favorite.name)")
        }
        Button {
          vm.removeFavoriteOpenRouterModel(id: favorite.id)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove \(favorite.name) from favorites")
        .accessibilityLabel("Remove \(favorite.name) from favorites")
      }
    } label: {
      Text(favorite.name)
      Text(favorite.id)
        .monospaced()
    }
  }

  private var gatewaysSection: some View {
    Section {
      APIKeyRow(
        title: "OpenRouter",
        alias: AppConfig.openrouterAPIKeyAlias,
        prompt: "sk-or-…",
        onSave: vm.saveOpenRouterKey
      )
      APIKeyRow(
        title: "Vercel AI Gateway",
        alias: AppConfig.vercelGatewayAPIKeyAlias,
        onSave: vm.saveVercelGatewayKey
      )
    } header: {
      Text("LLM gateways")
    } footer: {
      Text("Each favorite routes through the gateway it was added from, so you can mix both "
        + "catalogs. Save a key for every gateway you use.")
        .settingsFootnote()
    }
  }

  private var openRouterOptionsSection: some View {
    Section {
      Picker(selection: $vm.openrouterRouting) {
        Text("Auto").tag("auto")
        Text("Latency").tag("latency")
        Text("Throughput").tag("throughput")
      } label: {
        Text("Routing priority")
        Text("Auto lets OpenRouter decide.")
      }
      .pickerStyle(.segmented)

      Picker(selection: $vm.openrouterReasoning) {
        ForEach(OpenRouterReasoningMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      } label: {
        Text("Reasoning")
        Text(vm.openrouterReasoning.detail)
      }
    } header: {
      Text("OpenRouter options")
    } footer: {
      Text("These apply to OpenRouter models only and are ignored for Vercel-routed models.")
        .settingsFootnote()
    }
  }
}
