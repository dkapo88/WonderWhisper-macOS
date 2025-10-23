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

    private let simpleItems: [SimpleSidebarItem] = [.scratchpad, .dictation, .assistant, .history, .settings]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ModeToggle(mode: $vm.interfaceMode)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
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
                case .history:
                    SimpleHistoryView(vm: vm)
                        .navigationTitle("History")
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

private struct ModeToggle: View {
    @Binding var mode: InterfaceMode

    var body: some View {
        GeometryReader { geometry in
            let segmentWidth = geometry.size.width / 2
            ZStack(alignment: mode == .simple ? .leading : .trailing) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(mode == .simple ? Color.blue : Color.red)
                    .frame(width: segmentWidth - 8)
                    .padding(4)
                    .animation(.easeInOut(duration: 0.25), value: mode)

                HStack(spacing: 0) {
                    modeButton(for: .simple, width: segmentWidth)
                    modeButton(for: .pro, width: segmentWidth)
                }
            }
        }
        .frame(height: 46)
    }

    private func modeButton(for candidate: InterfaceMode, width: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                mode = candidate
            }
        } label: {
            Text(candidate.displayName)
                .font(.headline)
                .foregroundColor(mode == candidate ? .white : .primary)
                .frame(width: width, height: 46)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView(vm: DictationViewModel())
}
