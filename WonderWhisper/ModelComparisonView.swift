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
    VStack(spacing: 0) {
      controls
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          inputSection
          selectedModelSection
          resultsSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear(perform: ensureInitialSelection)
    .onChange(of: vm.favoriteOpenRouterModels) { _, _ in
      reconcileSelectionWithFavorites()
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Menu {
        if vm.favoriteOpenRouterModels.isEmpty {
          Text("No favorite models")
        } else {
          Button {
            selectAllModels()
          } label: {
            Label("Select All", systemImage: "checkmark.circle")
          }

          Button {
            clearSelectedModels()
          } label: {
            Label("Clear Selection", systemImage: "xmark.circle")
          }
          .disabled(selectedModelIDs.isEmpty)

          Divider()

          ForEach(vm.favoriteOpenRouterModels) { model in
            Button {
              toggle(model)
            } label: {
              HStack {
                if selectedModelIDs.contains(model.id) {
                  Image(systemName: "checkmark")
                }
                Text(model.name)
              }
            }
          }
        }
      } label: {
        Label(modelSelectionTitle, systemImage: "list.bullet.rectangle")
      }
      .menuStyle(.borderlessButton)
      .disabled(vm.favoriteOpenRouterModels.isEmpty || isProcessing)

      Picker("Run mode", selection: $runMode) {
        ForEach(ModelComparisonRunMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 220)
      .disabled(isProcessing)

      Spacer()

      Button {
        Task { await runComparison() }
      } label: {
        if isProcessing {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Process", systemImage: "play.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canProcess)
    }
  }

  private var inputSection: some View {
    GroupBox("Raw Text") {
      TextEditor(text: $rawText)
        .font(.body)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 160)
        .padding(6)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
        )
    }
  }

  private var selectedModelSection: some View {
    GroupBox("Models") {
      if selectedModels.isEmpty {
        Text("Select one or more favorite models to compare.")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 6)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(selectedModels) { model in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                  .font(.callout.weight(.medium))
                Text(model.id)
                  .font(.caption2)
                  .foregroundColor(.secondary)
                  .textSelection(.enabled)
              }

              Spacer()

              Picker("Reasoning", selection: reasoningBinding(for: model.id)) {
                ForEach(OpenRouterReasoningMode.allCases, id: \.self) { mode in
                  Text(mode.displayName).tag(mode)
                }
              }
              .labelsHidden()
              .frame(width: 180)
              .disabled(isProcessing)
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
  }

  private var resultsSection: some View {
    GroupBox("Output Comparison") {
      if results.isEmpty {
        Text("Results will appear after processing.")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 6)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(results) { result in
            resultView(result)
          }
        }
      }
    }
  }

  private func resultView(_ result: ModelComparisonResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(result.modelName)
          .font(.headline)
        Text(result.modelID)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
        Spacer()
        Label(String(format: "%.2fs", result.duration), systemImage: "timer")
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
        Text(result.reasoning.displayName)
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
      }

      if let error = result.errorMessage {
        Text(error)
          .foregroundColor(.red)
          .textSelection(.enabled)
      } else {
        Text(result.output.isEmpty ? "(empty)" : result.output)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)

        HStack {
          Spacer()
          Button {
            copy(result.output)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .windowBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.12))
    )
  }

  private var modelSelectionTitle: String {
    switch selectedModelIDs.count {
    case 0:
      return "Select Models"
    case 1:
      return selectedModels.first?.name ?? "1 Model"
    default:
      return "\(selectedModelIDs.count) Models"
    }
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
