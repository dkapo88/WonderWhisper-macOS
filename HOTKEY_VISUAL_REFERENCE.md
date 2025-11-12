# Hotkey Flow - Visual Reference Guide

## Timeline Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│ USER PRESSES HOTKEY                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                     (nanoseconds)
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ HotkeyManager.handleHotkeyDown()                                    │
│ └─ Detects key press event                                          │
│ └─ Sets hotkeyPressStart = Date()                                  │
│ └─ Calls onActivate?()                                             │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                     (microseconds)
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ DictationViewModel.toggle() [Task launched]                         │
│ └─ Switches on controller.currentState()                           │
│ └─ Case .idle                                                       │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                   (milliseconds - CRITICAL)
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ await MainActor.run {                                               │
│     self.isRecording = true          ← @Published property changes  │
│     self.recordingStartTimestamp = Date()                           │
│     self.recordingStartInProgress = true                            │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                   ⚡ MAGIC HAPPENS HERE ⚡
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ SwiftUI View Invalidation Cascade                                   │
│                                                                      │
│ 1. isRecording changed: false → true (on MainActor)                 │
│ 2. @Published notification sent                                      │
│ 3. All @ObservedObject vm views invalidated                         │
│ 4. SwiftUI re-renders entire view tree                              │
│ 5. didSet handler called:                                           │
│    ├─ updateEscapeMonitor()                                         │
│    ├─ SoundFeedback.playStart()                                     │
│ 6. View layout recalculated with isRecording=true                   │
│ 7. Modal content that was hidden is now visible                     │
│ 8. Modal size expands to accommodate content                        │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                   (milliseconds - faster operations)
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ await MainActor.run { self.persistPromptLibrary() }                 │
│ await MainActor.run { self.updateProvidersImmediately() }           │
│ await waitForLatestProviderUpdate()                                 │
│ await checkAndStoreSelectedTextPromptFast()                         │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                (milliseconds to seconds - slower)
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ await controller.toggle()                                            │
│ └─ recorder.startRecording()                                        │
│ └─ state = .recording (on DictationController actor)                │
│ └─ groq.beginRealtime() or parakeet warmUp()                        │
│ └─ preCaptureScreenContext()                                        │
│ └─ Setup complete                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
                   RECORDING NOW ACTIVE
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Timer fires (every ~200ms)                                          │
│ └─ Polls controller.currentState()                                  │
│ └─ Syncs status property if needed                                  │
│ └─ May trigger additional view refresh                              │
└─────────────────────────────────────────────────────────────────────┘
```

## State Property Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DictationViewModel                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  @Published Properties (affect view refresh):                       │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ isRecording: false                                             │ │
│  │ └─ Changed by: toggle() and timer                             │ │
│  │ └─ Triggers: Immediate view refresh                           │ │
│  │ └─ Used in: SoundFeedback, escape monitor, modal sizing       │ │
│  │                                                                │ │
│  │ status: "Idle"                                                │ │
│  │ └─ Changed by: timer poll (every ~200ms)                      │ │
│  │ └─ Triggers: View refresh if changed                          │ │
│  │ └─ Used in: Status display UI                                 │ │
│  │                                                                │ │
│  │ audioLevel: 0.0                                               │ │
│  │ └─ Changed by: Audio monitoring                               │ │
│  │ └─ Triggers: Waveform display refresh                         │ │
│  │                                                                │ │
│  │ [Other @Published properties...]                              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  Private State (used internally):                                   │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ recordingStartTimestamp: Date? = nil                           │ │
│  │ └─ Set to: Date() when recording starts                        │ │
│  │ └─ Purpose: Grace period for race condition prevention         │ │
│  │                                                                │ │
│  │ recordingStartInProgress: Bool = false                        │ │
│  │ └─ Set to: true when starting, false when done               │ │
│  │ └─ Purpose: Prevent multiple simultaneous starts              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  Observers:                                                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Any view with: @ObservedObject var vm: DictationViewModel     │ │
│  │ Will be invalidated and redrawn when @Published properties     │ │
│  │ change.                                                         │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Interaction Diagram

```
┌──────────────────────┐
│   Physical Input     │
│  (Hotkey Press)      │
└──────────────┬───────┘
               │
               ↓
┌──────────────────────────────────────┐
│      HotkeyManager                   │
│  ┌────────────────────────────────┐  │
│  │ handleHotkeyDown()             │  │
│  │ └─ onActivate?()  ──────────┐  │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
               │
               ↓
┌──────────────────────────────────────┐
│  DictationViewModel                  │
│  ┌────────────────────────────────┐  │
│  │ toggle()                       │  │
│  │ ├─ MainActor.run {             │  │
│  │ │   isRecording = true  ────┐  │  │
│  │ │ }                          │  │  │
│  │ └─ controller.toggle()       │  │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
               │                │
               │                └──────────────────┐
               ↓                                   ↓
    ┌──────────────────────┐        ┌──────────────────────┐
    │  SwiftUI View Tree   │        │ DictationController  │
    │                      │        │                      │
    │ @ObservedObject vm   │        │ actor State:         │
    │ └─ Invalidated       │        │ .idle → .recording   │
    │ └─ Redrawn           │        │                      │
    │ └─ Modal expands     │        │ Actual recording     │
    │                      │        │ setup happens        │
    └──────────────────────┘        └──────────────────────┘
```

## isRecording Lifecycle

```
┌────────────────────────────────────────────────────────────────────┐
│                   isRecording Property                             │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Declaration:                                                     │
│  @Published var isRecording: Bool = false {                       │
│      didSet {                                                      │
│          updateEscapeMonitor(isRecording: isRecording)            │
│          if isRecording {                                         │
│              SoundFeedback.playStart()                            │
│          } else if oldValue {                                     │
│              SoundFeedback.playStop()                             │
│          }                                                         │
│      }                                                             │
│  }                                                                 │
│                                                                    │
│  State Transitions:                                               │
│                                                                    │
│  false (idle)                                                     │
│    │                                                              │
│    │ toggle() on idle                                            │
│    ↓                                                              │
│  true (recording)                                                │
│    │                                                              │
│    │ toggle() on recording                                       │
│    ↓                                                              │
│  false (stopped)                                                 │
│                                                                   │
│  Side Effects on Change:                                         │
│  ├─ updateEscapeMonitor(true/false)  [keyboard monitoring]       │
│  ├─ SoundFeedback.playStart()         [audio feedback]           │
│  ├─ SoundFeedback.playStop()          [audio feedback]           │
│  ├─ View invalidation                 [@Published notification]  │
│  └─ View refresh                      [SwiftUI rerender]         │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## View Refresh Cascade

```
isRecording changes from false to true
            ↓
@Published notification sent
            ↓
ObservableObject sends willChange notification
            ↓
All @ObservedObject observers notified
            ↓
SwiftUI marks views as invalid
            ↓
┌─────────────────────────────────────────────────────────────┐
│ Redraw Phase:                                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. ContentView redraws                                      │
│    └─ Passes updated vm to child views                      │
│                                                             │
│ 2. SimplePromptEditorView redraws                           │
│    └─ Can now access vm.isRecording = true                  │
│    └─ Conditional content now visible                       │
│                                                             │
│ 3. Modal/Sheet redraws                                      │
│    └─ If modal depends on isRecording, now works correctly  │
│    └─ Layout recalculated with new state                    │
│                                                             │
│ 4. Size calculated                                          │
│    └─ Previously: minimal size (empty box)                  │
│    └─ Now: proper size with content                         │
│                                                             │
│ 5. Rendering                                                │
│    └─ Modal appears expanded                                │
│    └─ Content is visible                                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## The Modal Problem Illustrated

```
BEFORE HOTKEY PRESS (isRecording = false):
┌─────────────────────────┐
│ Modal                   │
├─────────────────────────┤
│ Empty/Tiny              │ ← Content hidden or size = 10pt
│                         │
│                         │
└─────────────────────────┘
Size: 50×50 (minimal)

                    [USER PRESSES HOTKEY]
                    isRecording = true
                    View invalidated
                    [REDRAW]

AFTER HOTKEY PRESS (isRecording = true):
┌──────────────────────────────────────────┐
│ Modal                                    │
├──────────────────────────────────────────┤
│ Content visible now                      │
│                                          │
│ Prompt header text...                    │
│ Prompt rules...                          │
│ Context settings...                      │
│                                          │
│ [All content now visible]                │
│                                          │
│                                          │
│                                          │
└──────────────────────────────────────────┘
Size: 600×400 (proper)
```

## Code Execution Order

```
┌─ HOTKEY PRESS
│
├─ HotkeyManager.handleHotkeyDown()
│  └─ Sets hotkeyPressStart
│  └─ Calls onActivate?()
│
├─ DictationViewModel.toggle()
│  │
│  ├─ Task { [background thread]
│  │  │
│  │  ├─ let currentState = await controller.currentState()
│  │  │
│  │  ├─ case .idle, .error:
│  │  │  │
│  │  │  ├─ ⚡ MAIN THREAD JUMP
│  │  │  ├─ await MainActor.run {
│  │  │  │   self.isRecording = true         ← VIEW REFRESH #1
│  │  │  │   self.recordingStartTimestamp = Date()
│  │  │  │   self.recordingStartInProgress = true
│  │  │  │ }
│  │  │  │
│  │  │  ├─ await MainActor.run { 
│  │  │  │   self.persistPromptLibrary()
│  │  │  │ }
│  │  │  │
│  │  │  ├─ await MainActor.run {
│  │  │  │   self.updateProvidersImmediately()
│  │  │  │ }
│  │  │  │
│  │  │  ├─ await waitForLatestProviderUpdate()
│  │  │  │
│  │  │  ├─ await checkAndStoreSelectedTextPromptFast()
│  │  │  │
│  │  │  ├─ let prompt = await MainActor.run { ... }
│  │  │  │
│  │  │  ├─ [BACKGROUND] Start actual recording
│  │  │  └─ await controller.toggle(userPrompt: prompt)
│  │  │
│  │  └─ }
│  │  }
│  │
│  └─ [TIMER FIRES EVERY ~200ms]
│     ├─ Polls controller.currentState()
│     └─ Updates status = "Recording"  ← VIEW REFRESH #2
│
└─ RECORDING NOW ACTIVE
```

## Summary Table

| Stage | Component | Action | Effect | Timing |
|-------|-----------|--------|--------|--------|
| 1 | HotkeyManager | Detect key press | - | ns |
| 2 | HotkeyManager | Call onActivate() | - | μs |
| 3 | DictationViewModel | toggle() called | - | μs |
| 4 | DictationViewModel | isRecording = true | **View refresh** | ms |
| 5 | SwiftUI | View invalidation | **Modal expands** | ms |
| 6 | DictationViewModel | updateProvidersImmediately() | - | ms |
| 7 | DictationController | recorder.startRecording() | Recording starts | ms-s |
| 8 | Timer | Poll state every 200ms | Update status | 200ms+ |

The key insight: **Stage 4 (view refresh) happens before Stage 7 (recording starts)**.
