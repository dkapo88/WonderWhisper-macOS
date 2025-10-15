import Foundation
import AppKit
import Carbon.HIToolbox

final class InsertionService {
    var useAXInsertion: Bool = false

    func insert(_ text: String) {
        // Special-case: if our app is frontmost, insert directly into the first responder text view
        if let bundleID = Bundle.main.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
           insertIntoFirstResponder(text) {
            return
        }
        // Strategy 1: AX direct insertion when enabled
        if useAXInsertion, setFocusedAXValue(text) {
            return
        }
        // Fallback: write to pasteboard (optionally as rich text) + Command-V with clipboard restore
        let snapshot = snapshotPasteboard()
        let pb = NSPasteboard.general
        pb.clearContents()

        // Prefer rich text (HTML/RTF) if enabled; always include plain text as a fallback
        let preferFormatted = UserDefaults.standard.bool(forKey: "insertion.pasteFormatted")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if preferFormatted {
            if let htmlData = buildHTMLData(from: text) {
                // public.html
                item.setData(htmlData, forType: .html)
                // Some apps (Electron/web) explicitly look for text/html
                item.setData(htmlData, forType: NSPasteboard.PasteboardType("text/html"))
            }
            if let rtfData = buildRTFData(from: text) {
                item.setData(rtfData, forType: .rtf)
            }
        }
        pb.writeObjects([item])

        let ourChange = pb.changeCount
        // Paste strategy selection:
        // - Prefer AppleScript for known-problematic apps (Slack/Electron/Chromium/UpNote)
        // - Otherwise try AX menu Paste first
        // - Always fall back to synthesized Command+V if the chosen method fails
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let preferAppleScript = shouldPreferAppleScript(for: frontBundle) || UserDefaults.standard.bool(forKey: "insertion.useAppleScriptPaste")
        if preferAppleScript {
            if !pasteUsingAppleScript() {
                // Try AX paste, then CGEvent as last resort
                if !axPressPasteInFrontApp() { synthesizeCmdV() }
            }
        } else {
            if !axPressPasteInFrontApp() {
                if !pasteUsingAppleScript() { synthesizeCmdV() }
            }
        }
        let fast = UserDefaults.standard.bool(forKey: "insertion.fastMode")
        let delay: TimeInterval = fast ? 0.12 : 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restorePasteboard(snapshot, ifChangeCountEquals: ourChange)
        }
    }

    private func shouldPreferAppleScript(for bundleID: String) -> Bool {
        // Known apps where CGEvent Cmd+V can be ignored intermittently
        let prefer: Set<String> = [
            "com.tinyspeck.slackmacgap",     // Slack
            "com.google.Chrome",             // Chrome
            "com.brave.Browser",             // Brave
            "com.microsoft.edgemac",         // Edge
            "org.mozilla.firefox",           // Firefox
            "com.getupnote.desktop"          // UpNote (Electron)
        ]
        if prefer.contains(bundleID) { return true }
        // Heuristic: Electron-based apps often have bundle IDs containing "electron"
        return bundleID.lowercased().contains("electron")
    }

    private func pasteUsingAppleScript() -> Bool {
        // Requires Automation (Apple Events) permission to control System Events
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        var err: NSDictionary?
        let ok = NSAppleScript(source: script)?.executeAndReturnError(&err) != nil
        if !ok {
            let msg = (err?[NSAppleScript.errorMessage as String] as? String) ?? "unknown error"
            AppLog.insertion.error("AppleScript paste error: \(msg)")
        }
        return ok
    }

    private func insertIntoFirstResponder(_ text: String) -> Bool {
        var success = false
        DispatchQueue.main.sync {
            if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
                responder.insertText(text, replacementRange: responder.selectedRange())
                success = true
            }
        }
        return success
    }

    private func setFocusedAXValue(_ text: String) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return false }
        let res = AXUIElementSetAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, text as CFTypeRef)
        return res == .success
    }

    private func synthesizeCmdV() {
        // Use HID system state to mimic real keyboard
        let src = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        let keyCmd: CGKeyCode = 0x37 // left Command virtual key

        // Detect currently held modifiers that could interfere with paste (not Command)
        let modsToTempRelease: [CGKeyCode] = [
            CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
            CGKeyCode(kVK_Option),  CGKeyCode(kVK_RightOption),
            CGKeyCode(kVK_Shift),   CGKeyCode(kVK_RightShift)
        ].filter { CGEventSource.keyState(.hidSystemState, key: $0) }

        // Temporarily release interfering modifiers (do NOT touch Command)
        for code in modsToTempRelease {
            let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }

        // Explicit Command down
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: keyCmd, keyDown: true)
        cmdDown?.post(tap: .cghidEventTap)

        // V down/up with Command flag set
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Command up
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: keyCmd, keyDown: false)
        cmdUp?.post(tap: .cghidEventTap)

        // Restore previously held modifiers
        for code in modsToTempRelease {
            let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            down?.post(tap: .cghidEventTap)
        }
    }

    private func axPressPasteInFrontApp() -> Bool {
        // Requires Accessibility permission; works under sandbox
        let ws = NSWorkspace.shared
        guard let app = ws.frontmostApplication else { return false }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        var menubarObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXMenuBarAttribute as CFString, &menubarObj) == .success,
              let menubarCF = menubarObj else { return false }
        let menubar = menubarCF as! AXUIElement
        if let item = findPasteMenuItem(in: menubar) {
            let res = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return res == .success
        }
        return false
    }

    private func findPasteMenuItem(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 6 { return nil } // avoid runaway recursion
        var childrenObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenObj) != .success { return nil }
        guard let children = childrenObj as? [AXUIElement] else { return nil }
        for child in children {
            // Check if this child is a menu item that looks like Paste
            var roleObj: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleObj)
            let role = roleObj as? String ?? ""
            if role == (kAXMenuItemRole as String) {
                var titleObj: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleObj)
                let title = (titleObj as? String)?.lowercased() ?? ""
                var cmdCharObj: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(child, kAXMenuItemCmdCharAttribute as CFString, &cmdCharObj)
                let cmdChar = (cmdCharObj as? String)?.lowercased()
                if title.contains("paste") || cmdChar == "v" {
                    return child
                }
            }
            if let found = findPasteMenuItem(in: child, depth: depth + 1) { return found }
        }
        return nil
    }


    // MARK: - Formatting helpers
    private func buildHTMLData(from text: String) -> Data? {
        // Convert double newlines to paragraphs, single newlines to <br>
        func htmlEscape(_ s: String) -> String {
            var out = s
            out = out.replacingOccurrences(of: "&", with: "&amp;")
            out = out.replacingOccurrences(of: "<", with: "&lt;")
            out = out.replacingOccurrences(of: ">", with: "&gt;")
            return out
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Split paragraphs on 2+ consecutive newlines
        let normalized = trimmed.replacingOccurrences(of: "\r", with: "")
        let paraDelimiter = "\u{0001}"
        let collapsed = normalized.replacingOccurrences(of: "\\n{2,}", with: paraDelimiter, options: .regularExpression)
        let paras = collapsed.components(separatedBy: paraDelimiter)
        let body = paras.map { p in
            let esc = htmlEscape(p)
            let withBR = esc.replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(withBR)</p>"
        }.joined()
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\">
          <style>body{white-space:pre-wrap;} p{margin:0 0 12px 0;}</style>
        </head>
        <body>\(body)</body>
        </html>
        """
        return html.data(using: String.Encoding.utf8)
    }

    private func buildRTFData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8 // points after each paragraph
        let attr = NSAttributedString(string: trimmed, attributes: [.paragraphStyle: style])
        return try? attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: - Clipboard snapshot/restore
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types {
                if let d = item.data(forType: t) { dict[t] = d }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, ifChangeCountEquals changeCount: Int) {
        let pb = NSPasteboard.general
        // Do not clobber user clipboard if they copied something else since
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
}
