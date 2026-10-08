import SwiftUI
import AppKit

struct ModelComparisonRequest {
  let model: FavoriteOpenRouterModel
  let reasoning: OpenRouterReasoningMode
}

struct ModelComparisonResult: Identifiable, Equatable {
  let id = UUID()
  let modelID: String
  let modelName: String
  let reasoning: OpenRouterReasoningMode
  let output: String
  let duration: TimeInterval
  let errorMessage: String?

  var succeeded: Bool { errorMessage == nil }
}

struct ModelComparisonView: View {
  @ObservedObject var vm: DictationViewModel

  @State private var rawText = ""
  @State private var selectedModelIDs: Set<String> = []
  @State private var reasoningByModel: [String: OpenRouterReasoningMode] = [:]
  @State private var runMode: ModelComparisonRunMode = .parallel
  @State private var isProcessing = false
  @State private var results: [ModelComparisonResult] = []

  private var selectedModels: [FavoriteOpenRouterModel] {
    vm.favoriteOpenRouterModels.filter { selectedModelIDs.contains($0.id) }
  }

  private var canProcess: Bool {
    !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !selectedModels.isEmpty
      && !isProcessing
  }

  var body: some View {
    SettingsPage {
      Section {
        TextEditor(text: $rawText)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 140)
          .accessibilityLabel("Raw text to compare")
      } header: {
        Text("Raw text")
      } footer: {
        Text("Paste a raw transcript. Each selected model cleans it up with the Dictation prompt.")
          .settingsFootnote()
      }

      Section {
        if vm.favoriteOpenRouterModels.isEmpty {
          Text("Add favorite models in Settings → Models to compare them.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(vm.favoriteOpenRouterModels) { model in
            modelRow(model)
          }
        }
      } header: {
        HStack {
          Text("Models")
          Spacer()
          Button(selectedModelIDs.count == vm.favoriteOpenRouterModels.count
            ? "Clear Selection"
            : "Select All"
          ) {
            if selectedModelIDs.count == vm.favoriteOpenRouterModels.count {
              clearSelectedModels()
            } else {
              selectAllModels()
            }
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(vm.favoriteOpenRouterModels.isEmpty || isProcessing)
        }
      }

      Section {
        if results.isEmpty {
          Text(isProcessing ? "Processing…" : "Results appear here after you run a comparison.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(results) { result in
            resultView(result)
          }
        }
      } header: {
        Text("Results")
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Picker("Run mode", selection: $runMode) {
          ForEach(ModelComparisonRunMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .disabled(isProcessing)
        .help("Run models at the same time or one after another")

        Button {
          Task { await runComparison() }
        } label: {
          Label("Compare", systemImage: "play")
            .labelStyle(.titleAndIcon)
        }
        .disabled(!canProcess)
        .help("Run the raw text through every selected model")
      }
    }
    .onAppear(perform: ensureInitialSelection)
    .onChange(of: vm.favoriteOpenRouterModels) { _, _ in
      reconcileSelectionWithFavorites()
    }
  }

  private func modelRow(_ model: FavoriteOpenRouterModel) -> some View {
    let isSelected = Binding(
      get: { selectedModelIDs.contains(model.id) },
      set: { newValue in
        if newValue != selectedModelIDs.contains(model.id) { toggle(model) }
      }
    )
    return HStack(spacing: DesignTokens.Spacing.small) {
      Toggle(isOn: isSelected) {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.name)
          Text(model.id)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.checkbox)
      .disabled(isProcessing)
      .layoutPriority(1)

      Spacer()

      Text("Reasoning")
        .foregroundStyle(.secondary)
      Picker("Reasoning", selection: reasoningBinding(for: model.id)) {
        ForEach(OpenRouterReasoningMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .labelsHidden()
      .fixedSize()
      .disabled(isProcessing || !isSelected.wrappedValue)
      .accessibilityLabel("Reasoning for \(model.name)")
    }
  }

  private func resultView(_ result: ModelComparisonResult) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xSmall) {
        Text(result.modelName)
          .font(.headline)
        Spacer()
        Text("\(String(format: "%.2f", result.duration)) s · Reasoning \(result.reasoning.displayName)")
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
        if result.succeeded {
          Button {
            copy(result.output)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy output")
          .accessibilityLabel("Copy \(result.modelName) output")
        }
      }

      if let error = result.errorMessage {
        StatusBadge(.error, error)
          .textSelection(.enabled)
      } else {
        Text(result.output.isEmpty ? "No output." : result.output)
          .foregroundStyle(result.output.isEmpty ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.xxSmall)
  }

  private func toggle(_ model: FavoriteOpenRouterModel) {
    if selectedModelIDs.contains(model.id) {
      selectedModelIDs.remove(model.id)
    } else {
      selectedModelIDs.insert(model.id)
      reasoningByModel[model.id] = reasoningByModel[model.id] ?? .off
    }
  }

  private func selectAllModels() {
    selectedModelIDs = Set(vm.favoriteOpenRouterModels.map(\.id))
    for model in vm.favoriteOpenRouterModels {
      reasoningByModel[model.id] = reasoningByModel[model.id] ?? .off
    }
  }

  private func clearSelectedModels() {
    selectedModelIDs.removeAll()
  }

  private func reasoningBinding(for modelID: String) -> Binding<OpenRouterReasoningMode> {
    Binding(
      get: { reasoningByModel[modelID] ?? .off },
      set: { reasoningByModel[modelID] = $0 }
    )
  }

  private func ensureInitialSelection() {
    guard selectedModelIDs.isEmpty else { return }
    let active = vm.simpleSelectedModel.lowercased()
    if let activeFavorite = vm.favoriteOpenRouterModels.first(where: { $0.id.lowercased() == active }) {
      selectedModelIDs.insert(activeFavorite.id)
      reasoningByModel[activeFavorite.id] = .off
    } else if let first = vm.favoriteOpenRouterModels.first {
      selectedModelIDs.insert(first.id)
      reasoningByModel[first.id] = .off
    }
  }

  private func reconcileSelectionWithFavorites() {
    let validIDs = Set(vm.favoriteOpenRouterModels.map(\.id))
    selectedModelIDs = selectedModelIDs.intersection(validIDs)
    reasoningByModel = reasoningByModel.filter { validIDs.contains($0.key) }
    ensureInitialSelection()
  }

  private func runComparison() async {
    let models = selectedModels
    guard canProcess, !models.isEmpty else { return }
    isProcessing = true
    defer { isProcessing = false }

    results = await vm.compareRawTextAcrossModels(
      rawText,
      models: models,
      reasoningByModel: reasoningByModel,
      runConcurrently: runMode == .parallel
    )
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private enum ModelComparisonRunMode: String, CaseIterable, Identifiable {
  case parallel
  case sequential

  var id: String { rawValue }

  var title: String {
    switch self {
    case .parallel: return "Parallel"
    case .sequential: return "Sequential"
    }
  }
}

#Preview {
  ModelComparisonView(vm: DictationViewModel())
}
