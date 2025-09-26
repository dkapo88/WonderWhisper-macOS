//
//  ContentView.swift
//  WonderWhisper Mac
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI

private enum SidebarItem: Hashable, Identifiable {
    case home
    case history
    case settingsGeneral
    case settingsModels
    case settingsPrompts
    case settingsVocabulary
    case settingsShortcuts
    case settingsAPIKeys

    var id: String {
        switch self {
        case .home: return "home"
        case .history: return "history"
        case .settingsGeneral: return "settings.general"
        case .settingsModels: return "settings.models"
        case .settingsPrompts: return "settings.prompts"
        case .settingsVocabulary: return "settings.vocabulary"
        case .settingsShortcuts: return "settings.shortcuts"
        case .settingsAPIKeys: return "settings.apiKeys"
        }
    }

    var title: String {
        switch self {
        case .home: return "Scratchpad"
        case .history: return "History"
        case .settingsGeneral: return "General"
        case .settingsModels: return "Models"
        case .settingsPrompts: return "Prompts"
        case .settingsVocabulary: return "Vocabulary"
        case .settingsShortcuts: return "Shortcuts"
        case .settingsAPIKeys: return "API Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "mic"
        case .history: return "clock"
        case .settingsGeneral: return "gear"
        case .settingsModels: return "brain.head.profile"
        case .settingsPrompts: return "text.justify.left"
        case .settingsVocabulary: return "textformat.abc"
        case .settingsShortcuts: return "keyboard"
        case .settingsAPIKeys: return "key"
        }
    }
}

struct ContentView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var selection: SidebarItem? = .home

    private let items: [SidebarItem] = [
        .home, .history, .settingsGeneral, .settingsModels, .settingsPrompts, .settingsVocabulary, .settingsShortcuts, .settingsAPIKeys
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("WonderWhisper") {
                    ForEach([SidebarItem.home, SidebarItem.history], id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
                Section("Settings") {
                    ForEach([SidebarItem.settingsGeneral, SidebarItem.settingsModels, SidebarItem.settingsPrompts, SidebarItem.settingsVocabulary, SidebarItem.settingsShortcuts, SidebarItem.settingsAPIKeys], id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("WonderWhisper")
        } detail: {
            switch selection ?? .home {
            case .home:
                ScratchpadView(vm: vm, openPromptSettings: { selection = .settingsPrompts })
                    .navigationTitle("Scratchpad")
            case .history:
                HistoryView(vm: vm)
                    .environmentObject(vm.history)
                    .navigationTitle("History")
            case .settingsGeneral:
                SettingsGeneralView(vm: vm)
                    .navigationTitle("Settings · General")
            case .settingsModels:
                SettingsModelsView(vm: vm)
                    .navigationTitle("Settings · Models")
            case .settingsPrompts:
                SettingsPromptsView(vm: vm)
                    .navigationTitle("Settings · Prompts")
            case .settingsVocabulary:
                SettingsVocabularyView(vm: vm)
                    .navigationTitle("Settings · Vocabulary")
            case .settingsShortcuts:
                SettingsShortcutsView(vm: vm)
                    .navigationTitle("Settings · Shortcuts")
            case .settingsAPIKeys:
                SettingsAPIKeysView(vm: vm)
                    .navigationTitle("Settings · API Keys")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { if selection == nil { selection = .home } }
        .onReceive(NotificationCenter.default.publisher(for: .openAPIKeysSettings)) { _ in
            selection = .settingsAPIKeys
        }
    }
}
#Preview {
    ContentView(vm: DictationViewModel())
}
