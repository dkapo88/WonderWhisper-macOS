# Hotkey to Recording State Change - Complete Analysis Index

## Overview

This analysis documents what happens when a user presses the hotkey to start dictation recording, with a focus on understanding why a prompt debug modal appears as an empty tiny box until the hotkey is pressed.

**Key Finding:** The `isRecording` property becomes `true` when the hotkey is pressed, triggering an immediate SwiftUI view refresh that causes the modal to expand and display content properly.

## Documents in This Analysis

### 1. HOTKEY_SUMMARY.md (START HERE)
**Best for:** Quick understanding and overview
- 30-second explanation of the complete flow
- Key state changes table
- The magic line that triggers everything
- Why the modal appears empty
- Quick debugging tips

**Read this first** if you just want to understand the issue.

### 2. HOTKEY_FLOW_ANALYSIS.md
**Best for:** Understanding the call chain and architecture
- Complete call chain from hotkey to view refresh
- Detailed explanation of each step
- Problem statement and discovery
- View refresh triggers
- Sequence diagram
- Implications for the modal issue
- Solution approaches

**Read this** to understand the system design and how components connect.

### 3. HOTKEY_CODE_SNIPPETS.md
**Best for:** Developers who want to see actual code
- Complete code excerpts from the codebase
- Line numbers and file paths
- All major functions involved
- State change summary table
- View refresh cascade diagram
- Critical observation about MainActor updates

**Read this** when you need to see the actual implementation.

### 4. MODAL_EXPANSION_FIX.md
**Best for:** Fixing the empty modal issue
- Root cause analysis
- Where to look in the code
- Exact patterns to identify
- 5 fix strategies with code examples
- Implementation checklist
- Testing guide
- Debugging tips

**Read this** when you're ready to fix the modal expansion bug.

## Quick Navigation

**I want to...**

- **Understand what happens when the hotkey is pressed**
  → Read HOTKEY_SUMMARY.md (5 min) then HOTKEY_FLOW_ANALYSIS.md (15 min)

- **See the actual code**
  → Read HOTKEY_CODE_SNIPPETS.md (10 min)

- **Fix the empty modal problem**
  → Read MODAL_EXPANSION_FIX.md (20 min) and apply the fixes

- **Debug why my views aren't updating**
  → HOTKEY_CODE_SNIPPETS.md section "Critical Observation" + MODAL_EXPANSION_FIX.md section "Debugging Tips"

- **Understand state management in the app**
  → HOTKEY_FLOW_ANALYSIS.md sections on "State Change Triggers" and "State Polling Timer"

## The Core Insight

When the hotkey is pressed, this happens in this order:

```
1. HotkeyManager detects physical key press (nanoseconds)
2. Calls onActivate callback (microseconds)  
3. DictationViewModel.toggle() is called (microseconds)
4. MainActor.run { isRecording = true } (milliseconds)
   └─ @Published property changes
   └─ SwiftUI invalidates all observing views
   └─ View tree is redrawn (THE KEY MOMENT)
5. updateProvidersImmediately() (milliseconds)
6. controller.toggle() starts actual recording (milliseconds to seconds)
7. Timer polls and syncs state (~200ms later)
```

**The view refresh (step 4) happens BEFORE actual recording starts (step 6).**

This is intentional for responsiveness - the user sees immediate UI feedback while the slow operations happen in the background.

## Key Files Referenced

### Source Code Files

| File | Purpose | Key Sections |
|------|---------|--------------|
| `HotkeyManager.swift` | Detects physical key presses | `handleHotkeyDown()` (line 260) |
| `DictationViewModel.swift` | Manages app state and UI updates | `toggle()` (line 430), `isRecording` (line 26) |
| `DictationController.swift` | Orchestrates recording pipeline | `toggle()` (line 113) |
| `SimpleModeSettingsView.swift` | Settings UI | Potential location of debug modal |
| `SimplePromptEditorView.swift` | Prompt editing | Potential location of debug modal |
| `ContentView.swift` | Main UI structure | Navigation and modal definitions |

### Documentation Files (New)

| File | Size | Purpose |
|------|------|---------|
| `HOTKEY_SUMMARY.md` | 3KB | Quick reference and overview |
| `HOTKEY_FLOW_ANALYSIS.md` | 12KB | Complete call chain and analysis |
| `HOTKEY_CODE_SNIPPETS.md` | 8KB | Actual code excerpts |
| `MODAL_EXPANSION_FIX.md` | 13KB | Fix strategies and debugging |
| `HOTKEY_ANALYSIS_INDEX.md` | This file | Navigation and overview |

## State Property Changes

When hotkey is pressed, these properties change on the MainActor:

```swift
// IMMEDIATE (within milliseconds)
isRecording: false → true          // @Published - triggers view refresh
recordingStartTimestamp: nil → Date()
recordingStartInProgress: false → true

// DELAYED (~200ms, from timer poll)
status: "Idle" → "Recording"       // @Published - triggers view refresh

// ACTOR-LOCAL (not directly observed, polled)
controller.state: .idle → .recording
```

## The Modal Problem Explained

**Symptom:**
```
User action: Open prompt debug modal
Result: Modal appears empty and tiny
User action: Press hotkey
Result: Modal suddenly expands and shows content
```

**Root cause:**
- Modal is presented while `isRecording = false`
- Modal content depends on or is conditional on `isRecording`
- When hotkey is pressed, `isRecording = true`
- View invalidation reveals content that was hidden or not calculated
- Modal expands to proper size

**Solutions:**
1. Remove dependency on `isRecording` (recommended)
2. Use explicit `.frame()` sizing
3. Use `.defaultSize()` if available
4. Separate modal visibility from recording state
5. Use `.frame(minHeight:)` instead of conditional sizing

See MODAL_EXPANSION_FIX.md for detailed fix implementation.

## Architecture Pattern

The app uses this pattern for responsive UI:

```swift
func toggle() {
    Task {  // Background async task
        // PHASE 1: Update UI immediately (MainActor)
        await MainActor.run {
            self.isRecording = true  // View refresh happens here
        }
        
        // PHASE 2: Prepare (slower operations)
        await updateProvidersImmediately()
        await waitForLatestProviderUpdate()
        await checkAndStoreSelectedTextPromptFast()
        
        // PHASE 3: Execute (slowest operations)
        await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)
    }
}
```

This gives the user immediate visual feedback while expensive operations happen in the background.

## Integration Points

If you're making changes related to recording state:

1. **Hotkey detection** → HotkeyManager.swift
2. **Hotkey callbacks** → DictationViewModel.init() line 353
3. **State changes** → DictationViewModel.toggle()
4. **View updates** → Any view with `@ObservedObject var vm`
5. **Recording execution** → DictationController.toggle()
6. **State polling** → DictationViewModel timer setup (line 369)

Changes to any of these affect when and how the view refreshes.

## Testing the Understanding

To verify your understanding of this flow:

1. Add a breakpoint in `DictationViewModel.toggle()`
2. Step through the execution
3. Watch when `isRecording` changes to `true`
4. Observe what happens to the UI immediately after
5. Verify that `controller.toggle()` hasn't been called yet

This demonstrates that view update (step 4) happens before recording starts (step 6).

## Debugging Checklist

- [ ] Does your modal appear and properly size before pressing hotkey?
- [ ] Does pressing hotkey still start recording normally?
- [ ] Are there any `if vm.isRecording` checks in your modal?
- [ ] Is the modal size bound to any `isRecording` value?
- [ ] Does the modal have explicit `.frame()` sizing?
- [ ] Can you open the modal multiple times with consistent sizing?
- [ ] Does the view hierarchy respect the modal's frame?

## Performance Implications

**Current design:**
- View refresh happens immediately on hotkey press (good for UX)
- Actual recording work happens asynchronously (good for responsiveness)
- State polling happens every 200ms (good balance)
- MainActor updates are prioritized (good for UI responsiveness)

**Potential issues:**
- If modal content is heavy, view refresh might be slow
- If modal size calculation is expensive, it might cause jank
- If multiple @Published properties change, multiple refreshes occur

## Related Topics in CLAUDE.md

From the project CLAUDE.md file:

- **Key Features** section describes Simple Mode (Dictation/Command)
- **Streaming** section describes how Groq streaming works
- **Security & Configuration** describes API key handling
- **Common Development Commands** for building and testing

The hotkey flow integrates with these features - the hotkey triggers recording, which uses the selected transcription provider (Parakeet or Groq streaming).

## Code Style Notes

The codebase follows these conventions (from `.cursor/rules/`):

- **Indentation:** 2 spaces
- **Naming:** `PascalCase` for types, `camelCase` for methods/variables
- **Error handling:** Explicit, avoid force unwrapping
- **Main thread:** Use MainActor for UI updates
- **Async:** Use Swift's async/await pattern

All the hotkey-related code follows these conventions.

## Additional Resources

- **CLAUDE.md** - Project overview and architecture
- **datamodel.md** - Complete data model documentation (661 lines)
- **.cursor/rules/** - Development rules and conventions
- **Scripts/** - Build and run scripts

## Summary

When a user presses the hotkey:

1. Physical key press detected by HotkeyManager
2. Callback triggers DictationViewModel.toggle()
3. **First thing:** `isRecording = true` on MainActor
4. SwiftUI sees @Published change and invalidates views
5. All views observing vm are redrawn
6. Modal content that was hidden now appears
7. Modal layout recalculates and expands
8. Then (in background) actual recording starts

The key insight is that **view refresh happens immediately, before recording starts**, allowing the UI to show immediate feedback while expensive operations occur in the background.

---

**Last Updated:** 2025-11-13  
**Analysis by:** Claude AI  
**Codebase:** WonderWhisper Mac (wwmac-lite)
