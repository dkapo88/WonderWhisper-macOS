//
//  HermesWhisperApp.swift
//  HermesWhisper
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI
import AppKit
import Combine

@main
struct HermesWhisperApp: App {
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
                }
        }
    }
}
