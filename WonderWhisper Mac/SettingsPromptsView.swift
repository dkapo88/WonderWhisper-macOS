import SwiftUI
import Carbon.HIToolbox
import AppKit

struct SettingsPromptsView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var renamingPromptID: UUID?
    @State private var nameDraft: String = ""
    @State private var capturingPromptID: UUID?
    @State private var draggedPromptID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragBaseTranslation: CGFloat = 0
    @State private var promptHeights: [UUID: CGFloat] = [:]
    // Track indices during an active drag, without committing reorder to the model.
    @State private var dragStartIndex: Int?
    @State private var dragCurrentIndex: Int?
    @State private var expandedPromptIDs: Set<UUID> = []

    private let promptSpacing: CGFloat = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        promptList
                        promptEditor
                    }
                    VStack(spacing: 16) {
                        promptList
                        promptEditor
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: vm.selectedPromptID) { newValue in
            guard let id = newValue else { return }
            expandedPromptIDs.insert(id)
        }
        .onAppear {
            if expandedPromptIDs.isEmpty, let id = vm.selectedPromptID ?? vm.prompts.first?.id {
                expandedPromptIDs.insert(id)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Prompt Library")
                .font(.title2)
                .bold()
            Spacer()
            Button {
                vm.addPrompt()
            } label: {
                Label("Add Prompt", systemImage: "plus")
            }
        }
    }

    private var promptList: some View {
        GroupBox("Saved prompts") {
            if vm.prompts.isEmpty {
                Text("No prompts yet. Use \"Add Prompt\" to create one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.prompts) { prompt in
                            let isDragging = draggedPromptID == prompt.id
                            promptRow(prompt, isDragging: isDragging)
                                .padding(12)
                                .background(selectionBackground(for: prompt, isDragging: isDragging))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(heightReader(for: prompt))
                                .offset(y: rowOffset(for: prompt))
                                .shadow(color: isDragging ? Color.black.opacity(0.18) : .clear, radius: isDragging ? 10 : 0, y: isDragging ? 6 : 0)
                                .zIndex(isDragging ? 10 : 0)
                                // Animate rows shifting out of the way and the dragged card moving
                                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.15), value: dragOffset)
                                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.15), value: dragCurrentIndex)
                                .highPriorityGesture(dragGesture(for: prompt))
                        }
                    }
                    .onPreferenceChange(PromptRowHeightPreferenceKey.self) { newHeights in
                        promptHeights.merge(newHeights) { _, new in new }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
    }

    private func promptRow(_ prompt: PromptConfiguration, isDragging _: Bool) -> some View {
        let expanded = expandedPromptIDs.contains(prompt.id)
        let summary = triggerSummary(for: prompt)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    toggleExpansion(for: prompt.id)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)

                if renamingPromptID == prompt.id {
                    TextField("Prompt name", text: $nameDraft, onCommit: {
                        vm.renamePrompt(id: prompt.id, to: nameDraft)
                        renamingPromptID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                } else {
                    Text(prompt.name)
                        .fontWeight(vm.selectedPromptID == prompt.id ? .semibold : .regular)
                        .foregroundColor(vm.selectedPromptID == prompt.id ? .accentColor : .primary)
                }

                Spacer()

                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if vm.prompts.count > 1 {
                    Button(role: .destructive) {
                        vm.deletePrompt(id: prompt.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    if renamingPromptID == prompt.id {
                        vm.renamePrompt(id: prompt.id, to: nameDraft)
                        renamingPromptID = nil
                    } else {
                        renamingPromptID = prompt.id
                        nameDraft = prompt.name
                    }
                } label: {
                    Text(renamingPromptID == prompt.id ? "Done" : "Rename")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if renamingPromptID != prompt.id {
                    vm.selectPrompt(id: prompt.id)
                }
            }

            if expanded {
                PromptTriggerEditor(
                    prompt: prompt,
                    capturingPromptID: $capturingPromptID,
                    onShortcutChange: { vm.updateShortcut(for: prompt.id, to: $0) },
                    onSelectionChange: { vm.updateSelection(for: prompt.id, to: $0) }
                )
                .padding(.leading, 22)
                .padding(.top, 2)
            }
        }
    }

    private func toggleExpansion(for id: UUID) {
        if expandedPromptIDs.contains(id) {
            expandedPromptIDs.remove(id)
        } else {
            expandedPromptIDs.insert(id)
        }
    }

    private func triggerSummary(for prompt: PromptConfiguration) -> String {
        if let selection = prompt.selection {
            return "Key: \(selection.displayName)"
        }
        if let shortcut = prompt.shortcut {
            return shortcutDescription(shortcut)
        }
        return "No trigger"
    }

    private func selectionBackground(for prompt: PromptConfiguration, isDragging: Bool) -> some View {
        let baseFill = Color(nsColor: .controlBackgroundColor)
        let isSelected = vm.selectedPromptID == prompt.id

        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(baseFill)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isDragging ? Color.accentColor.opacity(0.65) : (isSelected ? Color.accentColor.opacity(0.45) : Color.black.opacity(0.08)),
                        lineWidth: isDragging ? 1.6 : (isSelected ? 1.2 : 1)
                    )
            )
    }

    private func dragGesture(for prompt: PromptConfiguration) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard renamingPromptID == nil else { return }
                if draggedPromptID == nil {
                    draggedPromptID = prompt.id
                    dragOffset = 0
                    dragBaseTranslation = 0
                    // Snapshot starting index once at drag begin
                    dragStartIndex = vm.prompts.firstIndex(where: { $0.id == prompt.id })
                    dragCurrentIndex = dragStartIndex
                }
                guard draggedPromptID == prompt.id else { return }
                handleDragChange(for: prompt.id, translation: value.translation.height)
            }
            .onEnded { _ in
                guard draggedPromptID == prompt.id else { return }
                let start = dragStartIndex
                let target = dragCurrentIndex
                // Reset visual offsets first so the commit animates smoothly
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.82, blendDuration: 0.2)) {
                    dragOffset = 0
                }
                draggedPromptID = nil
                dragBaseTranslation = 0
                let spring = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.85, blendDuration: 0.15)
                if let s = start, let t = target, s != t {
                    withAnimation(spring) {
                        // Commit a single reorder to the model to avoid mid-drag churn
                        if s < vm.prompts.count, t < vm.prompts.count, s >= 0, t >= 0 {
                            vm.movePrompt(id: vm.prompts[s].id, to: t)
                        }
                    }
                }
                dragStartIndex = nil
                dragCurrentIndex = nil
            }
    }

    private func handleDragChange(for promptID: UUID, translation: CGFloat) {
        guard let startIndex = dragStartIndex else { return }
        guard var currentIndex = dragCurrentIndex ?? vm.prompts.firstIndex(where: { $0.id == promptID }) else { return }
        let defaultHeight: CGFloat = 72
        let draggedHeight = promptHeights[promptID] ?? defaultHeight

        var delta = translation - dragBaseTranslation

        // Move down: cross into the next index when the dragged card's center passes
        // the neighbor's center. Threshold = half dragged + spacing + half neighbor.
        while currentIndex < vm.prompts.count - 1 {
            let nextID = vm.prompts[currentIndex + 1].id
            let nextH = promptHeights[nextID] ?? defaultHeight
            let step = (draggedHeight / 2) + promptSpacing + (nextH / 2)
            guard delta > step else { break }
            dragBaseTranslation += step
            currentIndex += 1
            delta = translation - dragBaseTranslation
        }

        // Move up: symmetric threshold vs the previous neighbor
        while currentIndex > 0 {
            let prevID = vm.prompts[currentIndex - 1].id
            let prevH = promptHeights[prevID] ?? defaultHeight
            let step = (draggedHeight / 2) + promptSpacing + (prevH / 2)
            guard delta < -step else { break }
            dragBaseTranslation -= step
            currentIndex -= 1
            delta = translation - dragBaseTranslation
        }

        dragOffset = translation
        dragCurrentIndex = currentIndex
    }

    // Compute per-row offset during an active drag without mutating the model array.
    private func rowOffset(for prompt: PromptConfiguration) -> CGFloat {
        guard let draggedID = draggedPromptID,
              let from = dragStartIndex,
              let to = dragCurrentIndex,
              let idx = vm.prompts.firstIndex(where: { $0.id == prompt.id }) else { return 0 }

        if prompt.id == draggedID { return dragOffset }

        let defaultHeight: CGFloat = 72
        let draggedHeight = promptHeights[draggedID] ?? defaultHeight
        let shift = draggedHeight + promptSpacing

        if to > from {
            // Rows between from+1...to shift up to make space
            if idx > from && idx <= to { return -shift }
        } else if to < from {
            // Rows between to...from-1 shift down to make space
            if idx >= to && idx < from { return +shift }
        }
        return 0
    }

    private func heightReader(for prompt: PromptConfiguration) -> some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PromptRowHeightPreferenceKey.self, value: [prompt.id: proxy.size.height])
        }
    }

    private var promptEditor: some View {
        GroupBox("Prompt editor") {
            if let prompt = vm.prompts.prompt(withID: vm.selectedPromptID) ?? vm.prompts.first {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Prompt Settings")
                            .font(.headline)

                        PromptLLMModelEditor(
                            prompt: prompt,
                            defaultModel: vm.llmModel,
                            provider: vm.llmProvider,
                            favorites: vm.favoriteLLMModels,
                            onUpdate: { model, provider in vm.updateLLMOverride(for: prompt.id, model: model, provider: provider) }
                        )

                        PromptScreenContextEditor(
                            prompt: prompt,
                            defaultScreenContext: vm.screenContextEnabled,
                            defaultPreprocess: vm.screenContextPreprocessingMode,
                            onScreenUpdate: { vm.updateScreenContextOverride(for: prompt.id, to: $0) },
                            onPreprocessUpdate: { vm.updateScreenContextPreprocessingOverride(for: prompt.id, to: $0) }
                        )
                    }

                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("System Prompt")
                            .font(.headline)
                        TextEditor(text: $vm.systemPrompt)
                            .frame(minHeight: 160)
                            .border(Color.gray.opacity(0.2))
                        Button("Reset to Default") {
                            vm.systemPrompt = AppConfig.defaultSystemPromptTemplate
                        }
                        .disabled(vm.systemPrompt == AppConfig.defaultSystemPromptTemplate)
                        .padding(.bottom, 8)

                        Text("User Prompt")
                            .font(.headline)
                        TextEditor(text: $vm.userPrompt)
                            .frame(minHeight: 100)
                            .border(Color.gray.opacity(0.2))
                        HStack {
                            Button("Clear") { vm.userPrompt = "" }
                            Spacer()
                            Text("Editing: \(prompt.name)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text("Select a prompt to edit its content.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PromptTriggerEditor: View {
    enum TriggerMode: String, CaseIterable, Identifiable {
        // Order matters: show Single Key (selection) on the left
        case selection
        case shortcut

        var id: String { rawValue }
        var label: String {
            switch self {
            case .selection: return "Single Key"
            case .shortcut: return "Key Combination"
            }
        }
    }

    let prompt: PromptConfiguration
    @Binding var capturingPromptID: UUID?
    let onShortcutChange: (HotkeyManager.Shortcut?) -> Void
    let onSelectionChange: (HotkeyManager.Selection?) -> Void

    @State private var mode: TriggerMode
    @State private var selectionValue: HotkeyManager.Selection?

    private var isCapturing: Bool { capturingPromptID == prompt.id && mode == .shortcut }

    init(prompt: PromptConfiguration,
         capturingPromptID: Binding<UUID?>,
         onShortcutChange: @escaping (HotkeyManager.Shortcut?) -> Void,
         onSelectionChange: @escaping (HotkeyManager.Selection?) -> Void) {
        self.prompt = prompt
        self._capturingPromptID = capturingPromptID
        self.onShortcutChange = onShortcutChange
        self.onSelectionChange = onSelectionChange
        // Default to Single Key when nothing configured; preserve existing choices otherwise
        let initialMode: TriggerMode = (prompt.selection != nil || (prompt.selection == nil && prompt.shortcut == nil)) ? .selection : .shortcut
        self._mode = State(initialValue: initialMode)
        self._selectionValue = State(initialValue: prompt.selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Trigger type", selection: $mode) {
                ForEach(TriggerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mode == .shortcut {
                shortcutControls
            } else {
                selectionControls
            }
        }
        .onChange(of: prompt) { newPrompt in
            // Keep Single Key as default when neither is set
            let derivedMode: TriggerMode = (newPrompt.selection != nil || (newPrompt.selection == nil && newPrompt.shortcut == nil)) ? .selection : .shortcut
            if mode != derivedMode {
                mode = derivedMode
            }
            selectionValue = newPrompt.selection
        }
        .onChange(of: mode) { newMode in
            if newMode == .shortcut {
                capturingPromptID = nil
                selectionValue = nil
                onSelectionChange(nil)
            } else {
                capturingPromptID = nil
                onShortcutChange(nil)
            }
        }
        .onChange(of: selectionValue) { newValue in
            if mode == .selection {
                onSelectionChange(newValue)
            }
        }
        .overlay(
            Group {
                if isCapturing {
                    ShortcutCaptureOverlay { event in
                        capturingPromptID = nil
                        if let evt = event, let shortcut = shortcutFromEvent(evt) {
                            onShortcutChange(shortcut)
                        }
                    }
                }
            }
        )
    }

    private var shortcutControls: some View {
        HStack(spacing: 8) {
            Text(prompt.shortcut.map(shortcutDescription) ?? "No hotkey")
                .font(.subheadline)
            Spacer()
            Button(isCapturing ? "Press keys…" : "Set Hotkey") {
                capturingPromptID = prompt.id
            }
            .buttonStyle(.bordered)
            if prompt.shortcut != nil {
                Button("Clear") {
                    capturingPromptID = nil
                    onShortcutChange(nil)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Single key", selection: Binding(get: {
                selectionValue
            }, set: { newValue in
                selectionValue = newValue
            })) {
                Text("None").tag(HotkeyManager.Selection?.none)
                ForEach(selectionOptions, id: \.self) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)

            if let selectionValue {
                HStack {
                    Text("Selected: \(selectionValue.displayName)")
                    Spacer()
                    Button("Clear") {
                        self.selectionValue = nil
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private var selectionOptions: [HotkeyManager.Selection] {
        HotkeyManager.Selection.allCases.filter { $0 != .f5 }
    }
}

private struct PromptLLMModelEditor: View {
    let prompt: PromptConfiguration
    let defaultModel: String
    let provider: String
    let favorites: [FavoriteLLMModel]
    let onUpdate: (String?, String?) -> Void

    @State private var modelDraft: String
    @State private var providerState: String
    @FocusState private var isFieldFocused: Bool

    init(prompt: PromptConfiguration,
         defaultModel: String,
         provider: String,
         favorites: [FavoriteLLMModel],
         onUpdate: @escaping (String?, String?) -> Void) {
        self.prompt = prompt
        self.defaultModel = defaultModel
        self.provider = provider
        self.favorites = favorites
        self.onUpdate = onUpdate
        _modelDraft = State(initialValue: prompt.llmModelOverride ?? "")
        _providerState = State(initialValue: (prompt.llmProviderOverride ?? provider).lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("LLM model override")
                    .font(.subheadline)
                    .bold()
                if hasOverride {
                    Text("Override active")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }

            TextField("Use default (\(defaultModel))", text: $modelDraft)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit { commit() }
                .onChange(of: isFieldFocused) { focused in
                    if !focused { commit() }
                }

            HStack(spacing: 8) {
                let groups = groupedQuickOptions
                if !groups.isEmpty {
                    Menu(favoritesMenuTitle) {
                        ForEach(groups, id: \.provider) { group in
                            Section(providerDisplayName(group.provider)) {
                                ForEach(group.models, id: \.key) { option in
                                    Button(option.model) {
                                        providerState = option.provider.lowercased()
                                        modelDraft = option.model
                                        commit()
                                    }
                                }
                            }
                        }
                    }
                }

                Button("Use default") {
                    modelDraft = ""
                    providerState = provider.lowercased()
                    commit()
                }
                .buttonStyle(.borderless)
                .disabled(!hasOverride && modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && providerState.caseInsensitiveCompare(provider) == .orderedSame)

                Spacer()
                Text("Using \(providerDisplayName(effectiveProvider)) · \(effectiveModel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: prompt.llmModelOverride) { newValue in
            if !isFieldFocused {
                modelDraft = newValue ?? ""
            }
        }
        .onChange(of: prompt.llmProviderOverride) { newValue in
            if !isFieldFocused {
                providerState = (newValue ?? provider).lowercased()
            }
        }
        .onChange(of: favorites) { _ in
            // Ensure provider state remains valid if favorites removed
            if !availableProviders.contains(where: { $0.caseInsensitiveCompare(providerState) == .orderedSame }) {
                providerState = provider.lowercased()
            }
        }
    }

    private var hasOverride: Bool {
        guard let override = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if !override.isEmpty { return true }
        return providerState.caseInsensitiveCompare(provider) != .orderedSame
    }

    private var effectiveModel: String {
        if let override = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return defaultModel
    }

    private var providerOverride: String? {
        let trimmed = providerState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.caseInsensitiveCompare(provider) != .orderedSame else { return nil }
        return trimmed.lowercased()
    }

    private var effectiveProvider: String {
        providerOverride ?? provider
    }

    private var quickOptions: [FavoriteLLMModel] {
        let baseList: [FavoriteLLMModel]
        if !favorites.isEmpty {
            baseList = favorites
        } else {
            let suggestions: [String]
            switch provider.lowercased() {
            case "openrouter":
                suggestions = ["openrouter/auto", "anthropic/claude-3.5-sonnet", "openai/gpt-4o-mini"]
            case "cerebras":
                suggestions = [
                    "llama-4-scout-17b-16e-instruct",
                    "llama3.1-8b",
                    "llama-3.3-70b",
                    "gpt-oss-120b",
                    "qwen-3-32b"
                ]
            default:
                suggestions = [
                    "moonshotai/kimi-k2-instruct",
                    "moonshotai/kimi-k2-instruct-0905",
                    "openai/gpt-oss-120b",
                    "meta-llama/llama-4-scout-17b-16e-instruct"
                ]
            }
            baseList = suggestions.map { FavoriteLLMModel(provider: provider.lowercased(), model: $0) }
        }
        var seen: Set<String> = []
        var result: [FavoriteLLMModel] = []
        for item in baseList {
            let key = item.key
            if !seen.contains(key) {
                seen.insert(key)
                result.append(FavoriteLLMModel(id: item.id, provider: item.provider.lowercased(), model: item.model))
            }
        }
        return result
    }

    private var groupedQuickOptions: [(provider: String, models: [FavoriteLLMModel])] {
        var order: [String] = []
        var groups: [String: [FavoriteLLMModel]] = [:]
        for option in quickOptions {
            let key = option.provider.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(option)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var favoritesMenuTitle: String {
        favorites.isEmpty ? "Suggested" : "Favorites"
    }

    private func commit() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        let current = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentProvider = prompt.llmProviderOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        var newProvider = providerOverride
        if let normalized, let match = favorites.first(where: { $0.model.caseInsensitiveCompare(normalized) == .orderedSame }) {
            providerState = match.provider.lowercased()
            newProvider = match.provider.lowercased() == provider.lowercased() ? nil : match.provider.lowercased()
        }
        if normalized == (current?.isEmpty == true ? nil : current) && ((currentProvider?.isEmpty ?? true ? nil : currentProvider?.lowercased()) == newProvider?.lowercased()) {
            return
        }
        onUpdate(normalized, newProvider)
    }

    private var availableProviders: [String] {
        var providers: [String] = [provider.lowercased()]
        for favorite in favorites {
            let key = favorite.provider.lowercased()
            if !providers.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                providers.append(key)
            }
        }
        return providers
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openrouter": return "OpenRouter"
        case "cerebras": return "Cerebras"
        default: return "Groq"
        }
    }
}

private enum PromptOverrideChoice: String, CaseIterable, Identifiable {
    case inherit
    case enabled
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: return "Default"
        case .enabled: return "On"
        case .disabled: return "Off"
        }
    }

    var boolValue: Bool? {
        switch self {
        case .inherit: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    func resolved(defaultValue: Bool) -> Bool {
        switch self {
        case .inherit: return defaultValue
        case .enabled: return true
        case .disabled: return false
        }
    }

    static func choice(for override: Bool?) -> PromptOverrideChoice {
        guard let override else { return .inherit }
        return override ? .enabled : .disabled
    }
}

private enum PromptPreprocessingChoice: String, CaseIterable, Identifiable {
  case inherit
  case off
  case onDevice
  case llm

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inherit: return "Default"
    case .off: return "Off"
    case .onDevice: return "On-device"
    case .llm: return "LLM"
    }
  }

  var modeValue: ScreenContextPreprocessingMode? {
    switch self {
    case .inherit: return nil
    case .off: return .off
    case .onDevice: return .onDevice
    case .llm: return .llm
    }
  }

  func resolved(defaultValue: ScreenContextPreprocessingMode) -> ScreenContextPreprocessingMode {
    modeValue ?? defaultValue
  }

  static func choice(for override: ScreenContextPreprocessingMode?) -> PromptPreprocessingChoice {
    guard let override else { return .inherit }
    switch override {
    case .off: return .off
    case .onDevice: return .onDevice
    case .llm: return .llm
    }
  }
}

private struct PromptScreenContextEditor: View {
    let prompt: PromptConfiguration
    let defaultScreenContext: Bool
    let defaultPreprocess: ScreenContextPreprocessingMode
    let onScreenUpdate: (Bool?) -> Void
    let onPreprocessUpdate: (ScreenContextPreprocessingMode?) -> Void

    @State private var screenChoice: PromptOverrideChoice
    @State private var preprocessChoice: PromptPreprocessingChoice

    init(prompt: PromptConfiguration,
         defaultScreenContext: Bool,
         defaultPreprocess: ScreenContextPreprocessingMode,
         onScreenUpdate: @escaping (Bool?) -> Void,
         onPreprocessUpdate: @escaping (ScreenContextPreprocessingMode?) -> Void) {
        self.prompt = prompt
        self.defaultScreenContext = defaultScreenContext
        self.defaultPreprocess = defaultPreprocess
        self.onScreenUpdate = onScreenUpdate
        self.onPreprocessUpdate = onPreprocessUpdate
        _screenChoice = State(initialValue: PromptOverrideChoice.choice(for: prompt.screenContextOverride))
        _preprocessChoice = State(initialValue: PromptPreprocessingChoice.choice(for: prompt.screenContextPreprocessingOverride))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Screen context")
                        .font(.subheadline).bold()
                    Spacer()
                    Text(defaultScreenContext ? "Default: On" : "Default: Off")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Picker("Screen context", selection: $screenChoice) {
                    ForEach(PromptOverrideChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: screenChoice) { newValue in
                    onScreenUpdate(newValue.boolValue)
                    let resolved = newValue.resolved(defaultValue: defaultScreenContext)
                    if !resolved {
                        preprocessChoice = .inherit
                        onPreprocessUpdate(nil)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                let resolvedDefault = defaultPreprocess
                let screenResolved = screenChoice.resolved(defaultValue: defaultScreenContext)
                HStack {
                    Text("Screen preprocessing")
                        .font(.subheadline).bold()
                    Spacer()
                    Text("Default: \(resolvedDefault.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Picker("Screen preprocessing", selection: $preprocessChoice) {
                    ForEach(PromptPreprocessingChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!screenResolved || !defaultScreenContext)
                .onChange(of: preprocessChoice) { newValue in
                    onPreprocessUpdate(newValue.modeValue)
                }
                .onChange(of: screenChoice) { newValue in
                    let resolved = newValue.resolved(defaultValue: defaultScreenContext)
                    if !resolved {
                        preprocessChoice = .inherit
                    } else if preprocessChoice == .inherit,
                              let override = prompt.screenContextPreprocessingOverride {
                        preprocessChoice = PromptPreprocessingChoice.choice(for: override)
                    }
                }
            }
        }
        .padding(.top, 6)
        .onChange(of: prompt.screenContextOverride) { newValue in
            screenChoice = PromptOverrideChoice.choice(for: newValue)
        }
        .onChange(of: prompt.screenContextPreprocessingOverride) { newValue in
            preprocessChoice = PromptPreprocessingChoice.choice(for: newValue)
        }
    }
}

private struct PromptRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Shared helpers for keyboard capture
private func shortcutDescription(_ s: HotkeyManager.Shortcut) -> String {
    var parts: [String] = []
    if s.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
    if s.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if s.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if s.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    parts.append(keyName(from: UInt16(s.keyCode)))
    return parts.joined()
}

private func keyName(from code: UInt16) -> String {
    let letters: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O", UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z"
    ]
    if let name = letters[code] { return name }

    let digits: [UInt16: String] = [
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_9): "9"
    ]
    if let name = digits[code] { return name }

    let fMap: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]
    if let name = fMap[code] { return name }

    let specials: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
    ]
    if let s = specials[code] { return s }
    return "Key_\(code)"
}

private func shortcutFromEvent(_ event: NSEvent) -> HotkeyManager.Shortcut? {
    let code = UInt16(event.keyCode)
    let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
    let modifierOnly: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_CapsLock), UInt16(kVK_Option), UInt16(kVK_Control),
        UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl), UInt16(kVK_RightCommand)
    ]
    guard !modifierOnly.contains(code) else { return nil }
    return HotkeyManager.Shortcut(keyCode: UInt32(code), modifiers: modifiers)
}

private struct ShortcutCaptureOverlay: NSViewRepresentable {
    let onComplete: (NSEvent?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onComplete = onComplete
        DispatchQueue.main.async { view.beginCapture() }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.onComplete = onComplete
    }

    static func dismantleNSView(_ nsView: ShortcutCaptureView, coordinator: ()) {
        nsView.endCapture()
    }

    final class ShortcutCaptureView: NSView {
        var onComplete: ((NSEvent?) -> Void)?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }

        func beginCapture() {
            endCapture()
            window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.onComplete?(event)
                return nil
            }
        }

        func endCapture() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { endCapture() }
    }
}
