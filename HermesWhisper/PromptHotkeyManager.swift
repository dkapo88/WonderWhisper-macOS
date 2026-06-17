import Foundation
import Carbon.HIToolbox
import Cocoa
import ApplicationServices
import IOKit.hidsystem

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
    private var pendingSelectionWorkItems: [HotkeyManager.Selection: DispatchWorkItem] = [:]
    private let modifierActivationDelay: TimeInterval = 0.16

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

        let hotKeyID = EventHotKeyID(signature: OSType(0x57575054), id: nextIdentifier) // 'WWPT'
        nextIdentifier &+= 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let ref = hotKeyRef else {
            AppLog.hotkeys.error(
                "Failed prompt hotkey key=\(shortcut.keyCode) mods=\(shortcut.modifiers) status=\(status)"
            )
            return
        }
        shortcutEntries[hotKeyID.id] = ShortcutEntry(promptID: promptID, ref: ref)
        AppLog.hotkeys.log(
            "Registered prompt hotkey id=\(promptID.uuidString) key=\(shortcut.keyCode) mods=\(shortcut.modifiers)"
        )
    }

    func register(selection: HotkeyManager.Selection, for promptID: UUID) {
        unregister(promptID: promptID)
        if selection == .f5 {
            registerKeyEventSelection(selection, for: promptID)
            return
        }
        if let shortcut = selection.directShortcut {
            register(shortcut: shortcut, for: promptID)
            return
        }
        registerKeyEventSelection(selection, for: promptID)
    }

    private func registerKeyEventSelection(_ selection: HotkeyManager.Selection, for promptID: UUID) {
        ensureSelectionTap()
        guard selectionTap != nil else {
            AppLog.hotkeys.error(
                "Skipped prompt selection id=\(promptID.uuidString, privacy: .public) selection=\(selection.rawValue, privacy: .public) because event tap is unavailable"
            )
            return
        }
        var set = selectionBindings[selection] ?? []
        set.insert(promptID)
        selectionBindings[selection] = set
        AppLog.hotkeys.log(
            "Registered prompt selection id=\(promptID.uuidString, privacy: .public) selection=\(selection.rawValue, privacy: .public)"
        )
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
            guard !HotkeyManager.isActivationSuppressed else { return noErr }
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
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        guard trusted else {
            AppLog.hotkeys.error("Prompt selection event tap blocked: Accessibility trust is not granted")
            return
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << NX_SYSDEFINED)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<PromptHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            var shouldSuppress = false
            if type == .flagsChanged {
                manager.handleFlagsChanged(event: event)
            } else if type == .keyDown {
                shouldSuppress = manager.handleKeyDown(event: event)
            } else if type == .keyUp {
                shouldSuppress = manager.handleKeyUp(event: event)
            } else if type.rawValue == NX_SYSDEFINED {
                shouldSuppress = manager.handleSystemDefined(event: event)
            }
            if shouldSuppress { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            AppLog.hotkeys.error(
                "Failed to install prompt selection event tap axTrusted=\(trusted, privacy: .public)"
            )
            return
        }
        selectionTap = tap
        selectionSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = selectionSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let trusted = AXIsProcessTrusted()
            AppLog.hotkeys.log(
                "Installed prompt selection event tap axTrusted=\(trusted, privacy: .public)"
            )
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
        cancelAllPendingSelectionActivations()
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
        if HotkeyManager.isActivationSuppressed {
            leftCmdDown = false
            rightCmdDown = false
            leftOptDown = false
            rightOptDown = false
            leftCtrlDown = false
            rightCtrlDown = false
            leftShiftDown = false
            rightShiftDown = false
            fnDown = false
            selectionActiveStates = selectionActiveStates.mapValues { _ in false }
            cancelAllPendingSelectionActivations()
            return
        }
        guard !selectionBindings.isEmpty else { return }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        refreshModifierState(changedKeyCode: keyCode, flags: flags)

        for (selection, promptIDs) in selectionBindings {
            let isActive = isSelectionCurrentlyActive(selection)
            let wasActive = selectionActiveStates[selection] ?? false
            let isPending = pendingSelectionWorkItems[selection] != nil
            let hasDisallowedModifier = selection.needsChordGuard &&
                hasDisallowedModifierDown(for: selection)
            if isActive, !wasActive, hasDisallowedModifier {
                cancelPendingSelectionActivation(selection)
                continue
            }
            if isActive, isPending, hasDisallowedModifier {
                cancelPendingSelectionActivation(selection)
                continue
            }
            if isActive && !wasActive && !isPending {
                if selection.needsChordGuard {
                    scheduleSelectionActivation(selection, promptIDs: promptIDs)
                } else {
                    fireSelectionActivation(selection, promptIDs: promptIDs)
                }
            } else if !isActive && wasActive {
                cancelPendingSelectionActivation(selection)
                selectionActiveStates[selection] = false
                for id in promptIDs {
                    onPromptEvent?(id, .up)
                }
            } else if !isActive && isPending {
                firePendingSelectionTapOnRelease(selection, promptIDs: promptIDs)
            } else if !isActive {
                cancelPendingSelectionActivation(selection)
            }
        }
    }

    private func refreshModifierState(changedKeyCode: CGKeyCode, flags: CGEventFlags) {
        let commandDown = flags.contains(.maskCommand)
        let optionDown = flags.contains(.maskAlternate)
        let controlDown = flags.contains(.maskControl)
        let shiftDown = flags.contains(.maskShift)
        let functionDown = flags.contains(.maskSecondaryFn)

        if !commandDown {
            leftCmdDown = false
            rightCmdDown = false
        }
        if !optionDown {
            leftOptDown = false
            rightOptDown = false
        }
        if !controlDown {
            leftCtrlDown = false
            rightCtrlDown = false
        }
        if !shiftDown {
            leftShiftDown = false
            rightShiftDown = false
        }
        if !functionDown {
            fnDown = false
        }

        switch changedKeyCode {
        case CGKeyCode(kVK_Command):
            leftCmdDown = commandDown
        case CGKeyCode(kVK_RightCommand):
            rightCmdDown = commandDown
        case CGKeyCode(kVK_Option):
            leftOptDown = optionDown
        case CGKeyCode(kVK_RightOption):
            rightOptDown = optionDown
        case CGKeyCode(kVK_Control):
            leftCtrlDown = controlDown
        case CGKeyCode(kVK_RightControl):
            rightCtrlDown = controlDown
        case CGKeyCode(kVK_Shift):
            leftShiftDown = shiftDown
        case CGKeyCode(kVK_RightShift):
            rightShiftDown = shiftDown
        case CGKeyCode(kVK_Function):
            fnDown = functionDown
        default:
            break
        }
    }

    private func hasDisallowedModifierDown(for selection: HotkeyManager.Selection) -> Bool {
        switch selection {
        case .fnGlobe:
            return leftCmdDown || rightCmdDown || leftOptDown || rightOptDown ||
                leftCtrlDown || rightCtrlDown || leftShiftDown || rightShiftDown
        case .leftCommand:
            return rightCmdDown || leftOptDown || rightOptDown || leftCtrlDown ||
                rightCtrlDown || leftShiftDown || rightShiftDown || fnDown
        case .rightCommand:
            return leftCmdDown || leftOptDown || rightOptDown || leftCtrlDown ||
                rightCtrlDown || leftShiftDown || rightShiftDown || fnDown
        case .leftOption:
            return leftCmdDown || rightCmdDown || rightOptDown || leftCtrlDown ||
                rightCtrlDown || leftShiftDown || rightShiftDown || fnDown
        case .rightOption:
            return leftCmdDown || rightCmdDown || leftOptDown || leftCtrlDown ||
                rightCtrlDown || leftShiftDown || rightShiftDown || fnDown
        case .control:
            return leftCmdDown || rightCmdDown || leftOptDown || rightOptDown ||
                leftShiftDown || rightShiftDown || fnDown
        case .commandRightShift:
            return leftOptDown || rightOptDown || leftCtrlDown || rightCtrlDown ||
                leftShiftDown || fnDown
        case .optionRightShift:
            return leftCmdDown || rightCmdDown || leftCtrlDown || rightCtrlDown ||
                leftShiftDown || fnDown
        case .backslash, .f5:
            return false
        }
    }

    private func handleKeyDown(event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == CGKeyCode(kVK_ANSI_Backslash) {
            return handleBackslashDown(event: event)
        }
        if keyCode == CGKeyCode(kVK_F5) {
            return handleF5Down(flags: event.flags)
        }
        guard !HotkeyManager.isModifierKey(keyCode) else { return false }
        guard !pendingSelectionWorkItems.isEmpty else { return false }
        cancelAllPendingSelectionActivations()
        return false
    }

    private func handleKeyUp(event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == CGKeyCode(kVK_F5) {
            return handleF5Up(flags: event.flags)
        }
        guard keyCode == CGKeyCode(kVK_ANSI_Backslash) else { return false }
        guard let promptIDs = selectionBindings[.backslash], !promptIDs.isEmpty else {
            return false
        }
        let wasActive = selectionActiveStates[.backslash] ?? false
        let shouldCapture = wasActive || !hasDisallowedKeyModifiers(event.flags)
        if wasActive {
            selectionActiveStates[.backslash] = false
            for id in promptIDs {
                onPromptEvent?(id, .up)
            }
        }
        return shouldCapture
    }

    private func handleBackslashDown(event: CGEvent) -> Bool {
        guard let promptIDs = selectionBindings[.backslash], !promptIDs.isEmpty else {
            return false
        }
        guard !hasDisallowedKeyModifiers(event.flags) else { return false }
        guard !HotkeyManager.isActivationSuppressed else { return true }
        guard selectionActiveStates[.backslash] != true else { return true }
        fireSelectionActivation(.backslash, promptIDs: promptIDs)
        return true
    }

    private func handleF5Down(flags: CGEventFlags = []) -> Bool {
        guard let promptIDs = selectionBindings[.f5], !promptIDs.isEmpty else {
            return false
        }
        guard !hasDisallowedF5Modifiers(flags) else { return false }
        guard !HotkeyManager.isActivationSuppressed else { return true }
        guard selectionActiveStates[.f5] != true else { return true }
        AppLog.hotkeys.log("Observed F5 keyDown via prompt event tap")
        fireSelectionActivation(.f5, promptIDs: promptIDs)
        return true
    }

    private func handleF5Up(flags: CGEventFlags = []) -> Bool {
        guard let promptIDs = selectionBindings[.f5], !promptIDs.isEmpty else {
            return false
        }
        let wasActive = selectionActiveStates[.f5] ?? false
        let shouldCapture = wasActive || !hasDisallowedF5Modifiers(flags)
        if wasActive {
            AppLog.hotkeys.log("Observed F5 keyUp via prompt event tap")
            selectionActiveStates[.f5] = false
            for id in promptIDs {
                onPromptEvent?(id, .up)
            }
        }
        return shouldCapture
    }

    private func hasDisallowedKeyModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)
            || flags.contains(.maskSecondaryFn)
    }

    private func hasDisallowedF5Modifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)
    }

    private func handleSystemDefined(event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
            return false
        }
        let keyType = (nsEvent.data1 & 0xFFFF0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000FF00) >> 8
        guard keyType == NX_KEYTYPE_ILLUMINATION_DOWN else {
            if selectionBindings[.f5]?.isEmpty == false {
                AppLog.hotkeys.log(
                    "Observed system-defined key type=\(keyType, privacy: .public) state=\(keyState, privacy: .public)"
                )
            }
            return false
        }
        if keyState == 0x0A {
            AppLog.hotkeys.log("Observed F5 system-defined keyDown")
            return handleF5Down()
        }
        if keyState == 0x0B {
            AppLog.hotkeys.log("Observed F5 system-defined keyUp")
            return handleF5Up()
        }
        return false
    }

    private func fireSelectionActivation(_ selection: HotkeyManager.Selection, promptIDs: Set<UUID>) {
        selectionActiveStates[selection] = true
        for id in promptIDs {
            onPromptEvent?(id, .down)
        }
    }

    private func scheduleSelectionActivation(_ selection: HotkeyManager.Selection, promptIDs: Set<UUID>) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !HotkeyManager.isActivationSuppressed else { return }
            guard self.isSelectionCurrentlyActive(selection) else { return }
            self.pendingSelectionWorkItems[selection] = nil
            self.fireSelectionActivation(selection, promptIDs: promptIDs)
        }
        pendingSelectionWorkItems[selection] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierActivationDelay, execute: item)
    }

    private func cancelPendingSelectionActivation(_ selection: HotkeyManager.Selection) {
        pendingSelectionWorkItems[selection]?.cancel()
        pendingSelectionWorkItems[selection] = nil
    }

    private func cancelAllPendingSelectionActivations() {
        for item in pendingSelectionWorkItems.values {
            item.cancel()
        }
        pendingSelectionWorkItems.removeAll()
    }

    private func firePendingSelectionTapOnRelease(
        _ selection: HotkeyManager.Selection,
        promptIDs: Set<UUID>
    ) {
        cancelPendingSelectionActivation(selection)
        guard !HotkeyManager.isActivationSuppressed else { return }
        for id in promptIDs {
            onPromptEvent?(id, .down)
            onPromptEvent?(id, .up)
        }
    }

    private func isSelectionCurrentlyActive(_ selection: HotkeyManager.Selection) -> Bool {
        switch selection {
        case .fnGlobe:
            return fnDown
        case .leftCommand:
            return leftCmdDown
        case .leftOption:
            return leftOptDown
        case .control:
            return leftCtrlDown || rightCtrlDown
        case .rightCommand:
            return rightCmdDown
        case .rightOption:
            return rightOptDown
        case .commandRightShift:
            return (leftCmdDown || rightCmdDown) && rightShiftDown
        case .optionRightShift:
            return (leftOptDown || rightOptDown) && rightShiftDown
        case .backslash, .f5:
            return false
        }
    }
}
