import SwiftUI

/// Root of the Settings window (Cmd+,): one toolbar tab per area, each a grouped form.
struct SettingsRootView: View {
  @ObservedObject var vm: DictationViewModel
  @ObservedObject var router: SettingsRouter = .shared
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    TabView(selection: $router.selectedTab) {
      ForEach(SettingsTab.allCases) { tab in
        pane(for: tab)
          .tabItem { Label(tab.title, systemImage: tab.systemImage) }
          .tag(tab)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      noticeBar
    }
    .frame(
      width: DesignTokens.Width.settingsWindow,
      height: DesignTokens.Width.settingsWindowHeight
    )
    .onAppear {
      router.openSettingsAction = openSettings
      router.openWindowAction = openWindow
    }
  }

  @ViewBuilder
  private func pane(for tab: SettingsTab) -> some View {
    switch tab {
    case .general:
      GeneralSettingsPane(vm: vm)
    case .transcription:
      TranscriptionSettingsPane(vm: vm)
    case .models:
      ModelsSettingsPane(vm: vm)
    case .audio:
      AudioSettingsPane(vm: vm)
    case .meetings:
      MeetingSettingsPane(
        coordinator: vm.meetingCoordinator,
        favoriteModels: vm.favoriteOpenRouterModels
      )
    case .shortcuts:
      ShortcutsSettingsPane(vm: vm)
    case .integrations:
      IntegrationsSettingsPane(vm: vm, router: router)
    case .permissions:
      PermissionsView()
    }
  }

  /// The last save/validation message from the view model (key saved, invalid key, etc.).
  @ViewBuilder
  private var noticeBar: some View {
    if let notice = vm.settingsNotice {
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        StatusBadge(SettingsNotice.kind(for: notice), notice)
          .textSelection(.enabled)
          .lineLimit(2)
        Spacer(minLength: DesignTokens.Spacing.xSmall)
        Button {
          vm.settingsNotice = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss message")
      }
      .padding(.horizontal, DesignTokens.Spacing.medium)
      .padding(.vertical, DesignTokens.Spacing.xSmall)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
  }
}
