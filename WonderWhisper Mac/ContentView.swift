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
    case fileTranscription
    case settingsGeneral
    case settingsModels
    case settingsPrompts
    case settingsVocabulary
    case settingsAPIKeys

    var id: String {
        switch self {
        case .home: return "home"
        case .history: return "history"
        case .fileTranscription: return "fileTranscription"
        case .settingsGeneral: return "settings.general"
        case .settingsModels: return "settings.models"
        case .settingsPrompts: return "settings.prompts"
        case .settingsVocabulary: return "settings.vocabulary"
        case .settingsAPIKeys: return "settings.apiKeys"
        }
    }

    var title: String {
        switch self {
        case .home: return "Scratchpad"
        case .history: return "History"
        case .fileTranscription: return "File Transcription"
        case .settingsGeneral: return "General"
        case .settingsModels: return "Models"
        case .settingsPrompts: return "Prompts"
        case .settingsVocabulary: return "Vocabulary"
        case .settingsAPIKeys: return "API Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "mic"
        case .history: return "clock"
        case .fileTranscription: return "waveform.badge.magnifyingglass"
        case .settingsGeneral: return "gear"
        case .settingsModels: return "brain.head.profile"
        case .settingsPrompts: return "text.justify.left"
        case .settingsVocabulary: return "textformat.abc"
        case .settingsAPIKeys: return "key"
        }
    }
}

struct ContentView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var proSelection: SidebarItem? = .home

    private let simpleItems: [SimpleSidebarItem] = [.scratchpad, .dictation, .assistant, .settings]

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $vm.interfaceMode) {
                    ForEach(InterfaceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)

                if vm.interfaceMode == .simple {
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
                } else {
                    List(selection: $proSelection) {
                        Section("WonderWhisper") {
                            ForEach([SidebarItem.home, SidebarItem.history, SidebarItem.fileTranscription], id: \.self) { item in
                                Label(item.title, systemImage: item.systemImage)
                                    .tag(item)
                            }
                        }
                        Section("Settings") {
                            ForEach([SidebarItem.settingsGeneral, SidebarItem.settingsModels, SidebarItem.settingsPrompts, SidebarItem.settingsVocabulary, SidebarItem.settingsAPIKeys], id: \.self) { item in
                                Label(item.title, systemImage: item.systemImage)
                                    .tag(item)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .padding(.top, 12)
            .navigationTitle("WonderWhisper")
        } detail: {
            if vm.interfaceMode == .simple {
                switch vm.simpleSidebarSelection {
                case .scratchpad:
                    SimpleScratchpadView(vm: vm)
                        .navigationTitle("Scratchpad")
                case .dictation:
                    SimplePromptEditorView(vm: vm, kind: .dictation)
                        .navigationTitle("Dictation")
                case .assistant:
                    SimplePromptEditorView(vm: vm, kind: .assistant)
                        .navigationTitle("Assistant")
                case .settings:
                    SimpleModeSettingsView(vm: vm)
                        .navigationTitle("Simple Settings")
                }
            } else {
                switch proSelection ?? .home {
                case .home:
                    ScratchpadView(vm: vm, openPromptSettings: { proSelection = .settingsPrompts })
                        .navigationTitle("Scratchpad")
                case .history:
                    HistoryView(vm: vm)
                        .environmentObject(vm.history)
                        .navigationTitle("History")
                case .fileTranscription:
                    FileTranscriptionView(dictationVM: vm)
                        .navigationTitle("File Transcription")
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
                case .settingsAPIKeys:
                    SettingsAPIKeysView(vm: vm)
                        .navigationTitle("Settings · API Keys")
                }
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { if proSelection == nil { proSelection = .home } }
        .onReceive(NotificationCenter.default.publisher(for: .openAPIKeysSettings)) { _ in
            proSelection = .settingsAPIKeys
        }
    }
}
#Preview {
    ContentView(vm: DictationViewModel())
}
