import SwiftUI

/// One settings row for a Keychain-backed secret: label, status, and an inline secure field.
/// Replaces the per-service "status line + SecureField + Save key" blocks.
///
/// The row never shows the stored value. When a key is saved it shows a "Saved" badge and a
/// Replace button; otherwise (or while replacing) it shows the field and Save.
struct APIKeyRow: View {
  let title: String
  let alias: String
  var prompt: String = "Paste key"
  var detail: String?
  /// Whether a stored value counts as a usable key (e.g. Groq keys must start with `gsk_`).
  var isStoredValueValid: (String) -> Bool = { _ in true }
  let onSave: (String) -> Void

  @State private var input = ""
  @State private var isReplacing = false
  @State private var hasKey = false

  private let keychain = KeychainService()

  var body: some View {
    LabeledContent {
      if hasKey && !isReplacing {
        HStack(spacing: DesignTokens.Spacing.small) {
          StatusBadge(.ok, "Saved")
          Button("Replace…") { isReplacing = true }
            .accessibilityLabel("Replace \(title)")
        }
      } else {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          SecureField(title, text: $input, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .onSubmit(save)
            .accessibilityLabel(title)
          Button("Save", action: save)
            .disabled(trimmedInput.isEmpty)
            .accessibilityLabel("Save \(title)")
          if isReplacing {
            Button("Cancel") {
              input = ""
              isReplacing = false
            }
          }
        }
      }
    } label: {
      Text(title)
      if let subtitle {
        Text(subtitle)
      }
    }
    .onAppear(perform: refresh)
  }

  private var subtitle: String? {
    if hasKey { return detail }
    guard let detail else { return "Not saved" }
    return "Not saved. \(detail)"
  }

  private var trimmedInput: String {
    KeychainService.normalizedSecret(input)
  }

  private func save() {
    let value = trimmedInput
    guard !value.isEmpty else { return }
    onSave(value)
    refresh()
    // Only clear the field once the Keychain actually holds the new value; a rejected key
    // (for example a malformed Groq key) stays in the field so it can be corrected.
    if keychain.getSecret(forKey: alias) == value {
      input = ""
      isReplacing = false
    }
  }

  private func refresh() {
    hasKey = keychain.getSecret(forKey: alias).map(isStoredValueValid) ?? false
  }
}
