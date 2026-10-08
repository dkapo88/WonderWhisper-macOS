import AppKit
import SwiftUI

/// Shared navigation state for the Settings window and the main window, so any surface
/// (a toolbar gear, the menu bar menu) can open Settings on a specific tab or bring the main
/// window back.
@MainActor
final class SettingsRouter: ObservableObject {
  static let shared = SettingsRouter()

  static let mainWindowID = "main"

  @Published var selectedTab: SettingsTab = .general
  @Published var selectedIntegration: SettingsTab.Integration = .codex

  /// Captured from a live SwiftUI environment; used when the app-menu route is unavailable.
  var openSettingsAction: OpenSettingsAction?
  var openWindowAction: OpenWindowAction?

  private init() {}

  /// Selects a tab (and optionally an integration) and opens the Settings window.
  func show(_ tab: SettingsTab, integration: SettingsTab.Integration? = nil) {
    selectedTab = tab
    if let integration {
      selectedIntegration = integration
    }
    openSettingsWindow()
  }

  /// Opens the Settings scene. The app menu's own "Settings…" item is the most reliable route
  /// from AppKit code (`showSettingsWindow:` is ignored on macOS 14+), with the SwiftUI
  /// `openSettings` action as a fallback.
  func openSettingsWindow() {
    NSApp.activate()
    if let (menu, index) = Self.settingsMenuItemLocation() {
      menu.performActionForItem(at: index)
    } else {
      openSettingsAction?()
    }
  }

  /// Brings the main window forward, recreating it if it was closed.
  func openMainWindow() {
    NSApp.activate()
    if let window = NSApp.windows.first(where: Self.isMainWindow) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindowAction?(id: Self.mainWindowID)
    }
  }

  private static func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix(mainWindowID) == true
  }

  private static func settingsMenuItemLocation() -> (NSMenu, Int)? {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return nil }
    guard let index = appMenu.items.firstIndex(where: {
      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
    }) else { return nil }
    return (appMenu, index)
  }
}
