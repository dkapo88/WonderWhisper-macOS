import Foundation
import Carbon.HIToolbox
import Cocoa

/// Shared shortcut types and the single legacy Carbon hotkey still in use: Paste Last.
/// Prompt activation is owned by `PromptHotkeyManager`.
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
    defer { suppressionLock.unlock() }
    if let deadline = suppressedUntil, deadline <= Date() {
      suppressedUntil = nil
    }
    return suppressedUntil.map { $0 > Date() } ?? false
  }

  enum Selection: String, CaseIterable, Codable {
    case fnGlobe
    case leftCommand
    case leftOption
    case control
    case rightCommand
    case rightOption
    case commandRightShift
    case optionRightShift
    case backslash
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
      case .backslash: return "Backslash (\\)"
      case .f5: return "F5"
      }
    }

    var directShortcut: Shortcut? {
      switch self {
      case .f5: return Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
      default: return nil
      }
    }

    var requiresAX: Bool {
      switch self {
      case .f5: return true
      default: return directShortcut == nil
      }
    }

    var needsChordGuard: Bool {
      switch self {
      case .fnGlobe, .leftCommand, .leftOption, .control, .rightCommand,
           .rightOption, .commandRightShift, .optionRightShift:
        return true
      case .backslash, .f5:
        return false
      }
    }
  }

  struct Shortcut: Equatable, Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
  }

  var onPaste: (() -> Void)?
  var pasteShortcut: Shortcut? { didSet { registerPasteHotkey() } }

  private var pasteHotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var lastPasteTrigger: Date?

  private func ensureEventHandlerInstalled() {
    guard eventHandlerRef == nil else { return }
    let specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      )
    ]
    let callback: EventHandlerUPP = { _, event, userData in
      guard let event, let userData else { return noErr }
      let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
      var hotkeyID = EventHotKeyID()
      var size = MemoryLayout<EventHotKeyID>.size
      let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        size,
        &size,
        &hotkeyID
      )
      if status == noErr, hotkeyID.id == 2 {
        manager.handlePasteRelease()
      }
      return noErr
    }
    let userPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let status = specs.withUnsafeBufferPointer { buffer in
      InstallEventHandler(
        GetApplicationEventTarget(),
        callback,
        buffer.count,
        buffer.baseAddress,
        userPointer,
        &eventHandlerRef
      )
    }
    if status != noErr {
      AppLog.hotkeys.error("Failed to install paste hotkey handler: status=\(status)")
    }
  }

  private func registerPasteHotkey() {
    unregisterPasteHotkey()
    guard let shortcut = pasteShortcut else { return }
    ensureEventHandlerInstalled()

    let hotkeyID = EventHotKeyID(signature: OSType(0x57575056), id: 2)
    var reference: EventHotKeyRef?
    var status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      hotkeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    if status != noErr || reference == nil {
      status = RegisterEventHotKey(
        shortcut.keyCode,
        shortcut.modifiers,
        hotkeyID,
        GetEventDispatcherTarget(),
        0,
        &reference
      )
    }
    if status == noErr, let reference {
      pasteHotKeyRef = reference
      AppLog.hotkeys.log(
        "Registered paste hotkey keyCode=\(shortcut.keyCode) mods=\(shortcut.modifiers)"
      )
    } else {
      AppLog.hotkeys.error("Failed to register paste hotkey: status=\(status)")
    }
  }

  private func unregisterPasteHotkey() {
    if let pasteHotKeyRef {
      UnregisterEventHotKey(pasteHotKeyRef)
    }
    pasteHotKeyRef = nil
  }

  private func handlePasteRelease() {
    guard !Self.isActivationSuppressed else { return }
    let now = Date()
    if let lastPasteTrigger, now.timeIntervalSince(lastPasteTrigger) < 0.25 { return }
    lastPasteTrigger = now
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.onPaste?()
    }
  }

  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
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
    unregisterPasteHotkey()
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }
}
