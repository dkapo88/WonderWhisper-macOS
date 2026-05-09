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
            // Use a single template image and tint for state changes
            button.image = Self.templateWImage
            button.contentTintColor = .labelColor
            button.toolTip = "HermesWhisper"
        }
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // Observe recording state
        viewModel.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self, let button = self.statusItem.button else { return }
                let color: NSColor = recording ? .systemRed : .labelColor
                button.contentTintColor = color
                button.toolTip = recording ? "HermesWhisper — Recording" : "HermesWhisper — Idle"
                self.statusItem.menu = self.buildMenu()
                self.statusItem.menu?.delegate = self
            }
            .store(in: &cancellables)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

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

        let inputMenu = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // System default
        let currentSelection = AudioInputSelection.load()
        let sysItem = NSMenuItem(title: "System Default", action: #selector(selectSystemDefault), keyEquivalent: "")
        sysItem.target = self
        sysItem.state = (currentSelection == .systemDefault) ? .on : .off
        sub.addItem(sysItem)

        // Devices
        let devices = AudioDeviceManager.availableInputDevices()
        if devices.isEmpty == false { sub.addItem(.separator()) }
        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.representedObject = dev.uid
            item.target = self
            if case .deviceUID(let uid) = currentSelection, uid == dev.uid { item.state = .on }
            sub.addItem(item)
        }
        inputMenu.submenu = sub
        menu.addItem(inputMenu)

        menu.addItem(.separator())
        let apiItem = NSMenuItem(title: "API Keys…", action: #selector(openAPIKeys), keyEquivalent: ",")
        apiItem.keyEquivalentModifierMask = [.command]
        apiItem.target = self
        menu.addItem(apiItem)
        menu.addItem(NSMenuItem(title: "Quit HermesWhisper", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    @objc private func menuToggleDictation() { vm?.toggle() }
    @objc private func selectSystemDefault() {
        AudioInputSelection.systemDefault.persist()
        statusItem.menu = buildMenu()
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { AudioInputSelection.deviceUID(uid).persist() }
        statusItem.menu = buildMenu()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openAPIKeys() {
        // Post a notification for ContentView to switch to API Keys
        NotificationCenter.default.post(name: .openAPIKeysSettings, object: nil)
    }

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
        statusItem.menu = buildMenu()
    }

    // Single cached template image; colored via contentTintColor
    private static let templateWImage: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white, // template color, will be tinted
            .paragraphStyle: paragraph
        ]
        let str = NSAttributedString(string: "W", attributes: attrs)
        let rect = NSRect(x: 0, y: (size.height - font.capHeight)/2 - 1, width: size.width, height: font.capHeight + 2)
        str.draw(in: rect)
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
