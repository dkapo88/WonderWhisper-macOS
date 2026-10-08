//
//  ContentView.swift
//  WonderWhisper
//
//  Created by Dane Kapoor on 4/9/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
  @ObservedObject var vm: DictationViewModel
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @State private var missingPermissions: [String] = []

  var body: some View {
    NavigationSplitView {
      MainSidebarList(selection: selectionBinding)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          settingsButton
        }
    } detail: {
      VStack(spacing: 0) {
        if !missingPermissions.isEmpty {
          PermissionsBanner(missing: missingPermissions) {
            SettingsRouter.shared.show(.permissions)
          }
        }
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle(vm.simpleSidebarSelection.title)
      .navigationSubtitle(vm.simpleSidebarSelection.subtitle)
    }
    .frame(minWidth: 780, minHeight: 500)
    .onAppear {
      SettingsRouter.shared.openSettingsAction = openSettings
      SettingsRouter.shared.openWindowAction = openWindow
      refreshPermissions()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refreshPermissions()
    }
  }

  private var selectionBinding: Binding<SimpleSidebarItem?> {
    Binding(
      get: { vm.simpleSidebarSelection },
      set: { newValue in
        guard let newValue else { return }
        vm.simpleSidebarSelection = newValue
      }
    )
  }

  private var settingsButton: some View {
    Button {
      SettingsRouter.shared.openSettingsWindow()
    } label: {
      Label("Settings", systemImage: "gearshape")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, DesignTokens.Spacing.medium)
    .padding(.vertical, DesignTokens.Spacing.small)
    .help("Open Settings (⌘,)")
  }

  @ViewBuilder
  private var detail: some View {
    switch vm.simpleSidebarSelection {
    case .dictation:
      SimplePromptEditorView(vm: vm, kind: .dictation)
    case .command:
      SimplePromptEditorView(vm: vm, kind: .command)
    case .hermes:
      HermesAgentView(vm: vm)
    case .meetings:
      MeetingView(coordinator: vm.meetingCoordinator)
    case .vocabulary:
      VocabularyView(vm: vm)
    case .history:
      SimpleHistoryView(vm: vm)
    case .comparison:
      ModelComparisonView(vm: vm)
    }
  }

  private func refreshPermissions() {
    missingPermissions = PermissionsView.missingPermissionTitles()
  }
}

/// The grouped sidebar of work surfaces (Library, Modes, Agents, Tools).
struct MainSidebarList: View {
  @Binding var selection: SimpleSidebarItem?

  var body: some View {
    List(selection: $selection) {
      ForEach(SimpleSidebarItem.Group.allCases) { group in
        Section(group.title) {
          ForEach(group.items) { item in
            Label(item.title, systemImage: item.systemImage)
              .tag(item)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

#Preview {
  ContentView(vm: DictationViewModel())
}
