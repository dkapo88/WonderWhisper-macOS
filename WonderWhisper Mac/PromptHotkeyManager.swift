import Foundation
import Carbon.HIToolbox
import Cocoa

final class PromptHotkeyManager {
    enum TriggerPhase {
        case down
        case up
    }

    var onPromptEvent: ((UUID, TriggerPhase) -> Void)?

    private struct ShortcutEntry {
        let promptID: UUID
        let ref: EventHotKeyRef
    }

    private var nextIdentifier: UInt32 = 100
    private var shortcutEntries: [UInt32: ShortcutEntry] = [:]

    private var selectionBindings: [HotkeyManager.Selection: Set<UUID>] = [:]
    private var selectionActiveStates: [HotkeyManager.Selection: Bool] = [:]

    private var selectionTap: CFMachPort?
    private var selectionSource: CFRunLoopSource?

    // Modifier state
    private var leftCmdDown = false
    private var rightCmdDown = false
    private var leftOptDown = false
    private var rightOptDown = false
    private var leftCtrlDown = false
    private var rightCtrlDown = false
    private var leftShiftDown = false
    private var rightShiftDown = false
    private var fnDown = false

    private var handlerRef: EventHandlerRef?

    // MARK: - Public API
    func register(shortcut: HotkeyManager.Shortcut, for promptID: UUID) {
        unregister(promptID: promptID)
        ensureShortcutHandler()

        var hotKeyID = EventHotKeyID(signature: OSType(0x57575054), id: nextIdentifier) // 'WWPT'
        nextIdentifier &+= 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let ref = hotKeyRef else { return }
        shortcutEntries[hotKeyID.id] = ShortcutEntry(promptID: promptID, ref: ref)
    }

    func register(selection: HotkeyManager.Selection, for promptID: UUID) {
        unregister(promptID: promptID)
        if selection == .f5 {
            let shortcut = HotkeyManager.Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
            register(shortcut: shortcut, for: promptID)
            return
        }
        ensureSelectionTap()
        var set = selectionBindings[selection] ?? []
        set.insert(promptID)
        selectionBindings[selection] = set
    }

    func unregister(promptID: UUID) {
        if let shortcutPair = shortcutEntries.first(where: { $0.value.promptID == promptID }) {
            UnregisterEventHotKey(shortcutPair.value.ref)
            shortcutEntries.removeValue(forKey: shortcutPair.key)
        }
        for key in selectionBindings.keys {
            selectionBindings[key]?.remove(promptID)
            if selectionBindings[key]?.isEmpty == true {
                selectionBindings.removeValue(forKey: key)
                selectionActiveStates[key] = false
            }
        }
        if selectionBindings.isEmpty {
            tearDownSelectionTap()
        }
    }

    func unregisterAll() {
        for entry in shortcutEntries.values {
            UnregisterEventHotKey(entry.ref)
        }
        shortcutEntries.removeAll()
        selectionBindings.removeAll()
        selectionActiveStates.removeAll()
        tearDownSelectionTap()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    // MARK: - Shortcut handler
    private func ensureShortcutHandler() {
        guard handlerRef == nil else { return }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { (_, evt, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<PromptHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            var size = MemoryLayout<EventHotKeyID>.size
            let status = GetEventParameter(evt, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, size, &size, &hotKeyID)
            guard status == noErr, let entry = manager.shortcutEntries[hotKeyID.id] else { return noErr }
            let phase: TriggerPhase = (GetEventKind(evt) == UInt32(kEventHotKeyPressed)) ? .down : .up
            manager.onPromptEvent?(entry.promptID, phase)
            return noErr
        }
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), callback, specs.count, specs, ptr, &handlerRef)
    }

    // MARK: - Selection monitoring
    private func ensureSelectionTap() {
        guard selectionTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard type == .flagsChanged, let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<PromptHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            return
        }
        selectionTap = tap
        selectionSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = selectionSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func tearDownSelectionTap() {
        if let tap = selectionTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = selectionSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        selectionTap = nil
        selectionSource = nil
        leftCmdDown = false
        rightCmdDown = false
        leftOptDown = false
        rightOptDown = false
        leftCtrlDown = false
        rightCtrlDown = false
        leftShiftDown = false
        rightShiftDown = false
        fnDown = false
        selectionActiveStates.removeAll()
    }

    private func handleFlagsChanged(event: CGEvent) {
        guard !selectionBindings.isEmpty else { return }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch keyCode {
        case CGKeyCode(kVK_Command): leftCmdDown = flags.contains(.maskCommand)
        case CGKeyCode(kVK_RightCommand): rightCmdDown = flags.contains(.maskCommand)
        case CGKeyCode(kVK_Option): leftOptDown = flags.contains(.maskAlternate)
        case CGKeyCode(kVK_RightOption): rightOptDown = flags.contains(.maskAlternate)
        case CGKeyCode(kVK_Control): leftCtrlDown = flags.contains(.maskControl)
        case CGKeyCode(kVK_RightControl): rightCtrlDown = flags.contains(.maskControl)
        case CGKeyCode(kVK_Shift): leftShiftDown = flags.contains(.maskShift)
        case CGKeyCode(kVK_RightShift): rightShiftDown = flags.contains(.maskShift)
        default: break
        }
        fnDown = flags.contains(.maskSecondaryFn)

        for (selection, promptIDs) in selectionBindings {
            let isActive: Bool
            switch selection {
            case .fnGlobe:
                isActive = fnDown
            case .leftCommand:
                isActive = leftCmdDown
            case .leftOption:
                isActive = leftOptDown
            case .control:
                isActive = leftCtrlDown || rightCtrlDown
            case .rightCommand:
                isActive = rightCmdDown
            case .rightOption:
                isActive = rightOptDown
            case .commandRightShift:
                isActive = (leftCmdDown || rightCmdDown) && rightShiftDown
            case .optionRightShift:
                isActive = (leftOptDown || rightOptDown) && rightShiftDown
            case .f5:
                isActive = false
            }
            let wasActive = selectionActiveStates[selection] ?? false
            if isActive && !wasActive {
                selectionActiveStates[selection] = true
                for id in promptIDs {
                    onPromptEvent?(id, .down)
                }
            } else if !isActive && wasActive {
                selectionActiveStates[selection] = false
                for id in promptIDs {
                    onPromptEvent?(id, .up)
                }
            }
        }
    }
}
