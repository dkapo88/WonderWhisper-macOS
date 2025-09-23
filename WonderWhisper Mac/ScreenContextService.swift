import Foundation
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Vision

final class ScreenContextService {
    func frontmostAppNameAndBundle() -> (name: String?, bundleId: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    func focusedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        var value: AnyObject?
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let axElement = element as! AXUIElement
        let err2 = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value)
        if err2 == .success, let str = value as? String { return str }
        return nil
    }

    func selectedText() -> String? {
        // 1) Try AX APIs first (fast path)
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .success, let element = focused {
            // Direct selected text
            var sel: AnyObject?
            guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
            let axElement = element as! AXUIElement
            let res = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &sel)
            if res == .success, let s = sel as? String, !s.isEmpty { return s }
            // Range-based selected text
            var rangeValue: AnyObject?
            let res2 = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
            if res2 == .success, let axRange = rangeValue {
                var strForRange: AnyObject?

                let paramRes = AXUIElementCopyParameterizedAttributeValue(
                    axElement,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    axRange,
                    &strForRange
                )
                if paramRes == .success, let s = strForRange as? String, !s.isEmpty { return s }
            }
        }
        // 2) Fallback: non-destructive copy-based capture (works in many Electron/Chromium apps)
        return copySelectedTextNonDestructively()
    }

    func captureActiveWindowText() async -> String? {
        let svc = ScreenCaptureService()
        return await svc.captureActiveWindowText()
    }

}

private extension ScreenContextService {
    struct PasteboardSnapshot { let items: [[NSPasteboard.PasteboardType: Data]] }

    func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    func restorePasteboard(_ snapshot: PasteboardSnapshot, ifChangeCountEquals changeCount: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == changeCount else { return }
        pb.clearContents()
        let newItems: [NSPasteboardItem] = snapshot.items.map { mapping in
            let item = NSPasteboardItem()
            for (type, data) in mapping { item.setData(data, forType: type) }
            return item
        }
        if !newItems.isEmpty {
            pb.writeObjects(newItems as [NSPasteboardWriting])
        }
    }

    func copySelectedTextNonDestructively() -> String? {
        // Avoid copying from ourselves
        if let bundleID = Bundle.main.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return nil
        }
        let pb = NSPasteboard.general
        let snap = snapshotPasteboard()
        // Clear to isolate next copy
        pb.clearContents()

        // Try AX menu "Copy" first; fallback to synthesizing Cmd+C
        if !axPressCopyInFrontApp() {
            synthesizeCmdC()
        }
        // Allow time for clipboard update
        Thread.sleep(forTimeInterval: 0.12)

        let text = pb.string(forType: .string)
        let ourChange = pb.changeCount
        // Restore prior clipboard if nothing else changed since
        restorePasteboard(snap, ifChangeCountEquals: ourChange)
        if let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return nil
    }

    func axPressCopyInFrontApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        var menubarObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXMenuBarAttribute as CFString, &menubarObj) == .success,
              let menubarCF = menubarObj else { return false }
        guard CFGetTypeID(menubarCF) == AXUIElementGetTypeID() else { return false }
        let menubar = menubarCF as! AXUIElement
        if let item = findMenuItem(in: menubar, titled: "Copy") {
            let res = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return res == .success
        }
        return false
    }

    func findMenuItem(in element: AXUIElement, titled title: String, depth: Int = 0) -> AXUIElement? {
        if depth > 6 { return nil }
        var childrenObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenObj) != .success { return nil }
        guard let children = childrenObj as? [AXUIElement] else { return nil }
        for child in children {
            var roleObj: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleObj)
            let role = roleObj as? String ?? ""
            if role == (kAXMenuItemRole as String) {
                var titleObj: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleObj)
                let t = titleObj as? String ?? ""
                if t == title || t.localizedCaseInsensitiveContains(title) {
                    return child
                }
            }
            if let found = findMenuItem(in: child, titled: title, depth: depth + 1) { return found }
        }
        return nil
    }

    func synthesizeCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyC: CGKeyCode = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
