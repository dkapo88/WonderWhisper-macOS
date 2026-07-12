import Foundation
import ApplicationServices
import AppKit
import Carbon.HIToolbox

final class ScreenContextService {
    private let backgroundQueue = DispatchQueue(label: "com.wonderwhisper.screencontext", qos: .utility)
    private let clipboardQueue = DispatchQueue(label: "com.wonderwhisper.screencontext.clipboard", qos: .userInitiated)
    
    func frontmostAppNameAndBundle() -> (name: String?, bundleId: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    func activeTextField() -> String? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        // CFGetTypeID check above ensures this is an AXUIElement
        let axElement = (element as! AXUIElement)
        AXUIElementSetMessagingTimeout(axElement, 0.25)
        // Avoid reading from secure inputs
        if isSecureTextElement(axElement) { return nil }

        // If there is already a selection, prefer that and avoid altering selection state
        if let existingSelection = selectedTextFast(), !existingSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLog.dictation.log("Active text field: skipping because selected text exists (\(existingSelection.count) chars)")
            return nil
        }

        if let direct = copyValueAttribute(from: axElement) {
            return direct
        }

        if let entireRange = copyEntireRangeValue(from: axElement) {
            return entireRange
        }

        if let childValue = copyValueFromChildren(from: axElement) {
            return childValue
        }

        if let selection = copySelectedValue(from: axElement), !selection.isEmpty {
            return selection
        }

        return nil
    }

    private func copyValueFromChildren(from element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 1 { return nil }

        AXUIElementSetMessagingTimeout(element, 0.25)
        var childrenObj: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenObj)
        guard err == .success, let children = childrenObj as? [AXUIElement] else { return nil }

        for child in children {
            if let val = copyValueAttribute(from: child), !val.isEmpty {
                return val
            }
            if let val = copyEntireRangeValue(from: child), !val.isEmpty {
                return val
            }
        }

        if depth == 0 {
            for child in children {
                if let val = copyValueFromChildren(from: child, depth: depth + 1) {
                    return val
                }
            }
        }
        return nil
    }

    private func copyValueAttribute(from element: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return extractString(from: value)
    }

    private func copyEntireRangeValue(from element: AXUIElement) -> String? {
        guard let lengthNumber = numberOfCharacters(in: element) else { return nil }
        if lengthNumber <= 0 { return "" }

        var range = CFRange(location: 0, length: CFIndex(lengthNumber))
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        guard err == .success else { return nil }
        return extractString(from: value)
    }

    private func copySelectedValue(from element: AXUIElement) -> String? {
        var selected: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        guard err == .success else { return nil }
        return extractString(from: selected)
    }

    private func numberOfCharacters(in element: AXUIElement) -> Int? {
        var lengthValue: AnyObject?
        let lenErr = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &lengthValue)
        guard lenErr == .success else { return nil }
        return (lengthValue as? NSNumber)?.intValue
    }

    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        var roleObj: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObj)
        let role = roleObj as? String ?? ""
        if role == "AXSecureTextField" { return true }

        var subroleObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObj) == .success {
            let subrole = subroleObj as? String ?? ""
            if subrole.localizedCaseInsensitiveContains("secure") { return true }
        }
        return false
    }

    private func extractString(from value: AnyObject?) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    func selectedText() -> String? {
        // Try Accessibility APIs first (fast, non-destructive)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .success, let element = focused {
            // Direct selected text
            var sel: AnyObject?
            guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
            let axElement = (element as! AXUIElement)
            AXUIElementSetMessagingTimeout(axElement, 0.25)
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
        // AX APIs failed; try pasteboard fallback for better cross-app compatibility
        if let pasteboardText = clipboardQueue.sync(execute: copySelectedTextNonDestructively) {
            return pasteboardText
        }
        return nil
    }

    func selectedTextFast() -> String? {
        // Fast path: AX only, no 600ms pasteboard fallback
        // Used during recording start for minimal latency
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .success, let element = focused {
            var sel: AnyObject?
            guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
            let axElement = (element as! AXUIElement)
            AXUIElementSetMessagingTimeout(axElement, 0.25)
            let res = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &sel)
            if res == .success, let s = sel as? String, !s.isEmpty { return s }

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
        return nil
    }

    func captureFullScreenContextTerms(preferAccurate: Bool) async -> ScreenContextPreprocessingResult? {
        return await withCheckedContinuation { continuation in
            backgroundQueue.async {
                let svc = ScreenCaptureService()
                let correctionHints = ScreenContextPreprocessor.defaultCorrectionHints()
                let preprocessor = ScreenContextPreprocessor(correctionHints: correctionHints)
                Task {
                    guard let snapshot = await svc.captureActiveDisplayImage(
                        maxDimension: 4096,
                        lossless: true
                    ) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let text = await svc.recognizeText(
                        from: snapshot,
                        preferAccurate: preferAccurate,
                        customWords: correctionHints
                    ),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let result = await preprocessor.preprocess(ocrText: text)
                    continuation.resume(returning: result)
                }
            }
        }
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
        let afterClear = pb.changeCount

        // Try AX menu "Copy" first; fallback to synthesizing Cmd+C
        if !axPressCopyInFrontApp() {
            synthesizeCmdC()
        }

        // Wait for the pasteboard to change (up to ~350ms) rather than a fixed sleep
        _ = waitForPasteboardChange(since: afterClear, timeout: 0.35)

        // Read best-effort string from pasteboard (plain text -> RTF)
        if let s = readStringFromPasteboard(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let observed = pb.changeCount
            restorePasteboard(snap, ifChangeCountEquals: observed)
            return s
        }

        // Retry once with a direct Cmd+C (some apps ignore the AX menu path intermittently)
        pb.clearContents()
        let afterClear2 = pb.changeCount
        synthesizeCmdC()
        _ = waitForPasteboardChange(since: afterClear2, timeout: 0.25)
        if let s2 = readStringFromPasteboard(), !s2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let observed2 = pb.changeCount
            restorePasteboard(snap, ifChangeCountEquals: observed2)
            return s2
        }

        // Nothing captured; restore original clipboard if still untouched
        let observedFinal = pb.changeCount
        restorePasteboard(snap, ifChangeCountEquals: observedFinal)
        return nil
    }

    private func waitForPasteboardChange(since base: Int, timeout: TimeInterval) -> Int? {
        let pb = NSPasteboard.general
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let c = pb.changeCount
            if c > base { return c }
            usleep(10_000) // 10ms
        }
        return nil
    }

    private func readStringFromPasteboard() -> String? {
        let pb = NSPasteboard.general
        guard pb.pasteboardItems?.isEmpty == false else { return nil }
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let rtfData = pb.data(forType: .rtf),
           let attr = try? NSAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
           ) {
            let text = attr.string
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    func axPressCopyInFrontApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.25)
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
        AXUIElementSetMessagingTimeout(element, 0.25)
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
