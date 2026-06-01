//
//  ContentView.swift
//  HermesWhisper
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: DictationViewModel
    private let simpleItems = SimpleSidebarItem.displayOrder

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SimpleSidebarItem?>(
                get: { vm.simpleSidebarSelection },
                set: { newValue in
                    guard let newValue else { return }
                    vm.simpleSidebarSelection = newValue
                }
            )) {
                ForEach(simpleItems, id: \.self) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("HermesWhisper")
        } detail: {
            switch vm.simpleSidebarSelection {
            case .dictation:
                SimplePromptEditorView(vm: vm, kind: .dictation)
                    .navigationTitle("Dictation")
            case .command:
                SimplePromptEditorView(vm: vm, kind: .command)
                    .navigationTitle("Command")
            case .hermes:
                HermesAgentView(vm: vm)
                    .navigationTitle("Hermes")
            case .beeper:
                BeeperIntegrationView(vm: vm)
                    .navigationTitle("Beeper")
            case .vocabulary:
                VocabularyView(vm: vm)
                    .navigationTitle("Vocabulary")
            case .history:
                SimpleHistoryView(vm: vm)
                    .navigationTitle("History")
            case .comparison:
                ModelComparisonView(vm: vm)
                    .navigationTitle("Compare")
            case .microphone:
                MicrophoneSelectionView(vm: vm)
                    .navigationTitle("Microphone")
            case .permissions:
                PermissionsView()
                    .navigationTitle("Permissions")
            case .settings:
                SimpleModeSettingsView(vm: vm)
                    .navigationTitle("Settings")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}

#Preview {
    ContentView(vm: DictationViewModel())
}
