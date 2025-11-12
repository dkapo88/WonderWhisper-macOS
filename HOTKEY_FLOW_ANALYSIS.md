# Hotkey to Recording Start: Complete Flow Analysis

## Problem Statement
When the user opens a prompt debug modal, it appears as an empty tiny box until they press the hotkey to start dictation. Then the modal suddenly expands and shows all content properly. This suggests that pressing the hotkey triggers a view redraw/layout recalculation.

## Complete Call Chain

### 1. Hotkey Press Detection
**File:** `HotkeyManager.swift` (lines 260-280)

```swift
private func handleHotkeyDown() {
    hotkeyPressStart = Date()
    activateCalledOnThisPress = false
    onActivate?() // Start recording immediately or toggle if already recording
    activateCalledOnThisPress = true
}
```

The hotkey manager detects the key press and calls `onActivate()`.

**Set up in:** `DictationViewModel.swift` (line 353)
```swift
hotkeys.onActivate = { [weak self] in self?.toggle() }
```

### 2. ViewModel Toggle Function
**File:** `DictationViewModel.swift` (lines 430-470)

```swift
func toggle() {
    Task {
        let currentState = await controller.currentState()

        switch currentState {
        case .idle, .error:
            // Update UI IMMEDIATELY for instant feedback
            await MainActor.run {
                self.isRecording = true                    // <-- KEY STATE CHANGE
                self.recordingStartTimestamp = Date()
                self.recordingStartInProgress = true
            }

            // Now perform slower operations after UI is updated
            await MainActor.run { self.persistPromptLibrary() }
            await MainActor.run { self.updateProvidersImmediately() }
            await waitForLatestProviderUpdate()

            // Fast check for selected text (AX only, ~5ms, no pasteboard fallback)
            await checkAndStoreSelectedTextPromptFast()

            let prompt = await MainActor.run { self.userPrompt }
            let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == self.selectedPromptID }) }

            // Pass to controller for actual recording start
            await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)
            await MainActor.run { self.recordingStartInProgress = false }

        case .recording:
            // Stop recording
            await MainActor.run {
                self.isRecording = false
                self.recordingStartTimestamp = nil
                self.recordingStartInProgress = false
            }
            // ... stop processing
        }
    }
}
```

**Critical State Changes on Recording Start:**
1. `isRecording` = `true` (MainActor update - triggers view refresh)
2. `recordingStartTimestamp` = current Date
3. `recordingStartInProgress` = `true`

### 3. isRecording Didset Handler
**File:** `DictationViewModel.swift` (lines 26-36)

```swift
@Published var isRecording: Bool = false {
    didSet {
        updateEscapeMonitor(isRecording: isRecording)
        // Play chime sounds for recording start/stop
        if isRecording {
            SoundFeedback.playStart()
        } else if oldValue {
            // Only play stop sound if we were previously recording
            SoundFeedback.playStop()
        }
    }
}
```

When `isRecording` changes, it:
- Updates the escape key monitor state
- Plays audio feedback
- **Triggers view invalidation** (because it's `@Published`)

### 4. Controller Toggle - Recording Start
**File:** `DictationController.swift` (lines 113-150)

```swift
func toggle(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
    self.currentPrompt = activePrompt
    switch state {
    case .idle, .error:
        do {
            AppLog.dictation.log("Recording start")

            // Start file recording
            recorder.captureProfile = .standard16k

            // Update state IMMEDIATELY after starting recording for instant UI feedback
            let url = try recorder.startRecording()
            state = .recording    // <-- Changes internal controller state

            let recordingStart = Date()
            currentRecordingURL = url

            // If Parakeet is active, preload models in the background
            if let pk = transcriber as? ParakeetTranscriptionProvider {
                Task { await pk.warmUp() }
            }

            if let groq = transcriber as? GroqStreamingProvider {
                groq.updateSettings(transcriberSettings)
                try await groq.beginRealtime()
                try? recorder.startStreamingPCM16 { data in
                    Task { try? await groq.feedPCM16(data) }
                }
            }

            // Pre-capture screen context early
            if llmEnabled && screenContextEnabled {
                Task { await self.preCaptureScreenContext() }
            }
            // ... more initialization
        } catch {
            state = .error(...)
        }
    }
}
```

The controller changes its internal `state` from `.idle` to `.recording`.

### 5. State Polling Timer
**File:** `DictationViewModel.swift` (lines 369-410)

This runs every 0.2 seconds (200ms):

```swift
timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
    guard let self = self else { return }

    // ... throttling logic ...

    Task { [weak self] in
        guard let self = self else { return }
        let s = await self.controllerState()
        await MainActor.run {
            if self.status != s { self.status = s }
            let rec = (s == "Recording")

            // Prevent race condition check
            if !rec && self.isRecording {
                if self.recordingStartInProgress {
                    return
                }
                if let startTime = self.recordingStartTimestamp,
                   Date().timeIntervalSince(startTime) < 1.5 {
                    // Within grace period - don't reset yet
                    return
                }
            }

            if self.isRecording != rec {
                self.isRecording = rec  // Updates if controller state changed
                if rec {
                    self.recordingStartInProgress = false
                } else {
                    self.recordingStartTimestamp = nil
                    self.recordingStartInProgress = false
                }
            }
        }
    }
}
```

This polls the controller's state and syncs it with `isRecording`, triggering additional view refreshes.

## View Refresh Triggers

When the hotkey is pressed, the following state changes trigger SwiftUI view invalidation:

### Primary Trigger: `isRecording` Property
- **Type:** `@Published var`
- **Change:** `false` → `true`
- **Immediate:** Yes (called directly on MainActor)
- **Effect:** Any view observing `@ObservedObject vm` will be invalidated and redrawn

### Secondary Trigger: `status` Property
- **Type:** `@Published var`
- **Change:** "Idle" → "Recording"
- **Immediate:** After ~200ms (from timer poll)
- **Effect:** Additional view refresh for status display

### Tertiary Trigger: Providers Updated
During `toggle()`, this is called:
```swift
await MainActor.run { self.updateProvidersImmediately() }
```

This may update provider-related `@Published` properties, causing additional view refreshes.

## Why This Causes Modal Expansion

When a modal/sheet is first presented but before any state changes:
1. SwiftUI calculates initial layout with minimal/empty data
2. Modal appears small/empty because no content is bound to active state
3. When `isRecording` becomes `true`, SwiftUI redraws the entire view tree
4. Views that depend on `isRecording` or other state now have proper values
5. Content that was hidden or not rendered becomes visible
6. Layout engine re-runs with actual content dimensions
7. Modal expands to accommodate real content

## Key Code Locations

| Component | File | Lines | Function |
|-----------|------|-------|----------|
| Hotkey detection | HotkeyManager.swift | 260-280 | `handleHotkeyDown()` |
| Hotkey callback setup | DictationViewModel.swift | 353 | `init()` |
| Toggle entry point | DictationViewModel.swift | 430-470 | `toggle()` |
| isRecording property | DictationViewModel.swift | 26-36 | `@Published isRecording` |
| State polling timer | DictationViewModel.swift | 369-410 | Timer setup in `init()` |
| Controller state sync | DictationController.swift | 113-150 | `toggle()` |

## Sequence Diagram

```
Hotkey Press
    ↓
HotkeyManager.handleHotkeyDown()
    ↓
DictationViewModel.toggle() [async Task on background thread]
    ↓
MainActor.run {
    isRecording = true  ← VIEW INVALIDATION #1
    recordingStartTimestamp = Date()
    recordingStartInProgress = true
}
    ↓
updateProvidersImmediately()  ← May trigger more @Published updates
    ↓
controller.toggle() [starts actual recording]
    ↓
[After ~200ms, Timer fires]
    ↓
MainActor.run {
    status = "Recording"  ← VIEW INVALIDATION #2
}
```

## Implications for the Modal Issue

The empty modal likely appears because:

1. **Modal is presented before `isRecording` is true**
2. Modal content depends on `isRecording` being true to display:
   - Recording status indicators
   - Prompt text that should be visible
   - Layout constraints that require a width/height
3. **Initial rendering** with `isRecording = false` calculates minimal size
4. **After hotkey press**, `isRecording` becomes true → view hierarchy invalidated
5. **Layout engine recalculates** with actual binding values
6. **Modal expands** to its proper size

## Solution Approaches

To fix the "empty tiny modal" issue, ensure that:

1. **Modal content doesn't depend on `isRecording`** unless necessary for display logic
2. **Use `.frame()` or `.defaultSize()`** in SwiftUI sheets to set initial dimensions
3. **Bind to non-isRecording properties** for modal size if possible
4. **Force layout calculation** by having the modal calculate size based on content before presentation, not during
5. **Separate state concerns** - don't bind modal visibility to recording state if not needed

See the related view files (SimplePromptEditorView, SimpleModeSettingsView, etc.) to identify which property the modal is keying off of for sizing.
