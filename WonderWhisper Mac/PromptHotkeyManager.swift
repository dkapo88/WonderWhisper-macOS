import Foundation
import Carbon.HIToolbox
import Cocoa

final class PromptHotkeyManager {
    private struct Entry {
        let promptID: UUID
        let ref: EventHotKeyRef
    }

    private var nextIdentifier: UInt32 = 100
    private var entries: [UInt32: Entry] = [:]
    private var handlerRef: EventHandlerRef?

    var onActivatePrompt: ((UUID) -> Void)?

    func register(shortcut: HotkeyManager.Shortcut, for promptID: UUID) {
        unregister(promptID: promptID)
        ensureHandler()

        let identifier = nextIdentifier
        nextIdentifier &+= 1
        var hotKeyID = EventHotKeyID(signature: OSType(0x57575054), id: identifier) // 'WWPT'
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let ref = hotKeyRef else { return }
        entries[identifier] = Entry(promptID: promptID, ref: ref)
    }

    func unregister(promptID: UUID) {
        guard let pair = entries.first(where: { $0.value.promptID == promptID }) else { return }
        UnregisterEventHotKey(pair.value.ref)
        entries.removeValue(forKey: pair.key)
    }

    func unregisterAll() {
        for entry in entries.values {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func ensureHandler() {
        guard handlerRef == nil else { return }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        let callback: EventHandlerUPP = { (_, evt, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<PromptHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            var size = MemoryLayout<EventHotKeyID>.size
            let status = GetEventParameter(evt, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, size, &size, &hotKeyID)
            guard status == noErr, let entry = manager.entries[hotKeyID.id] else { return noErr }
            manager.onActivatePrompt?(entry.promptID)
            return noErr
        }
        let target = GetApplicationEventTarget()
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(target, callback, specs.count, specs, ptr, &handlerRef)
    }
}
