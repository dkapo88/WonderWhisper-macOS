import Foundation
import Carbon.HIToolbox
import Cocoa
import ApplicationServices

final class HotkeyManager {
    private static let suppressionLock = NSLock()
    private static var suppressedUntil: Date?

    static func suppressActivation(for duration: TimeInterval) {
        suppressionLock.lock()
        suppressedUntil = Date().addingTimeInterval(duration)
        suppressionLock.unlock()
    }

    static var isActivationSuppressed: Bool {
        suppressionLock.lock()
        let deadline = suppressedUntil
        if let deadline, deadline <= Date() {
            suppressedUntil = nil
        }
        let suppressed = suppressedUntil.map { $0 > Date() } ?? false
        suppressionLock.unlock()
        return suppressed
    }

    enum Selection: String, CaseIterable, Codable {
        case fnGlobe
        case leftCommand
        case leftOption
        case control // either side
        case rightCommand
        case rightOption
        case commandRightShift
        case optionRightShift
        case f5

        var displayName: String {
            switch self {
            case .fnGlobe: return "Fn / Globe"
            case .leftCommand: return "Left Command (⌘)"
            case .leftOption: return "Left Option (⌥)"
            case .control: return "Control (⌃)"
            case .rightCommand: return "Right Command (⌘)"
            case .rightOption: return "Right Option (⌥)"
            case .commandRightShift: return "Cmd + Right Shift"
            case .optionRightShift: return "Option + Right Shift"
            case .f5: return "F5"
            }
        }

        // Whether this selection requires an accessibility event tap
        var requiresAX: Bool {
            switch self {
            case .f5: return false
            default: return true
            }
        }
    }
    struct Shortcut: Equatable, Codable, Hashable {
        var keyCode: UInt32 // kVK_ constants (e.g., 49 for Space)
        var modifiers: UInt32 // Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey
    }

    // Carbon hotkeys
    private var toggleHotKeyRef: EventHotKeyRef?
    private var pasteHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Modifier state tracking for event tap
    private var lastFnFlagsOn: Bool = false
    private var leftCmdDown = false
    private var rightCmdDown = false
    private var leftOptDown = false
    private var rightOptDown = false
    private var leftCtrlDown = false
    private var rightCtrlDown = false
    private var rightShiftDown = false
    private var leftShiftDown = false
    private var selectionActive = false

    // Callbacks
    var onActivate: (() -> Void)?
    var onPaste: (() -> Void)?

    // Push-to-talk timing
    private var hotkeyPressStart: Date?
    private let briefPressThreshold: TimeInterval = 0.8
    private let modifierActivationDelay: TimeInterval = 0.16
    private var lastPasteTrigger: Date?
    private var activateCalledOnThisPress: Bool = false  // Prevent double-trigger
    private var pendingActivationWorkItem: DispatchWorkItem?

    // Settings (single source of truth)
    var selection: Selection? { didSet { applySelection() } }
    // Toggle/recording shortcut (used for .f5 selection)
    var registeredShortcut: Shortcut? { didSet { registerCarbonHotkeyForToggle() } }
    // Additional configurable paste shortcut
    var pasteShortcut: Shortcut? { didSet { registerCarbonHotkeyForPaste() } }

    // MARK: - Carbon Global Hotkey (standard key combos)
    // MARK: - Carbon Global Hotkeys
    private func ensureEventHandlerInstalled() {
        guard eventHandlerRef == nil else { return }

        // Install the event handler once
        let specs: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { (_, evtRef, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let selfRef = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            var size = MemoryLayout<EventHotKeyID>.size
            let status = GetEventParameter(evtRef, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, size, &size, &hkID)
            let kind = GetEventKind(evtRef)
            if status == noErr {
                // id: 1 => toggle; 2 => paste
                if kind == UInt32(kEventHotKeyPressed) {
                    if hkID.id == 1 { selfRef.handleHotkeyDown() }
                    // For paste, we act on key UP to avoid modifier interference
                } else if kind == UInt32(kEventHotKeyReleased) {
                    if hkID.id == 1 { selfRef.handleHotkeyUp() }
                    else if hkID.id == 2 { selfRef.handlePasteUp() }
                }
            }
            return noErr
        }
        let target = GetApplicationEventTarget()
        let userPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status: OSStatus = specs.withUnsafeBufferPointer { buf in
            InstallEventHandler(target, callback, Int(buf.count), buf.baseAddress, userPtr, &eventHandlerRef)
        }
        if status == noErr {
            AppLog.hotkeys.log("Installed Carbon event handler for hotkeys")
        } else {
            AppLog.hotkeys.error("Failed to install EventHandler: status=\(status)")
        }
    }

    private func registerCarbonHotkeyForToggle() {
        unregisterCarbonHotkey(ref: &toggleHotKeyRef)
        guard let shortcut = registeredShortcut else { return }
        ensureEventHandlerInstalled()

        let hotKeyID = EventHotKeyID(signature: OSType(0x57574854), id: 1) // 'WWHT'
        var hkRef: EventHotKeyRef?
        var status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hkRef)
        if status != noErr || hkRef == nil {
            status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hkRef)
        }
        if status == noErr, let hkRef {
            self.toggleHotKeyRef = hkRef
            AppLog.hotkeys.log("Registered toggle hotkey keyCode=\(shortcut.keyCode) mods=\(shortcut.modifiers) status=\(status)")
        } else {
            AppLog.hotkeys.error("Failed to register toggle hotkey (key=\(shortcut.keyCode), mods=\(shortcut.modifiers)), status=\(status)")
        }
    }

    private func registerCarbonHotkeyForPaste() {
        unregisterCarbonHotkey(ref: &pasteHotKeyRef)
        guard let shortcut = pasteShortcut else { return }
        ensureEventHandlerInstalled()

        let hotKeyID = EventHotKeyID(signature: OSType(0x57575056), id: 2) // 'WWPV'
        var hkRef: EventHotKeyRef?
        var status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hkRef)
        if status != noErr || hkRef == nil {
            // Try dispatcher target as a fallback for background delivery
            status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hkRef)
        }
        if status == noErr, let hkRef {
            self.pasteHotKeyRef = hkRef
            AppLog.hotkeys.log("Registered paste hotkey keyCode=\(shortcut.keyCode) mods=\(shortcut.modifiers) status=\(status)")
        } else {
            AppLog.hotkeys.error("Failed to register paste hotkey (key=\(shortcut.keyCode), mods=\(shortcut.modifiers)), status=\(status)")
        }
    }

    private func unregisterCarbonHotkey(ref: inout EventHotKeyRef?) {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
    }

    // MARK: - Accessibility event tap
    private func applySelection() {
        stopFnTap()
        unregisterCarbonHotkey(ref: &toggleHotKeyRef)
        resetModifierState()
        guard let sel = selection else { return }
        if sel.requiresAX {
            startFnTap(for: sel)
        } else {
            // Only F5 currently uses Carbon hotkey
            if sel == .f5 {
                registeredShortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
            }
        }
    }

    private func startFnTap(for sel: Selection) {
        if eventTap != nil { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .flagsChanged {
                manager.handleFlagsChanged(event: event)
            } else if type == .keyDown {
                manager.handleKeyDown(event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            // Likely missing Accessibility permission
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func stopFnTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        lastFnFlagsOn = false
        selectionActive = false
        cancelPendingActivation()
        activateCalledOnThisPress = false
    }

    // MARK: - Helpers
    private func resetModifierState() {
        cancelPendingActivation()
        leftCmdDown = false; rightCmdDown = false
        leftOptDown = false; rightOptDown = false
        leftCtrlDown = false; rightCtrlDown = false
        leftShiftDown = false; rightShiftDown = false
        lastFnFlagsOn = false
        selectionActive = false
    }

    private func handleFlagsChanged(event: CGEvent) {
        if Self.isActivationSuppressed {
            resetModifierState()
            return
        }
        guard let sel = selection else { return }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Update per-side modifier booleans based on which key toggled
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

        // Fn/globe state
        lastFnFlagsOn = flags.contains(.maskSecondaryFn)

        // Evaluate active condition for current selection
        let newActive: Bool
        switch sel {
        case .fnGlobe:
            newActive = lastFnFlagsOn
        case .leftCommand:
            newActive = leftCmdDown
        case .leftOption:
            newActive = leftOptDown
        case .control:
            newActive = leftCtrlDown || rightCtrlDown
        case .rightCommand:
            newActive = rightCmdDown
        case .rightOption:
            newActive = rightOptDown
        case .commandRightShift:
            newActive = (leftCmdDown || rightCmdDown) && rightShiftDown
        case .optionRightShift:
            newActive = (leftOptDown || rightOptDown) && rightShiftDown
        case .f5:
            newActive = false // handled via Carbon hotkey instead
        }

        // Guard against state transitions triggering both down and up in the same event
        // Only trigger state transitions on actual state changes
        let stateChanged = newActive != selectionActive
        if stateChanged {
            if newActive {
                scheduleHotkeyDown()
            } else {
                cancelPendingActivation()
                handleHotkeyUp()
            }
        }
        selectionActive = newActive
    }

    private func handleKeyDown(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard !Self.isModifierKey(keyCode) else { return }
        guard pendingActivationWorkItem != nil else { return }

        AppLog.hotkeys.log("Cancelled modifier hotkey activation because keyCode=\(keyCode) followed the modifier")
        cancelPendingActivation()
        hotkeyPressStart = nil
        activateCalledOnThisPress = false
    }

    private func scheduleHotkeyDown() {
        guard !Self.isActivationSuppressed else { return }
        cancelPendingActivation()
        let start = Date()
        hotkeyPressStart = start
        activateCalledOnThisPress = false
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !Self.isActivationSuppressed else { return }
            guard self.selectionActive, self.hotkeyPressStart == start else { return }
            self.pendingActivationWorkItem = nil
            self.onActivate?()
            self.activateCalledOnThisPress = true
        }
        pendingActivationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierActivationDelay, execute: item)
    }

    private func handleHotkeyDown() {
        guard !Self.isActivationSuppressed else { return }
        cancelPendingActivation()
        hotkeyPressStart = Date()
        activateCalledOnThisPress = false
        onActivate?()
        activateCalledOnThisPress = true
    }

    private func handleHotkeyUp() {
        guard !Self.isActivationSuppressed else {
            hotkeyPressStart = nil
            activateCalledOnThisPress = false
            return
        }
        guard let start = hotkeyPressStart else { return }
        hotkeyPressStart = nil
        let duration = Date().timeIntervalSince(start)
        // Prevent double-invocation: only toggle on release if we haven't already called onActivate on this press
        if duration >= briefPressThreshold && !activateCalledOnThisPress {
            // Held long enough: push-to-talk ends on release
            onActivate?()
        } else if duration >= briefPressThreshold && activateCalledOnThisPress {
            // Short hold: was already triggered on down, don't duplicate
        } else {
            // Short tap: hands-free mode (stay recording); next press will toggle stop
        }
        activateCalledOnThisPress = false
    }

    private func cancelPendingActivation() {
        pendingActivationWorkItem?.cancel()
        pendingActivationWorkItem = nil
    }


    private func handlePasteUp() {
        guard !Self.isActivationSuppressed else { return }
        // Fire on key up with a slight delay to let user release modifiers
        // Debounce in case we receive spurious duplicate key-up events
        let now = Date()
        if let last = lastPasteTrigger, now.timeIntervalSince(last) < 0.25 { return }
        lastPasteTrigger = now
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "?"
        let bundle = app?.bundleIdentifier ?? "?"
        AppLog.hotkeys.log("Paste hotkey released; will paste into frontmost=\(name) (\(bundle)) after delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onPaste?()
        }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func isModifierKey(_ keyCode: CGKeyCode) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_Shift, kVK_RightShift,
             kVK_Function:
            return true
        default:
            return false
        }
    }

    deinit {
        unregisterCarbonHotkey(ref: &toggleHotKeyRef)
        unregisterCarbonHotkey(ref: &pasteHotKeyRef)
        stopFnTap()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }
}
