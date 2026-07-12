import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderView: View {
    @Binding var shortcut: HotkeyManager.Shortcut
    @State private var isRecording: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shortcutDescription(shortcut))
                .monospaced()
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))

            HStack(spacing: 8) {
                Button(isRecording ? "Press keys…" : "Change…") { isRecording.toggle() }
                Button("Reset") {
                    shortcut = HotkeyManager.Shortcut(
                        keyCode: UInt32(kVK_ANSI_V),
                        modifiers: UInt32(cmdKey | controlKey)
                    )
                }
            }

            ShortcutCaptureRepresentable(isRecording: $isRecording) { evt in
                if let evt = evt, let sc = shortcutFromEvent(evt) {
                    shortcut = sc
                }
                isRecording = false
            }
            .frame(width: 0, height: 0)
        }
    }
}

// MARK: - Helpers
private func shortcutDescription(_ s: HotkeyManager.Shortcut) -> String {
    var parts: [String] = []
    if s.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
    if s.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if s.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if s.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    parts.append(keyName(from: UInt16(s.keyCode)))
    return parts.joined()
}

private func keyName(from code: UInt16) -> String {
    // Explicit mapping because Carbon key codes are non-contiguous and not sorted
    let letters: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O", UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z"
    ]
    if let name = letters[code] { return name }

    let digits: [UInt16: String] = [
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7",
        UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_9): "9"
    ]
    if let name = digits[code] { return name }

    let fMap: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]
    if let name = fMap[code] { return name }

    let specials: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Help): "Help",
    ]
    if let s = specials[code] { return s }

    let punctuation: [UInt16: String] = [
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_Grave): "`",
    ]
    if let p = punctuation[code] { return p }

    return "Key_\(code)"
}

private func isModifierKey(_ code: UInt16) -> Bool {
    let mods: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_CapsLock), UInt16(kVK_Option), UInt16(kVK_Control),
        UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl), UInt16(kVK_RightCommand)
    ]
    return mods.contains(code)
}

private func shortcutFromEvent(_ event: NSEvent) -> HotkeyManager.Shortcut? {
    let code = UInt16(event.keyCode)
    if isModifierKey(code) { return nil }
    let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
    return HotkeyManager.Shortcut(keyCode: UInt32(code), modifiers: modifiers)
}

// MARK: - NSView for capturing keydown
private struct ShortcutCaptureRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onComplete: (NSEvent?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let v = ShortcutCaptureView()
        v.onComplete = onComplete
        return v
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.onComplete = onComplete
        if isRecording {
            DispatchQueue.main.async { nsView.beginCapture(); nsView.window?.makeFirstResponder(nsView) }
        } else {
            nsView.endCapture()
        }
    }
}

private final class ShortcutCaptureView: NSView {
    var onComplete: ((NSEvent?) -> Void)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    func beginCapture() {
        endCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evt in
            self?.onComplete?(evt)
            return nil // swallow
        }
    }

    func endCapture() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { endCapture() }
}
