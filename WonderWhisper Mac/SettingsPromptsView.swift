import SwiftUI
import Carbon.HIToolbox

struct SettingsPromptsView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var renamingPromptID: UUID?
    @State private var nameDraft: String = ""
    @State private var capturingPromptID: UUID?

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
                            promptRow(prompt)
                                .padding(10)
                                .background(selectionBackground(for: prompt))
                                .cornerRadius(8)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
    }

    private func promptRow(_ prompt: PromptConfiguration) -> some View {
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

            PromptShortcutEditor(prompt: prompt, capturingPromptID: $capturingPromptID) { newShortcut in
                vm.updateShortcut(for: prompt.id, to: newShortcut)
            }
            .padding(.top, 2)

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

    private func selectionBackground(for prompt: PromptConfiguration) -> some View {
        Group {
            if vm.selectedPromptID == prompt.id {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08))
            }
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

private struct PromptShortcutEditor: View {
    let prompt: PromptConfiguration
    @Binding var capturingPromptID: UUID?
    let onChange: (HotkeyManager.Shortcut?) -> Void

    private var isCapturing: Bool { capturingPromptID == prompt.id }

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcutSummary())
                .font(.subheadline)
            Spacer()
            Button(isCapturing ? "Press keys…" : "Set Hotkey") {
                capturingPromptID = prompt.id
            }
            .buttonStyle(.bordered)
            if prompt.shortcut != nil {
                Button("Clear") {
                    onChange(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .overlay(
            Group {
                if isCapturing {
                    ShortcutCaptureOverlay { event in
                        capturingPromptID = nil
                        if let evt = event, let shortcut = shortcutFromEvent(evt) {
                            onChange(shortcut)
                        }
                    }
                }
            }
        )
    }

    private func shortcutSummary() -> String {
        guard let shortcut = prompt.shortcut else { return "No hotkey" }
        return shortcutDescription(shortcut)
    }
}

// MARK: - Shortcut capture utilities
private func shortcutDescription(_ s: HotkeyManager.Shortcut) -> String {
    var parts: [String] = []
    if s.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
    if s.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if s.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if s.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    parts.append(keyName(from: UInt16(s.keyCode)))
    return parts.joined(separator: "")
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
    let isModifierOnly = [UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_CapsLock), UInt16(kVK_Option), UInt16(kVK_Control), UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl), UInt16(kVK_RightCommand)].contains(code)
    guard !isModifierOnly else { return nil }
    return HotkeyManager.Shortcut(keyCode: UInt32(code), modifiers: modifiers)
}

private struct ShortcutCaptureOverlay: NSViewRepresentable {
    let onComplete: (NSEvent?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onComplete = onComplete
        DispatchQueue.main.async {
            view.beginCapture()
        }
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

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
