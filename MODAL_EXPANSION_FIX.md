# Modal Expansion Issue - Root Cause and Fix Guide

## Executive Summary

When a prompt debug/preview modal is opened, it appears as an empty tiny box until the hotkey is pressed to start dictation. Pressing the hotkey triggers `isRecording = true`, which causes SwiftUI to invalidate and redraw the entire view tree, revealing the modal's actual content and proper size.

**Root Cause:** The modal's layout depends on `isRecording` being true, but it's presented before recording starts.

## Root Cause Analysis

### What's Happening

1. **Modal Opens (isRecording = false)**
   - User opens the prompt debug modal
   - At this point, `isRecording` is `false`
   - SwiftUI renders the view hierarchy with `isRecording = false`
   - If the modal content depends on `isRecording`, it may be hidden or not properly calculated
   - Layout engine calculates minimal size (tiny box)

2. **Hotkey Pressed (isRecording = true)**
   - User presses hotkey to start recording
   - `toggle()` executes
   - First thing it does: `await MainActor.run { self.isRecording = true }`
   - This is `@Published`, so it triggers view invalidation
   - SwiftUI redraws entire view tree
   - Now `isRecording = true`, content appears, modal expands

### Why This Happens

The problem is in how SwiftUI handles view invalidation:

```
Initial render (isRecording=false):
├── Modal appears
├── Modal content checks: if isRecording { show content }
├── Content is hidden or conditional
├── Size calculated as minimal
└── Tiny empty box appears

After hotkey (isRecording=true):
├── @Published isRecording changes
├── SwiftUI invalidates @ObservedObject
├── Entire view tree redraws
├── Modal content now shows (if isRecording=true)
├── Size recalculated with actual content
└── Modal expands to proper size
```

## Where to Look

### 1. Check What the Modal is Displaying

Find the modal/sheet that's experiencing this issue. Look for:

**File locations likely containing the modal:**
- `SimpleModeSettingsView.swift`
- `SimplePromptEditorView.swift`
- `SimpleHistoryView.swift`
- Any custom view that displays prompt debugging info

Search for patterns like:
```swift
.sheet(isPresented: ...) { ... }
.modal(...) { ... }
Text(vm.systemPrompt)
Text(vm.userPrompt)
```

### 2. Identify the Dependency on isRecording

Look for code like:

```swift
// BAD: Modal visibility depends on isRecording
struct MyDebugModal: View {
    @ObservedObject var vm: DictationViewModel
    @State var showModal = true
    
    var body: some View {
        if vm.isRecording {
            Text(vm.systemPrompt)  // Only visible when recording
        }
    }
}
```

Or:

```swift
// BAD: Modal size depends on isRecording
Text(vm.systemPrompt)
    .frame(height: vm.isRecording ? 200 : 10)  // Size jumps when isRecording changes
```

### 3. Check if Content is Conditional on isRecording

Search for patterns in the modal view:

```swift
if vm.isRecording { ... }
vm.isRecording ? ... : ...
@available(when: vm.isRecording) // Not real syntax, but conceptually
```

## Fix Strategies

### Strategy 1: Remove isRecording Dependency (RECOMMENDED)

**Problem:**
```swift
var body: some View {
    VStack {
        if vm.isRecording {
            Text(vm.systemPrompt)
        }
    }
}
```

**Solution:**
```swift
var body: some View {
    VStack {
        // Always show, regardless of recording state
        Text(vm.systemPrompt)
    }
}
```

**Rationale:** A prompt debug modal should show the prompt regardless of recording state.

### Strategy 2: Set Fixed Modal Size

**Problem:**
```swift
.sheet(isPresented: $showModal) {
    Text(vm.systemPrompt)  // Size depends on SwiftUI's layout
}
```

**Solution:**
```swift
.sheet(isPresented: $showModal) {
    VStack {
        Text(vm.systemPrompt)
    }
    .frame(minWidth: 500, minHeight: 300)  // Set initial size
    .frame(maxWidth: .infinity, maxHeight: .infinity)  // Allow expansion
}
```

**Rationale:** Explicit sizing prevents SwiftUI from calculating minimal dimensions.

### Strategy 3: Use .defaultSize (SwiftUI 15+)

**Problem:**
```swift
.sheet(isPresented: $showModal) {
    DebugPromptView(vm: vm)
}
```

**Solution:**
```swift
.sheet(isPresented: $showModal) {
    DebugPromptView(vm: vm)
        .defaultSize(width: 600, height: 400)
}
```

**Rationale:** Explicitly tells SwiftUI the ideal size before rendering content.

### Strategy 4: Separate State Concerns

**Problem:**
```swift
var body: some View {
    // Modal visibility tied to recording state
    if vm.isRecording {
        Modal {
            Text(vm.systemPrompt)
        }
    }
}
```

**Solution:**
```swift
@State var showDebugModal = false

var body: some View {
    // Separate state for modal visibility
    if showDebugModal {
        Modal {
            Text(vm.systemPrompt)
        }
    }
    
    Button("Debug") { showDebugModal = true }
}
```

**Rationale:** Modal visibility is independent from recording state, preventing race conditions.

### Strategy 5: Force Layout Calculation

**Problem:**
```swift
Text(vm.systemPrompt)
    .frame(height: vm.isRecording ? 200 : 10)
```

**Solution:**
```swift
Text(vm.systemPrompt)
    .frame(minHeight: 200)  // Always at least 200pt
    .frame(maxHeight: .infinity)  // Can expand
```

**Rationale:** Layout is calculated once, not recalculated when isRecording changes.

## Implementation Checklist

- [ ] **Identify the modal view** - Which file contains the problematic modal?
- [ ] **Find content conditions** - Search for `if vm.isRecording` in the modal
- [ ] **Check frame/size bindings** - Are dimensions bound to `isRecording`?
- [ ] **Review @Published dependencies** - What properties does the modal observe?
- [ ] **Apply one of the fix strategies** - Choose the most appropriate approach
- [ ] **Test the fix** - Open modal without pressing hotkey, verify size
- [ ] **Verify hotkey still works** - Ensure recording still starts correctly
- [ ] **Check for regressions** - Make sure nothing else broke

## Code Review Questions

When examining the modal code, ask:

1. **Does this modal NEED to know about isRecording?**
   - If NO → Remove the dependency
   - If YES → Why? Can it be redesigned?

2. **Is the modal content conditional on isRecording?**
   - If YES → Why? Can it be made unconditional?

3. **Does the modal size change based on isRecording?**
   - If YES → Use explicit frame() instead

4. **Is the modal shown while isRecording = false?**
   - If YES → It should work without isRecording being true

5. **Are there other @Published properties the modal depends on?**
   - If YES → Check if they change when isRecording changes
   - This could cause a cascading refresh

## Performance Impact

**Before fix:**
- Hotkey press causes full view tree redraw
- Modal expansion animation may appear jerky
- Two separate layout passes (minimal, then full)

**After fix:**
- View renders correctly the first time
- No unexpected layout changes
- Smoother user experience

## Related Files to Review

Based on the codebase structure, check these files for potential issues:

1. `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/SimplePromptEditorView.swift`
   - Likely contains prompt editing interface
   - May have conditional display logic

2. `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/SimpleModeSettingsView.swift`
   - May have a prompt preview/debug section

3. `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/ContentView.swift`
   - Main navigation structure
   - Sheets/modals are often defined here

4. `/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/DictationViewModel.swift`
   - The source of `isRecording` and other state
   - Review @Published properties

## Testing the Fix

```swift
// Test 1: Modal appears correct without pressing hotkey
1. Launch app
2. Open prompt debug modal
3. Modal should appear at full size
4. No tiny/empty box phase

// Test 2: Recording still works
1. Open modal
2. Press hotkey
3. Recording should start normally
4. Modal should not interfere

// Test 3: No layout jank
1. Open modal (should be smooth)
2. Press hotkey (should be smooth)
3. No flashing/jumping/resizing
```

## Debugging Tips

If the issue persists after applying fixes:

1. **Add debug logging to track state changes:**
```swift
@Published var isRecording: Bool = false {
    didSet {
        print("isRecording changed: \(oldValue) -> \(isRecording)")
    }
}
```

2. **Use SwiftUI's debugger to see view invalidations:**
```swift
.onReceive(vm.objectWillChange) {
    print("ViewModel changed, views will redraw")
}
```

3. **Check if the modal view is respecting its frame:**
```swift
.border(Color.red)  // Add temporary border to see frame
.frame(width: 600)  // Test explicit size
```

4. **Verify the modal is actually being presented:**
```swift
.sheet(isPresented: $showModal) {
    Text("Modal is presented")  // Simple test
    DebugPromptView(vm: vm)
}
```

## Summary

The "empty tiny modal" issue occurs because:

1. Modal opens before `isRecording = true`
2. SwiftUI calculates minimal layout
3. Modal content may be hidden or conditional
4. Hotkey press triggers `isRecording = true`
5. View invalidation forces redraw
6. Modal now appears with proper content and size

**Fix:** Decouple modal content/size from `isRecording` state, use explicit sizing, and ensure content is not conditional on recording status.
