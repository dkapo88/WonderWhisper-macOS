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
    @State private var notchIndicator: NotchIndicatorController? = nil
    @State private var waveformOverlay: WaveformOverlayController? = nil
    @State private var streamingTranscriptOverlay: StreamingTranscriptOverlay? = nil
    @State private var hermesResponseWindow: HermesResponseWindowController? = nil
    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear {
                    if menuBar == nil { menuBar = MenuBarController(viewModel: vm) }
                    // Prefer a waveform overlay for clear visibility
                    if waveformOverlay == nil { waveformOverlay = WaveformOverlayController(viewModel: vm) }
                    // Streaming transcript overlay for Soniox
                    if streamingTranscriptOverlay == nil { streamingTranscriptOverlay = StreamingTranscriptOverlay(viewModel: vm) }
                    if hermesResponseWindow == nil { hermesResponseWindow = HermesResponseWindowController(viewModel: vm) }
                    // Keep the notch indicator optional; comment out if undesired
                    // if notchIndicator == nil { notchIndicator = NotchIndicatorController(viewModel: vm, side: .right) }
                }
                .onReceive(vm.$isRecording.combineLatest(vm.$simpleVoiceEngine)) { (isRecording, engine) in
                    // Show streaming transcript overlay for Soniox, waveform for others
                    if engine.showsLiveTranscript {
                        if isRecording {
                            streamingTranscriptOverlay?.show()
                        } else {
                            streamingTranscriptOverlay?.hide()
                        }
                    }
                }
                .onReceive(vm.$sonioxPreviewText) { text in
                    // Update streaming transcript overlay with live preview
                    streamingTranscriptOverlay?.updateText(text)
                }
        }
    }
}
