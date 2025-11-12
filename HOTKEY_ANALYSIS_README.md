# Hotkey Recording State Analysis - Complete Documentation

## What This Is

This is a comprehensive analysis of what happens in the WonderWhisper Mac app when a user presses the hotkey to start dictation recording. The analysis focuses on explaining why a prompt debug modal appears as an empty tiny box until the hotkey is pressed, then suddenly expands to show content properly.

**Total Documentation:** 68KB across 6 comprehensive guides

## Start Here

If you're new to this analysis, start with this reading order:

### For Quick Understanding (5-10 minutes)
1. Read **HOTKEY_SUMMARY.md** - Overview and 30-second explanation
2. Look at **HOTKEY_VISUAL_REFERENCE.md** - Timeline diagrams and visual maps

### For Complete Understanding (30-45 minutes)
1. **HOTKEY_SUMMARY.md** - Quick overview
2. **HOTKEY_FLOW_ANALYSIS.md** - Complete call chain and architecture
3. **HOTKEY_CODE_SNIPPETS.md** - Actual code from the codebase
4. **HOTKEY_VISUAL_REFERENCE.md** - Diagrams and visual references

### To Fix the Modal Issue (30 minutes)
1. **MODAL_EXPANSION_FIX.md** - Root cause and 5 fix strategies
2. Look at your actual modal code
3. Apply the appropriate fix strategy

### For Navigation (Anytime)
- **HOTKEY_ANALYSIS_INDEX.md** - Detailed navigation guide and overview

## The Documents

### 1. HOTKEY_SUMMARY.md (5.7 KB)
**Quick reference guide**

Contains:
- Problem in one sentence
- 30-second complete flow
- Key state changes table
- The magic line of code
- Why modal appears empty
- Quick debugging tips
- 3 documents overview

**Best for:** Getting up to speed quickly, quick debugging

### 2. HOTKEY_FLOW_ANALYSIS.md (9.9 KB)
**Complete call chain analysis**

Contains:
- Full problem statement
- Complete call chain from hotkey press to view refresh
- Detailed explanation of each step
- isRecording property with didSet handler
- Controller toggle and state changes
- State polling timer operation
- View refresh triggers explanation
- Sequence diagram
- Why this causes modal expansion
- Solution approaches

**Best for:** Understanding the system design and how components connect

### 3. HOTKEY_CODE_SNIPPETS.md (10 KB)
**Actual code from the codebase**

Contains:
- HotkeyManager.handleHotkeyDown() with explanation
- DictationViewModel hotkey callback setup
- isRecording property complete code
- toggle() function complete code
- DictationController.toggle() recording start
- State polling timer complete code
- State change summary table
- View refresh cascade diagram
- All with line numbers and file paths

**Best for:** Developers who want to see the actual implementation

### 4. MODAL_EXPANSION_FIX.md (9.2 KB)
**Root cause and fix strategies**

Contains:
- Root cause analysis with diagrams
- What's happening in detail
- Where to look in the code
- Exact patterns to search for
- 5 different fix strategies with code examples:
  1. Remove isRecording dependency (recommended)
  2. Set fixed modal size
  3. Use .defaultSize()
  4. Separate state concerns
  5. Force layout calculation
- Implementation checklist
- Testing guide
- Debugging tips
- Related files to review

**Best for:** Fixing the empty modal problem, implementing solutions

### 5. HOTKEY_ANALYSIS_INDEX.md (9.9 KB)
**Navigation and detailed overview**

Contains:
- Overview of all documents
- Quick navigation guide ("I want to...")
- Core insight explanation
- Key files referenced table
- State property changes summary
- The modal problem explained
- Architecture pattern description
- Integration points for making changes
- Testing the understanding
- Debugging checklist
- Performance implications
- Related topics and resources

**Best for:** Navigation, detailed overview, debugging checklist

### 6. HOTKEY_VISUAL_REFERENCE.md (23 KB)
**Diagrams, timelines, and visual maps**

Contains:
- Complete timeline diagram with ASCII art
- State property map
- Component interaction diagram
- isRecording lifecycle diagram
- View refresh cascade diagram
- Modal problem illustrated (before/after)
- Code execution order diagram
- Summary table

**Best for:** Visual learners, understanding sequence and relationships

## Key Findings

### The Core Issue

When a user presses the hotkey:

```
HotkeyManager detects key press
    ↓
DictationViewModel.toggle() is called
    ↓
isRecording = true (on MainActor)
    ↓
@Published property change triggers view invalidation
    ↓
SwiftUI redraws entire view tree
    ↓
Modal content (that was hidden) now appears
    ↓
Modal size recalculates and expands
    ↓
THEN actual recording starts in background
```

### Why the Modal Appears Empty

The modal appears empty because:

1. Modal is presented while `isRecording = false`
2. Modal content or size depends on `isRecording`
3. SwiftUI calculates minimal layout
4. Hotkey press makes `isRecording = true`
5. View invalidation reveals hidden content
6. Modal expands

### The Fix

Choose from 5 strategies in MODAL_EXPANSION_FIX.md:

1. **Remove dependency** - Best option if modal doesn't need to know about recording state
2. **Explicit sizing** - Use `.frame()` to set initial size
3. **defaultSize()** - Modern SwiftUI approach
4. **Separate state** - Independent modal visibility state
5. **Force layout** - Use minimum heights instead of conditional sizing

## Quick Reference

### The Magic Line
```swift
await MainActor.run {
    self.isRecording = true  // ← This triggers view refresh
}
```

**File:** DictationViewModel.swift, line 439

### State Changes on Hotkey Press

| Property | Before | After | Trigger |
|----------|--------|-------|---------|
| isRecording | false | true | MainActor immediate |
| recordingStartTimestamp | nil | Date() | MainActor immediate |
| recordingStartInProgress | false | true | MainActor immediate |
| status | "Idle" | "Recording" | Timer (~200ms) |

### Key Files

| File | Purpose | Lines |
|------|---------|-------|
| HotkeyManager.swift | Hotkey detection | 260-290 |
| DictationViewModel.swift | State management | 26, 353, 430-470, 369-410 |
| DictationController.swift | Recording control | 113-150 |

## How to Use This Documentation

### Scenario 1: "I need to understand what happens on hotkey press"
1. Read HOTKEY_SUMMARY.md (5 min)
2. Look at HOTKEY_VISUAL_REFERENCE.md diagrams (5 min)
3. Read HOTKEY_FLOW_ANALYSIS.md (15 min)

**Total time: 25 minutes**

### Scenario 2: "I need to fix the empty modal bug"
1. Read MODAL_EXPANSION_FIX.md (20 min)
2. Identify which view has the modal
3. Apply one of the 5 fix strategies (depends on fix)
4. Test the fix

**Total time: 30-60 minutes depending on complexity**

### Scenario 3: "I'm debugging view refresh issues"
1. Look at HOTKEY_VISUAL_REFERENCE.md "View Refresh Cascade" (5 min)
2. Read HOTKEY_CODE_SNIPPETS.md "Critical Observation" (5 min)
3. Check MODAL_EXPANSION_FIX.md "Debugging Tips" (10 min)

**Total time: 20 minutes**

### Scenario 4: "I need to make changes to hotkey handling"
1. Read HOTKEY_ANALYSIS_INDEX.md "Integration Points" (5 min)
2. Review HOTKEY_CODE_SNIPPETS.md for affected code (10 min)
3. Check HOTKEY_FLOW_ANALYSIS.md for dependencies (10 min)

**Total time: 25 minutes**

## File Locations

All analysis documents are in the project root:

```
/Users/danekapoor/Development/WWMac-lite/
├── HOTKEY_ANALYSIS_README.md (this file)
├── HOTKEY_SUMMARY.md
├── HOTKEY_FLOW_ANALYSIS.md
├── HOTKEY_CODE_SNIPPETS.md
├── MODAL_EXPANSION_FIX.md
├── HOTKEY_ANALYSIS_INDEX.md
├── HOTKEY_VISUAL_REFERENCE.md
```

Source code files referenced:

```
/Users/danekapoor/Development/WWMac-lite/WonderWhisper Mac/
├── HotkeyManager.swift
├── DictationViewModel.swift
├── DictationController.swift
├── ContentView.swift
├── SimplePromptEditorView.swift
├── SimpleModeSettingsView.swift
```

## Key Takeaways

1. **View refresh is immediate** - isRecording change triggers instant SwiftUI redraw
2. **Recording starts later** - Actual recording happens after view refresh
3. **Modal depends on state** - Empty modal means content depends on isRecording
4. **Five fix strategies** - Choose based on your modal's needs
5. **Responsive design** - Intentional delay between UI update and work

## Testing Checklist

- [ ] Read HOTKEY_SUMMARY.md
- [ ] Look at HOTKEY_VISUAL_REFERENCE.md timeline
- [ ] Identify your problematic modal
- [ ] Find isRecording dependencies in your modal
- [ ] Choose and apply a fix strategy
- [ ] Test modal appears properly before hotkey press
- [ ] Test hotkey still starts recording
- [ ] Verify no UI jank or layout issues

## Common Questions

**Q: Why does the modal appear empty?**
A: It depends on isRecording being true, but isRecording is false when modal opens. See MODAL_EXPANSION_FIX.md.

**Q: When does the view refresh happen?**
A: Immediately when isRecording changes (milliseconds). See HOTKEY_VISUAL_REFERENCE.md "Timeline Diagram".

**Q: How can I fix this?**
A: 5 strategies in MODAL_EXPANSION_FIX.md. Recommended: Remove isRecording dependency.

**Q: Does this affect recording?**
A: No, this is about view refresh timing. Recording starts normally after view refresh.

**Q: Can I debug this?**
A: Yes, see HOTKEY_ANALYSIS_INDEX.md "Debugging Checklist" and MODAL_EXPANSION_FIX.md "Debugging Tips".

## Document Statistics

| Document | Size | Words | Purpose |
|----------|------|-------|---------|
| HOTKEY_SUMMARY.md | 5.7 KB | ~900 | Quick reference |
| HOTKEY_FLOW_ANALYSIS.md | 9.9 KB | ~1800 | Complete analysis |
| HOTKEY_CODE_SNIPPETS.md | 10 KB | ~1500 | Source code |
| MODAL_EXPANSION_FIX.md | 9.2 KB | ~1600 | Fix strategies |
| HOTKEY_ANALYSIS_INDEX.md | 9.9 KB | ~1700 | Navigation guide |
| HOTKEY_VISUAL_REFERENCE.md | 23 KB | ~1800 | Diagrams & visuals |
| **TOTAL** | **68 KB** | **~11,000** | **Complete guide** |

## Version Info

- **Created:** 2025-11-13
- **Codebase:** WonderWhisper Mac (wwmac-lite)
- **Analysis by:** Claude AI
- **Scope:** Hotkey detection to view refresh pipeline

## Next Steps

1. **If fixing the modal:** Start with MODAL_EXPANSION_FIX.md
2. **If learning the system:** Read in order: SUMMARY → FLOW → CODE → VISUAL
3. **If debugging:** Check HOTKEY_ANALYSIS_INDEX.md checklist + MODAL_EXPANSION_FIX.md debugging
4. **If making changes:** Read HOTKEY_ANALYSIS_INDEX.md integration points

---

**All documents are comprehensive, self-contained, and cross-referenced. Pick the one that matches your needs.**
