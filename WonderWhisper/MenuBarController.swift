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

        let meetingCoordinator = viewModel.meetingCoordinator

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = Self.templateWonderWhisperImage
            button.contentTintColor = nil
            button.toolTip = "WonderWhisper"
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

        Publishers.CombineLatest3(
            meetingCoordinator.$activeSessionID,
            meetingCoordinator.$isStarting,
            meetingCoordinator.$isStopping
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.refreshStatusAndMenu()
        }
        .store(in: &cancellables)

        meetingCoordinator.$isLoadingSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusAndMenu() }
            .store(in: &cancellables)
    }

    private func refreshStatusAndMenu() {
        guard let vm else { return }
        let meetingCoordinator = vm.meetingCoordinator
        updateStatusIcon(
            isRecording: vm.isRecording,
            isMeetingActive: meetingCoordinator.activeSessionID != nil || meetingCoordinator.isStarting,
            pendingCount: vm.hermesPendingResponseCount
        )
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon(
        isRecording: Bool,
        isMeetingActive: Bool,
        pendingCount: Int
    ) {
        guard let button = statusItem.button else { return }
        if pendingCount > 0 {
            button.image = nil
            button.imagePosition = .noImage
            button.title = ""
            let countTitle = pendingCount > 99 ? "99+" : "\(pendingCount)"
            button.attributedTitle = NSAttributedString(
                string: countTitle,
                attributes: [
                    .foregroundColor: isRecording || isMeetingActive
                        ? NSColor.systemRed
                        : NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                ]
            )
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.contentTintColor = nil
            let suffix = pendingCount == 1 ? "response" : "responses"
            let activity = isMeetingActive
                ? "Meeting recording • "
                : (isRecording ? "Recording • " : "")
            button.toolTip = "WonderWhisper — \(activity)\(pendingCount) pending \(suffix)"
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            button.imagePosition = .imageOnly
            button.image = Self.templateWonderWhisperImage
            button.contentTintColor = isRecording || isMeetingActive ? .systemRed : nil
            if isMeetingActive {
                button.toolTip = "WonderWhisper — Meeting recording"
            } else {
                button.toolTip = isRecording ? "WonderWhisper — Recording" : "WonderWhisper — Idle"
            }
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
        let models = [
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

        let meetingCoordinator = vm?.meetingCoordinator
        let meetingTitle: String
        if meetingCoordinator?.isStarting == true {
            meetingTitle = "Starting Meeting…"
        } else if meetingCoordinator?.isStopping == true {
            meetingTitle = "Stopping Meeting…"
        } else if meetingCoordinator?.activeSessionID != nil {
            meetingTitle = "Stop Meeting"
        } else {
            meetingTitle = "Start Meeting"
        }
        let meeting = NSMenuItem(
            title: meetingTitle,
            action: #selector(toggleMeetingRecording),
            keyEquivalent: "m"
        )
        meeting.keyEquivalentModifierMask = [.command, .shift]
        meeting.target = self
        meeting.isEnabled = meetingCoordinator.map {
            !$0.isLoadingSessions && !$0.isStarting && !$0.isStopping
        } ?? false
        menu.addItem(meeting)

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
            title: "Quit WonderWhisper",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuToggleDictation() { vm?.toggle() }
    @objc private func toggleMeetingRecording() {
        guard let coordinator = vm?.meetingCoordinator,
              !coordinator.isLoadingSessions,
              !coordinator.isStarting,
              !coordinator.isStopping else { return }
        Task { @MainActor in
            if coordinator.activeSessionID == nil {
                await coordinator.startManualMeeting()
            } else {
                await coordinator.stopMeeting()
            }
        }
    }
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

    // A menu-bar-safe version of the app icon's WonderWhisper monogram. Keeping it as a
    // template lets AppKit tint the mark for light, dark, and highlighted menu bars.
    private static let templateWonderWhisperImage: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSColor.black.setStroke()

        let monogram = NSBezierPath()
        monogram.lineWidth = 2.8
        monogram.lineCapStyle = .square
        monogram.lineJoinStyle = .miter
        monogram.move(to: NSPoint(x: 2.5, y: 13.5))
        monogram.line(to: NSPoint(x: 6.5, y: 4.4))
        monogram.line(to: NSPoint(x: 10, y: 11.4))
        monogram.line(to: NSPoint(x: 13.5, y: 4.4))
        monogram.line(to: NSPoint(x: 17.5, y: 13.5))
        monogram.stroke()

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
