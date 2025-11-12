//
//  ContentView.swift
//  WonderWhisper Mac
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: DictationViewModel
    private let simpleItems: [SimpleSidebarItem] = [.dictation, .command, .vocabulary, .history, .settings]

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
            .navigationTitle("WonderWhisper")
        } detail: {
            switch vm.simpleSidebarSelection {
            case .dictation:
                SimplePromptEditorView(vm: vm, kind: .dictation)
                    .navigationTitle("Dictation")
            case .command:
                SimplePromptEditorView(vm: vm, kind: .command)
                    .navigationTitle("Command")
            case .vocabulary:
                VocabularyView(vm: vm)
                    .navigationTitle("Vocabulary")
            case .history:
                SimpleHistoryView(vm: vm)
                    .navigationTitle("History")
            case .settings:
                SimpleModeSettingsView(vm: vm)
                    .navigationTitle("Settings")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .openAPIKeysSettings)) { _ in
            vm.simpleSidebarSelection = .settings
        }
    }
}

#Preview {
    ContentView(vm: DictationViewModel())
}
