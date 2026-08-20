//
//  WonderWhisperApp.swift
//  WonderWhisper
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI
import AppKit
import Combine

@main
struct WonderWhisperApp: App {
    init() {
        QwenTranscribeHelper.runIfRequested()
        QwenSelfTest.runIfRequested()
    }

    @StateObject private var vm = DictationViewModel()
    @State private var menuBar: MenuBarController? = nil
    @State private var waveformOverlay: WaveformOverlayController? = nil
    @State private var streamingTranscriptOverlay: StreamingTranscriptOverlay? = nil
    @State private var hermesResponseWindow: HermesResponseWindowController? = nil
    @State private var meetingOverlay: MeetingOverlayWindowController? = nil
    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear {
                    if menuBar == nil { menuBar = MenuBarController(viewModel: vm) }
                    // Prefer a waveform overlay for clear visibility
                    if waveformOverlay == nil { waveformOverlay = WaveformOverlayController(viewModel: vm) }
                    // Live transcript overlay for Soniox/xAI streaming. It self-subscribes to the
                    // view model (show/hide/updateText), so it keeps working even when this window
                    // is closed — unlike the old .onReceive wiring which died with the view.
                    if streamingTranscriptOverlay == nil { streamingTranscriptOverlay = StreamingTranscriptOverlay(viewModel: vm) }
                    if hermesResponseWindow == nil { hermesResponseWindow = HermesResponseWindowController(viewModel: vm) }
                    if meetingOverlay == nil { meetingOverlay = MeetingOverlayWindowController(coordinator: vm.meetingCoordinator) }
                    // Touch the shared updater so Sparkle starts its scheduled check timer.
                    // Without this the updater is only created when the menu is first built.
                    _ = UpdaterController.shared
                }
        }
        .commands {
            // Mac convention puts "Check for Updates…" in the app menu, directly under
            // "About". CommandGroup(after: .appInfo) is the only placement AppKit exposes
            // for that slot.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem()
            }
        }
    }
}

/// "Check for Updates…" for the app menu. Kept as its own view so it can observe the updater
/// and disable itself while a check is already running.
private struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
