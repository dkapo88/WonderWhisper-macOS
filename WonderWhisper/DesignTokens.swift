import SwiftUI

/// The app's small spacing / radius / width scale. Settings surfaces lean on `Form` for row
/// spacing, so custom values should be rare; when one is needed, pick it from here instead of
/// inventing a new literal.
enum DesignTokens {
  enum Spacing {
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
  }

  enum Radius {
    /// Inline controls and small chips.
    static let control: CGFloat = 6
    /// Cards and grouped content inside the main window.
    static let card: CGFloat = 10
    /// Floating panels (overlay pill, companion, response windows).
    static let panel: CGFloat = 16
  }

  enum Width {
    /// Readable width for settings forms; System Settings caps its content similarly.
    static let settingsContent: CGFloat = 720
    /// Fixed size of the Settings window content.
    static let settingsWindow: CGFloat = 680
    static let settingsWindowHeight: CGFloat = 620
  }
}
