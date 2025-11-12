# Hotkey Recording Start - Quick Reference Guide

## The Problem in One Sentence
When a prompt debug modal opens, it appears as an empty tiny box until the hotkey is pressed—then it suddenly expands and shows content properly, suggesting the hotkey press triggers a view refresh that fixes the layout.

## The Complete Flow (30 seconds)

```
User presses hotkey
    ↓
HotkeyManager detects key press
    ↓
Calls onActivate callback
    ↓
DictationViewModel.toggle() runs
    ↓
IMMEDIATELY: isRecording = true (on MainActor)
    ↓
SwiftUI sees @Published isRecording change
    ↓
All views observing vm are invalidated
    ↓
View tree redraws
    ↓
Modal content now visible and properly sized
    ↓
THEN: Actual recording starts in background
```

## Key State Changes When Hotkey Pressed

| State Property | Before | After | Timing | Thread |
|---|---|---|---|---|
| `isRecording` | `false` | `true` | Immediate | MainActor |
| `recordingStartTimestamp` | `nil` | `Date()` | Immediate | MainActor |
| `recordingStartInProgress` | `false` | `true` | Immediate | MainActor |
| `status` | "Idle" | "Recording" | ~200ms | MainActor (via timer) |
| Controller `.state` | `.idle` | `.recording` | Immediate | DictationController (actor) |

## Three Documents Created

### 1. HOTKEY_FLOW_ANALYSIS.md
Complete call chain from hotkey press to view refresh, with explanations of why the modal expansion happens.

**Key sections:**
- Complete call chain diagram
- Where each component lives in the code
- Sequence diagram of state changes
- Why the modal appears empty, then expands

### 2. HOTKEY_CODE_SNIPPETS.md
Actual code excerpts from the codebase showing exactly what happens at each step.

**Includes:**
- HotkeyManager.handleHotkeyDown()
- DictationViewModel.toggle()
- isRecording property with didSet
- DictationController.toggle()
- State polling timer
- All with line numbers and file paths

### 3. MODAL_EXPANSION_FIX.md
Root cause analysis and 5 different fix strategies for the empty modal problem.

**Covers:**
- Why the modal appears empty
- How hotkey press fixes it
- 5 fix strategies (remove dependency, explicit sizing, etc.)
- Implementation checklist
- Testing guide

## The Magic Line

This is the line that causes the view refresh:

**File:** `DictationViewModel.swift` line 439
```swift
await MainActor.run {
    self.isRecording = true  // ← THIS TRIGGERS VIEW INVALIDATION
}
```

Because `isRecording` is declared as:
```swift
@Published var isRecording: Bool = false { didSet { ... } }
```

When it changes, **all views observing `@ObservedObject vm` are invalidated and redrawn**.

## Why This Matters for Your Modal

If your prompt debug modal appears empty and tiny until the hotkey is pressed, it's likely because:

1. The modal content **is conditionally shown** based on `isRecording`
2. Or the modal size is **calculated differently** when `isRecording = true`
3. Or something in the modal's view hierarchy **depends on `isRecording`**

When the modal first opens, `isRecording = false`, so:
- Conditional content isn't shown
- Size is minimal
- Layout is incomplete

When the hotkey is pressed, `isRecording = true`, and SwiftUI redraws, revealing:
- Content that was hidden
- Proper calculated size
- Complete layout

## What Actually Starts Recording

The actual recording is started by this code:

**File:** `DictationController.swift` line 131
```swift
let url = try recorder.startRecording()
state = .recording
```

But this happens **AFTER** the view refresh, not before. So the view sees the state change first, then the actual recording begins.

## The Real Discovery

The interesting insight is that SwiftUI view invalidation happens **before** the actual work (recording) happens:

```
Hotkey press
    ↓
isRecording = true (IMMEDIATE) ← View refresh happens here
    ↓
updateProvidersImmediately() (fast)
    ↓
checkAndStoreSelectedTextPromptFast() (fast)
    ↓
controller.toggle() (slower, actual recording setup)
    ↓
Recording starts
```

This is **intentional design** for responsiveness - the UI updates immediately to show the user that something is happening, while the slow operations happen in the background.

## Implementation Locations

| Component | File | Lines |
|-----------|------|-------|
| **Hotkey detection** | HotkeyManager.swift | 260-290 |
| **Hotkey callback setup** | DictationViewModel.swift | 353 |
| **toggle() function** | DictationViewModel.swift | 430-470 |
| **isRecording property** | DictationViewModel.swift | 26-36 |
| **Recording start** | DictationController.swift | 113-150 |
| **State polling** | DictationViewModel.swift | 369-410 |

## Quick Debugging

To verify this is what's happening in your app:

```swift
// Add to DictationViewModel.swift
@Published var isRecording: Bool = false {
    didSet {
        print("🎙️ isRecording changed: \(oldValue) → \(isRecording)")
        if isRecording {
            print("   └─ This triggers view redraw!")
        }
        updateEscapeMonitor(isRecording: isRecording)
        if isRecording {
            SoundFeedback.playStart()
        } else if oldValue {
            SoundFeedback.playStop()
        }
    }
}
```

When you press the hotkey, you'll see in the console:
```
🎙️ isRecording changed: false → true
   └─ This triggers view redraw!
```

This confirms the view refresh is happening.

## Next Steps

1. **Identify your modal** - Find which view contains the prompt debug modal
2. **Check for isRecording dependencies** - Search for `vm.isRecording` in the modal view
3. **Apply appropriate fix** - Use one of the 5 strategies from MODAL_EXPANSION_FIX.md
4. **Test without hotkey** - Modal should appear full-sized before pressing hotkey
5. **Verify hotkey still works** - Ensure recording starts normally

All the detailed code and explanations are in the three analysis documents.
