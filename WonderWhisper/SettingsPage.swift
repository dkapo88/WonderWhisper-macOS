import SwiftUI

/// Standard container for every settings surface: a grouped `Form` (System Settings style
/// rows, full-width groups, header/footer text) capped at a readable width.
///
/// Layout rules for content:
/// - One row = one setting. Label left, control right (`LabeledContent`, `Toggle`, `Picker`).
/// - One line of help goes in the row's secondary text; anything longer goes in the footer.
/// - Booleans are `Toggle`s. 2-3 options use a segmented picker, 4+ use a popup.
/// - Destructive actions are text buttons at the end of a section, never icon-only.
struct SettingsPage<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    Form {
      content
    }
    .formStyle(.grouped)
    .frame(maxWidth: DesignTokens.Width.settingsContent)
    .frame(maxWidth: .infinity)
  }
}

extension View {
  /// Secondary help text for settings rows and section footers.
  func settingsFootnote() -> some View {
    font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
