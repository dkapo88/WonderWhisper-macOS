import SwiftUI

/// Slim banner at the top of the main window while a required macOS permission is missing.
struct PermissionsBanner: View {
  let missing: [String]
  let onReview: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.small) {
      StatusBadge(.warning, message)
      Spacer(minLength: DesignTokens.Spacing.xSmall)
      Button("Review…", action: onReview)
        .controlSize(.small)
        .accessibilityLabel("Review permissions in Settings")
    }
    .padding(.horizontal, DesignTokens.Spacing.medium)
    .padding(.vertical, DesignTokens.Spacing.xSmall)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var message: String {
    let list = ListFormatter.localizedString(byJoining: missing)
    return missing.count == 1
      ? "\(list) permission is missing."
      : "\(list) permissions are missing."
  }
}
