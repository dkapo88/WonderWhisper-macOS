# Hotkey State Changes - Complete Code Snippets

## 1. Hotkey Manager - Initial Detection

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/HotkeyManager.swift`

```swift
private func handleHotkeyDown() {
    hotkeyPressStart = Date()
    activateCalledOnThisPress = false
    onActivate?() // Start recording immediately or toggle if already recording
    activateCalledOnThisPress = true
}

private func handleHotkeyUp() {
    guard let start = hotkeyPressStart else { return }
    hotkeyPressStart = nil
    let duration = Date().timeIntervalSince(start)
    // Prevent double-invocation: only toggle on release if we haven't already called onActivate on this press
    if duration >= briefPressThreshold && !activateCalledOnThisPress {
        // Held long enough: push-to-talk ends on release
        onActivate?()
    } else if duration >= briefPressThreshold && activateCalledOnThisPress {
        // Short hold: was already triggered on down, don't duplicate
    } else {
        // Short tap: hands-free mode (stay recording); next press will toggle stop
    }
    activateCalledOnThisPress = false
}
```

## 2. DictationViewModel - Hotkey Callback Setup

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationViewModel.swift` (line 353)

```swift
// In init():
hotkeys.onActivate = { [weak self] in self?.toggle() }
hotkeys.onPaste = { [weak self] in self?.pasteLastTranscription() }
```

## 3. DictationViewModel - isRecording Property (With didSet)

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationViewModel.swift` (lines 26-36)

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

**KEY POINTS:**
- `@Published` means any observer gets notified when this changes
- `didSet` block runs **immediately** when the value changes
- Both actions happen **on MainActor** context
- This triggers SwiftUI view invalidation automatically

## 4. DictationViewModel - The toggle() Function

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationViewModel.swift` (lines 430-470)

```swift
func toggle() {
    Task {
        let currentState = await controller.currentState()

        switch currentState {
        case .idle, .error:
            // Update UI IMMEDIATELY for instant feedback
            await MainActor.run {
                self.isRecording = true                    // ← TRIGGERS didSet
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
            await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)
            await MainActor.run { self.recordingStartInProgress = false }

        case .recording:
            await MainActor.run {
                self.isRecording = false
                self.recordingStartTimestamp = nil
                self.recordingStartInProgress = false
            }
            await MainActor.run { self.persistPromptLibrary() }
            let prompt = await MainActor.run { self.userPrompt }
            let activePrompt = await MainActor.run { self.prompts.first(where: { $0.id == self.selectedPromptID }) }
            await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)

        default:
            break
        }
    }
}
```

**EXECUTION FLOW:**
1. Called from hotkey callback
2. Wrapped in `Task {}` (background async)
3. First `MainActor.run { self.isRecording = true }` → **INSTANT UI REFRESH**
4. Then slower operations (providers, context capture)
5. Finally calls controller to actually start recording

## 5. DictationController - Recording Start

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationController.swift` (lines 113-150)

```swift
func toggle(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
    self.currentPrompt = activePrompt
    switch state {
    case .idle, .error:
        do {
            AppLog.dictation.log("Recording start")

            // Always start file recording as backup for all providers
            recorder.captureProfile = .standard16k

            // Update state IMMEDIATELY after starting recording for instant UI feedback
            let url = try recorder.startRecording()
            state = .recording

            let recordingStart = Date()
            currentRecordingURL = url

            // If Parakeet is active, preload models in the background to hide cold-start latency
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

            // Pre-capture screen context early so it is ready once recording stops
            preCapturedScreenSnapshot = nil
            preCapturedScreenText = nil
            preCapturedScreenMethod = nil
            preCapturedSelectedText = nil
            clipboardSnapshotForSession = nil

            if llmEnabled && screenContextEnabled {
                Task { await self.preCaptureScreenContext() }
            }
            if clipboardContextEnabled {
                await clipboardMonitor.refreshSnapshot()
                clipboardSnapshotForSession = await clipboardMonitor.consumeClipboardIfRecent(referenceDate: recordingStart, window: clipboardWindowSeconds)
            }
        } catch {
            AppLog.dictation.error("Recording start failed: \(error.localizedDescription)")
            state = .error("Recording start failed: \(error.localizedDescription)")
        }
    case .recording:
        await stopAndProcess(userPrompt: userPrompt)
    default:
        break
    }
}
```

**KEY POINTS:**
- `state = .recording` is set on the actor (DictationController)
- This state change is **polled** by the timer, not observed directly
- Controller state changes are reflected back to ViewModel via polling

## 6. DictationViewModel - State Polling Timer

**File:** `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationViewModel.swift` (lines 369-410)

```swift
// In init():
timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
    guard let self = self else { return }
    // Throttle polling when idle to reduce wakeups
    let isActive = self.isRecording || self.status == "Transcribing" || self.status == "Processing" || self.status == "Inserting"
    if !isActive {
        idleSkipCounter = (idleSkipCounter + 1) % 2 // ~2.5 Hz when idle
        if idleSkipCounter != 0 { return }
    } else {
        idleSkipCounter = 0
    }
    Task { [weak self] in
        guard let self = self else { return }
        let s = await self.controllerState()
        await MainActor.run {
            if self.status != s { self.status = s }
            let rec = (s == "Recording")

            // Prevent race condition: Don't reset isRecording to false while startup is still in progress
            if !rec && self.isRecording {
                if self.recordingStartInProgress {
                    return
                }
                if let startTime = self.recordingStartTimestamp,
                   Date().timeIntervalSince(startTime) < 1.5 {
                    // Within grace period after optimistic start - don't reset yet
                    return
                }
            }

            if self.isRecording != rec {
                self.isRecording = rec
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

**TIMING:**
- Fires every **200ms**
- Runs on background thread (Task wrapper)
- Updates `status` and `isRecording` on MainActor
- Includes grace period logic to prevent race conditions

## State Change Summary Table

| Property | Initial | After Hotkey | When | Context |
|----------|---------|--------------|------|---------|
| `isRecording` | `false` | `true` | Immediate | MainActor, triggers view refresh |
| `recordingStartTimestamp` | `nil` | `Date()` | Immediate | MainActor, used for grace period |
| `recordingStartInProgress` | `false` | `true` | Immediate | MainActor, prevents race conditions |
| `status` | "Idle" | "Recording" | ~0-200ms | MainActor via timer poll |
| Controller `.state` | `.idle` | `.recording` | Immediate (actor) | Not directly observed, polled |

## View Refresh Cascade

```
Hotkey Press (physical input event)
    ↓
HotkeyManager.handleHotkeyDown()
    ↓
onActivate callback fires
    ↓
DictationViewModel.toggle() [Task launched]
    ↓
[MAIN ACTOR CONTEXT]
isRecording = true
    ↓
@Published didSet triggers
    ↓
SwiftUI invalidates all views observing isRecording
    ↓
Views dependent on @ObservedObject vm redraw
    ↓
[BACKGROUND: Controller starts recording]
    ↓
[~200ms later: Timer fires]
    ↓
[MAIN ACTOR CONTEXT]
status = "Recording"
    ↓
SwiftUI invalidates status-dependent views
    ↓
Additional view refresh
```

## Critical Observation

The **first and most important state change** that causes view refresh is:

```swift
await MainActor.run {
    self.isRecording = true  // ← THIS LINE TRIGGERS VIEW INVALIDATION
}
```

This happens **immediately** (within microseconds) after the hotkey is detected, before any actual recording happens. The view refresh happens on the MainActor, making it a priority update in SwiftUI's rendering pipeline.
