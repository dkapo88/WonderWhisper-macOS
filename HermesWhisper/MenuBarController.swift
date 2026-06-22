import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private weak var vm: DictationViewModel?
    private var addDictItem: NSMenuItem?

    init(viewModel: DictationViewModel) {
        self.vm = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = Self.templateHermesMicImage
            button.contentTintColor = nil
            button.toolTip = "HermesWhisper"
        }
        refreshStatusAndMenu()

        // Observe the shared state that can affect the status icon or menu checks.
        viewModel.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)

        viewModel.$hermesPendingResponseCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)

        viewModel.$audioInputSelection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)

        viewModel.$simpleVoiceEngine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)

        viewModel.$openRouterTranscriptionModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)
    }

    private func refreshStatusAndMenu() {
        guard let vm else { return }
        updateStatusIcon(isRecording: vm.isRecording, pendingCount: vm.hermesPendingResponseCount)
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon(isRecording: Bool, pendingCount: Int) {
        guard let button = statusItem.button else { return }
        if pendingCount > 0 {
            button.image = nil
            button.imagePosition = .noImage
            button.title = pendingCount > 99 ? "99+" : "\(pendingCount)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.contentTintColor = nil
            let suffix = pendingCount == 1 ? "response" : "responses"
            button.toolTip = "HermesWhisper — \(pendingCount) pending \(suffix)"
        } else {
            button.title = ""
            button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            button.imagePosition = .imageOnly
            button.image = Self.templateHermesMicImage
            button.contentTintColor = isRecording ? .systemRed : nil
            button.toolTip = isRecording ? "HermesWhisper — Recording" : "HermesWhisper — Idle"
        }
    }

    private func refreshMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private var currentSelection: AudioInputSelection {
        vm?.audioInputSelection ?? AudioInputSelection.load()
    }

    private var currentOpenRouterVoiceModel: String {
        vm?.openRouterTranscriptionModel ?? AppConfig.defaultOpenRouterTranscriptionModel
    }

    private var currentVoiceEngine: SimpleVoiceEngine {
        vm?.simpleVoiceEngine ?? .parakeetLocal
    }

    private var openRouterVoiceModelOptions: [String] {
        var models = [
            AppConfig.defaultOpenRouterTranscriptionModel,
            "openai/gpt-4o-transcribe",
            "openai/whisper-1",
            currentOpenRouterVoiceModel
        ]
        var seen: Set<String> = []
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return trimmed
        }
    }

    private func displayName(forOpenRouterVoiceModel model: String) -> String {
        switch model.lowercased() {
        case AppConfig.defaultOpenRouterTranscriptionModel.lowercased():
            return "GPT-4o Mini Transcribe"
        case "openai/gpt-4o-transcribe":
            return "GPT-4o Transcribe"
        case "openai/whisper-1":
            return "Whisper 1"
        default:
            return model
        }
    }

    private func makeCheckedMenuItem(title: String,
                                     action: Selector,
                                     representedObject: Any?,
                                     isSelected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = isSelected ? .on : .off
        return item
    }

    private func buildStatusItem() -> NSMenuItem? {
        guard let vm, vm.hermesPendingResponseCount > 0 else { return nil }
        let suffix = vm.hermesPendingResponseCount == 1 ? "response" : "responses"
        let item = NSMenuItem(
            title: "\(vm.hermesPendingResponseCount) pending Hermes \(suffix)",
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        return item
    }

    private func buildInputDeviceMenu() -> NSMenuItem {
        let inputMenu = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let sysItem = makeCheckedMenuItem(
            title: "System Default",
            action: #selector(selectSystemDefault),
            representedObject: nil,
            isSelected: currentSelection == .systemDefault
        )
        sub.addItem(sysItem)

        let devices = AudioDeviceManager.availableInputDevices()
        if devices.isEmpty == false { sub.addItem(.separator()) }
        for dev in devices {
            let isSelected: Bool
            if case .deviceUID(let uid) = currentSelection {
                isSelected = uid == dev.uid
            } else {
                isSelected = false
            }
            sub.addItem(makeCheckedMenuItem(
                title: dev.name,
                action: #selector(selectDevice(_:)),
                representedObject: dev.uid,
                isSelected: isSelected
            ))
        }

        inputMenu.submenu = sub
        return inputMenu
    }

    private func buildVoiceEngineMenu() -> NSMenuItem {
        let engineMenu = NSMenuItem(title: "Voice Engine", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for engine in SimpleVoiceEngine.allCases {
            sub.addItem(makeCheckedMenuItem(
                title: engine.displayName,
                action: #selector(selectVoiceEngine(_:)),
                representedObject: engine.rawValue,
                isSelected: currentVoiceEngine == engine
            ))
        }
        engineMenu.submenu = sub
        return engineMenu
    }

    private func buildOpenRouterVoiceModelMenu() -> NSMenuItem {
        let modelMenu = NSMenuItem(title: "OpenRouter Voice Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentOpenRouterVoiceModel
        for model in openRouterVoiceModelOptions {
            sub.addItem(makeCheckedMenuItem(
                title: displayName(forOpenRouterVoiceModel: model),
                action: #selector(selectOpenRouterVoiceModel(_:)),
                representedObject: model,
                isSelected: model.caseInsensitiveCompare(current) == .orderedSame
            ))
        }
        sub.addItem(.separator())
        let customItem = NSMenuItem(
            title: "Custom Model ID…",
            action: #selector(promptForOpenRouterVoiceModel),
            keyEquivalent: ""
        )
        customItem.target = self
        sub.addItem(customItem)
        modelMenu.submenu = sub
        return modelMenu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if let status = buildStatusItem() {
            menu.addItem(status)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Toggle Dictation", action: #selector(menuToggleDictation), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)

        let addDict = NSMenuItem(title: "Add to Dictionary", action: #selector(addClipboardToVocabulary), keyEquivalent: "")
        addDict.target = self
        // Enable lazily when the menu opens (avoid pasteboard reads on every rebuild)
        addDict.isEnabled = false
        self.addDictItem = addDict
        menu.addItem(addDict)

        menu.addItem(.separator())

        menu.addItem(buildInputDeviceMenu())
        menu.addItem(buildVoiceEngineMenu())
        menu.addItem(buildOpenRouterVoiceModelMenu())

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit HermesWhisper",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuToggleDictation() { vm?.toggle() }
    @objc private func selectSystemDefault() {
        vm?.audioInputSelection = .systemDefault
        refreshMenu()
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            vm?.audioInputSelection = .deviceUID(uid)
        }
        refreshMenu()
    }
    @objc private func selectVoiceEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = SimpleVoiceEngine(rawValue: raw) else { return }
        vm?.simpleVoiceEngine = engine
        refreshStatusAndMenu()
    }
    @objc private func selectOpenRouterVoiceModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        vm?.simpleVoiceEngine = .openRouterTranscription
        vm?.openRouterTranscriptionModel = model
        refreshStatusAndMenu()
    }
    @objc private func promptForOpenRouterVoiceModel() {
        guard let vm else { return }
        let alert = NSAlert()
        alert.messageText = "OpenRouter Voice Model"
        alert.informativeText = "Enter the transcription model ID to use for OpenRouter voice transcription."
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = vm.openRouterTranscriptionModel
        alert.accessoryView = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let model = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        vm.simpleVoiceEngine = .openRouterTranscription
        vm.openRouterTranscriptionModel = model
        refreshStatusAndMenu()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func addClipboardToVocabulary() {
        guard let vm = vm else { return }
        guard var word = NSPasteboard.general.string(forType: .string) else { return }
        word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        // Split existing vocabulary by comma/newline, normalize and dedupe
        let separators = CharacterSet(charactersIn: ",\n\r")
        var items = vm.vocabCustom
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lowered = Set(items.map { $0.lowercased() })
        if !lowered.contains(word.lowercased()) {
            items.append(word)
            vm.vocabCustom = items.joined(separator: "\n")
        }
        refreshMenu()
    }

    // Single cached template image; AppKit tints it to match the active menu bar style.
    private static let templateHermesMicImage: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let staff = NSBezierPath()
        staff.lineWidth = 1.5
        staff.lineCapStyle = .round
        staff.move(to: NSPoint(x: 10, y: 3))
        staff.line(to: NSPoint(x: 10, y: 14.5))
        staff.stroke()

        let mic = NSBezierPath(roundedRect: NSRect(x: 7.2, y: 9.3, width: 5.6, height: 6.4),
                               xRadius: 2.8,
                               yRadius: 2.8)
        mic.lineWidth = 1.2
        mic.stroke()

        let base = NSBezierPath()
        base.lineWidth = 1.4
        base.lineCapStyle = .round
        base.move(to: NSPoint(x: 6.8, y: 3.2))
        base.line(to: NSPoint(x: 13.2, y: 3.2))
        base.stroke()

        for offset in 0..<3 {
            let inset = CGFloat(offset) * 1.45
            let left = NSBezierPath()
            left.lineWidth = 1.35
            left.lineCapStyle = .round
            left.move(to: NSPoint(x: 9.2 - inset * 0.25, y: 10.3 - inset))
            left.curve(
                to: NSPoint(x: 2.8 + inset, y: 13.2 - inset * 1.25),
                controlPoint1: NSPoint(x: 7.0 - inset * 0.2, y: 12.5 - inset),
                controlPoint2: NSPoint(x: 5.0 + inset * 0.6, y: 13.5 - inset)
            )
            left.stroke()

            let right = NSBezierPath()
            right.lineWidth = 1.35
            right.lineCapStyle = .round
            right.move(to: NSPoint(x: 10.8 + inset * 0.25, y: 10.3 - inset))
            right.curve(
                to: NSPoint(x: 17.2 - inset, y: 13.2 - inset * 1.25),
                controlPoint1: NSPoint(x: 13.0 + inset * 0.2, y: 12.5 - inset),
                controlPoint2: NSPoint(x: 15.0 - inset * 0.6, y: 13.5 - inset)
            )
            right.stroke()
        }

        img.isTemplate = true
        return img
    }()
}

// MARK: - NSMenuDelegate for lazy enabling
extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Re-evaluate clipboard only when the menu actually opens
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        addDictItem?.isEnabled = !clip.isEmpty
    }
}
