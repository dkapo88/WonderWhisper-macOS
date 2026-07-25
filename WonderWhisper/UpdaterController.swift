import Foundation
import Combine
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// Sparkle checks on its own schedule (see `SUScheduledCheckInterval` in Info.plist) and presents
/// its own update UI, so this wrapper only exists to expose a manual "Check for Updates…" action
/// and to publish whether a check is currently allowed (Sparkle disables it mid-check).
///
/// Updates are verified twice before install: an EdDSA signature over the DMG (`SUPublicEDKey`)
/// and a check that the new build's code signature matches the running app. That second check is
/// why an update cannot silently swap in a differently-signed build and reset the user's
/// Accessibility/Microphone grants.
@MainActor
final class UpdaterController: ObservableObject {
  static let shared = UpdaterController()

  private let updaterController: SPUStandardUpdaterController

  /// False while a check is already running, so the menu item can disable itself.
  @Published private(set) var canCheckForUpdates = false

  private init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    updaterController.updater
      .publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }

  func checkForUpdates() {
    updaterController.updater.checkForUpdates()
  }
}
