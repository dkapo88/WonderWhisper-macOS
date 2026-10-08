import Foundation

/// Classifies the free-form `DictationViewModel.settingsNotice` strings for display.
enum SettingsNotice {
  private static let successMarkers = ["saved", "ready", "connected"]
  private static let errorMarkers = [
    "could not", "couldn't", "failed", "invalid", "error", "already assigned", "should start",
    "missing", "not "
  ]

  static func kind(for notice: String) -> StatusBadge.Kind {
    let lowered = notice.lowercased()
    if errorMarkers.contains(where: lowered.contains) { return .error }
    if successMarkers.contains(where: lowered.contains) { return .ok }
    return .neutral
  }
}
