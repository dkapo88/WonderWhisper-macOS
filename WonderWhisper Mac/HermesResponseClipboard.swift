import AppKit

enum HermesResponseClipboard {
  @discardableResult
  @MainActor
  static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}
