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

    private let promptSpacing: CGFloat = 8

    var body: some View {
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
        .padding(16)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                        .onTapGesture { vm.selectPrompt(id: prompt.id) }
                }
                Spacer()
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
                }
                .buttonStyle(.borderless)
            }

            PromptTriggerEditor(
                prompt: prompt,
                capturingPromptID: $capturingPromptID,
                onShortcutChange: { vm.updateShortcut(for: prompt.id, to: $0) },
                onSelectionChange: { vm.updateSelection(for: prompt.id, to: $0) }
            )
            .padding(.top, 2)

            PromptLLMModelEditor(
                prompt: prompt,
                defaultModel: vm.llmModel,
                provider: vm.llmProvider,
                favorites: vm.favoriteLLMModels,
                onUpdate: { vm.updateLLMModel(for: prompt.id, to: $0) }
            )

            if vm.selectedPromptID == prompt.id {
                Text("Active prompt")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else {
                Button("Select this prompt") { vm.selectPrompt(id: prompt.id) }
                    .buttonStyle(.link)
            }
        }
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
    let favorites: [String]
    let onUpdate: (String?) -> Void

    @State private var modelDraft: String
    @FocusState private var isFieldFocused: Bool

    init(prompt: PromptConfiguration,
         defaultModel: String,
         provider: String,
         favorites: [String],
         onUpdate: @escaping (String?) -> Void) {
        self.prompt = prompt
        self.defaultModel = defaultModel
        self.provider = provider
        self.favorites = favorites
        self.onUpdate = onUpdate
        _modelDraft = State(initialValue: prompt.llmModelOverride ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("LLM model")
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
                if !quickOptions.isEmpty {
                    Menu(favoritesMenuTitle) {
                        ForEach(quickOptions, id: \.self) { option in
                            Button(option) {
                                modelDraft = option
                                commit()
                            }
                        }
                    }
                }

                Button("Use default") {
                    modelDraft = ""
                    commit()
                }
                .buttonStyle(.borderless)
                .disabled(!hasOverride && modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
                Text("Using \(effectiveModel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: prompt.llmModelOverride) { newValue in
            if !isFieldFocused {
                modelDraft = newValue ?? ""
            }
        }
    }

    private var hasOverride: Bool {
        guard let override = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !override.isEmpty
    }

    private var effectiveModel: String {
        if let override = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return defaultModel
    }

    private var quickOptions: [String] {
        let cleanedFavorites = favorites
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedFavorites.isEmpty {
            return Array(NSOrderedSet(array: cleanedFavorites)) as? [String] ?? cleanedFavorites
        }
        switch provider.lowercased() {
        case "openrouter":
            return ["openrouter/auto", "anthropic/claude-3.5-sonnet", "openai/gpt-4o-mini"]
        case "cerebras":
            return [
                "llama-4-scout-17b-16e-instruct",
                "llama3.1-8b",
                "llama-3.3-70b",
                "gpt-oss-120b",
                "qwen-3-32b"
            ]
        default:
            return [
                "moonshotai/kimi-k2-instruct",
                "moonshotai/kimi-k2-instruct-0905",
                "openai/gpt-oss-120b",
                "meta-llama/llama-4-scout-17b-16e-instruct"
            ]
        }
    }

    private var favoritesMenuTitle: String {
        favorites.isEmpty ? "Quick pick" : "Favorites"
    }

    private func commit() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        let current = prompt.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == (current?.isEmpty == true ? nil : current) {
            return
        }
        onUpdate(normalized)
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
