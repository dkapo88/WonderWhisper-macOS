import SwiftUI

/// Settings → Integrations: Codex, Beeper, and the Hermes connection, one at a time.
struct IntegrationsSettingsPane: View {
  @ObservedObject var vm: DictationViewModel
  @ObservedObject var router: SettingsRouter

  var body: some View {
    VStack(spacing: 0) {
      Picker("Integration", selection: $router.selectedIntegration) {
        ForEach(SettingsTab.Integration.allCases) { integration in
          Text(integration.title).tag(integration)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(.top, DesignTokens.Spacing.medium)
      .accessibilityLabel("Integration")

      switch router.selectedIntegration {
      case .codex:
        CodexSettingsForm(vm: vm)
      case .beeper:
        BeeperSettingsForm(vm: vm)
      case .hermes:
        HermesSettingsForm(vm: vm)
      }
    }
  }
}
