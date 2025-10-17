# Deep Analysis of DictationController.toggle() Recording Start Mechanism

## Executive Summary

A thorough analysis of the recording flow reveals **CRITICAL ISSUES** with potential for duplicate audio capture and multiple recording starts. The main problems are:

1. **startRecording() and startStreamingPCM16() are called sequentially without mutual exclusion**
2. **isRecording state is set BEFORE streaming starts, but isStreaming is set INDEPENDENTLY**
3. **stopRecording() can be called when streaming is still active, causing resource leaks**
4. **Callbacks from streaming providers could theoretically trigger state transitions**
5. **No re-entrance guard on DictationController.toggle()**

---

## Critical Code Flow Analysis

### DictationController.toggle() - Recording Start Phase
**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/DictationController.swift`
**Lines:** 63-138

```swift
func toggle(userPrompt: String, activePrompt: PromptConfiguration? = nil) async {
    self.currentPrompt = activePrompt
    switch state {
    case .idle, .error:
        do {
            AppLog.dictation.log("Recording start")

            // LINE 74-77: Set capture profile BEFORE starting recording
            if transcriber is NativeAppleTranscriptionProvider {
                recorder.captureProfile = .appleNativeHighQuality
            } else {
                recorder.captureProfile = .standard16k
            }

            // LINE 80-81: START FILE RECORDING and immediately set state
            let url = try recorder.startRecording()
            state = .recording

            let recordingStart = Date()
            currentRecordingURL = url

            // LINE 87-89: Warmup for Parakeet (Background task, no await)
            if let pk = transcriber as? ParakeetTranscriptionProvider {
                Task { await pk.warmUp() }
            }

            // LINE 92-113: START STREAMING FOR EACH PROVIDER
            if let aai = transcriber as? AssemblyAIStreamingProvider {
                try await aai.beginRealtimeSession(sampleRate: 16_000)
                try? recorder.startStreamingPCM16 { data in
                    Task { try? await aai.feedPCM16(data) }
                }
            } else if let dg = transcriber as? DeepgramStreamingProvider {
                try await dg.beginRealtime()
                try? recorder.startStreamingPCM16 { data in
                    Task { try? await dg.feedPCM16(data) }
                }
            } else if let groq = transcriber as? GroqStreamingProvider {
                groq.updateSettings(transcriberSettings)
                try await groq.beginRealtime()
                try? recorder.startStreamingPCM16 { data in
                    Task { try? await groq.feedPCM16(data) }
                }
            } else if let soniox = transcriber as? SonioxStreamingProvider {
                try await soniox.beginRealtime(settings: transcriberSettings)
                try? recorder.startStreamingPCM16 { data in
                    Task { try? await soniox.feedPCM16(data) }
                }
            }

            // LINE 116-128: Pre-capture context (Background tasks, no await)
            preCapturedScreenSnapshot = nil
            preCapturedScreenText = nil
            preCapturedScreenMethod = nil
            preCapturedScreenSelectedText = nil
            clipboardSnapshotForSession = nil

            if llmEnabled && screenContextEnabled {
                Task { await self.preCaptureScreenContext() }
            }
            if clipboardContextEnabled {
                await clipboardMonitor.refreshSnapshot()
                clipboardSnapshotForSession = await clipboardMonitor.consumeClipboardIfRecent(
                    referenceDate: recordingStart, 
                    window: clipboardWindowSeconds
                )
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

---

## Issue #1: State Management - isRecording vs isStreaming Desynchronization

### AudioRecorder State Tracking
**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/AudioRecorder.swift`
**Lines:** 13-16

```swift
private var recorder: AVAudioRecorder?
private var levelTimer: Timer?
private(set) var isRecording: Bool = false      // LINE 15
private(set) var isStreaming: Bool = false      // LINE 16
```

### Problem

1. **startRecording()** (lines 110-169) sets `isRecording = true` on line 158
2. **startStreamingPCM16()** (lines 264-300) sets `isStreaming = true` on line 277
3. These two flags are **INDEPENDENT** with no mutual coordination

#### Scenario: Partial Streaming Start Failure

```
Time T0: startRecording() called
        ├─ AVAudioRecorder created and recording starts
        └─ isRecording = true ✓

Time T1: beginRealtimeSession() called (awaited)
        ├─ WebSocket connection initiated
        └─ May throw error or timeout

Time T2: startStreamingPCM16() called
        ├─ IF isStreaming already true, stopStreamingPCM16() called first (line 266-269)
        ├─ BUT: If isStreaming was never set (previous call failed), 
        │       we continue WITHOUT cleanup
        └─ isStreaming = true
        └─ setupAudioEngine() called (async via audioQueue.async)

Result: 
  - isRecording = true ✓
  - isStreaming = true ✓
  - BUT: AVAudioEngine setup may overlap with AVAudioRecorder
  - POTENTIAL: Double audio capture through two different mechanisms
```

---

## Issue #2: Sequential Non-Atomic Recording Starts

### Lines 80-113 in toggle():

```swift
let url = try recorder.startRecording()         // LINE 80 - FILE recording starts
state = .recording                               // LINE 81 - STATE IMMEDIATELY SET

// ... (lines 83-88: setup code) ...

if let aai = transcriber as? AssemblyAIStreamingProvider {
    try await aai.beginRealtimeSession(...)     // LINE 93 - AWAITED
    try? recorder.startStreamingPCM16 { ... }   // LINE 94 - CALLED
}
```

### Timeline Issue

```
T0: startRecording() returns URL
    - state = .recording (immediately)
    - UI shows "Recording" 
    - AVAudioRecorder is actively capturing

T1-T2: aai.beginRealtimeSession() executing
       - Creates WebSocket connection
       - May take 100-500ms
       - state = .recording already committed

T3: startStreamingPCM16() called
    - IF beginRealtimeSession() failed silently:
       aai is not ready but startStreamingPCM16 proceeds
    - audioEngine starts on different thread (audioQueue.async)
    - Now TWO audio capture paths active
```

### Vulnerable Points

- **No guard** between `startRecording()` and `startStreamingPCM16()`
- **State is committed** before streaming is even attempted
- **try? recorder.startStreamingPCM16()** silently swallows errors (line 94, 99, 105, 110)

---

## Issue #3: Re-entrance Attack Vector

### DictationViewModel.toggle() - No State Check Before Calling Controller

**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/DictationViewModel.swift`
**Lines:** 407-438

```swift
func toggle() {
    persistPromptLibrary()
    Task {
        // Check state first
        let currentState = await controller.currentState()  // LINE 414

        switch currentState {
        case .idle, .error:
            // Update UI IMMEDIATELY before async work
            await MainActor.run { self.isRecording = true }  // LINE 422

            let prompt = await MainActor.run { self.userPrompt }
            let activePrompt = await MainActor.run { 
                self.prompts.first(where: { $0.id == self.selectedPromptID }) 
            }
            
            // CRITICAL: No re-check before calling toggle()
            await controller.toggle(userPrompt: prompt, activePrompt: activePrompt)  // LINE 426
        // ...
    }
}
```

### Problem

```
Scenario: User rapidly presses hotkey (e.g., Fn+E twice in 100ms)

Call 1 (T=0ms):
  ├─ currentState() = idle
  ├─ isRecording = true
  └─ controller.toggle() called
      ├─ state = idle
      ├─ startRecording() called (takes 10-50ms)
      └─ ... awaiting beginRealtimeSession() (takes 50-200ms)

Call 2 (T=50ms):  <-- Race condition window
  ├─ currentState() = ???
  │   ├─ If checked before state is committed: returns .idle or transitional state
  │   └─ If checked after state is committed: returns .recording
  ├─ If returns .idle or transient: will attempt SECOND toggle()
  └─ controller.toggle(userPrompt:) called AGAIN
      ├─ state check: if .idle, START RECORDING AGAIN
      └─ DUPLICATE startRecording() attempted!
```

### No Mutual Exclusion

- DictationController is an `actor` but toggle() is NOT atomic
- Multiple concurrent toggle() calls can race
- State is set AFTER files operations start, creating window for races

---

## Issue #4: Async Provider Callbacks During Recording

### AssemblyAIStreamingProvider.feedPCM16()

**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/AssemblyAIStreamingProvider.swift`
**Lines:** 115-122

```swift
func feedPCM16(_ data: Data) async throws {
    guard let task = liveTask, let acc = liveAccumulator else { return }
    if await acc.hasBegun() {
        try await task.send(.data(data))
    } else {
        pendingBinaryChunks.append(data)  // Buffering while awaiting Begin message
    }
}
```

### Problem: Callback Chain During Recording

```
Recording active:
  1. audioEngine processes buffer
  2. installTap callback fires (line 341-348 in AudioRecorder.swift)
  3. processAudioBuffer() called on audioQueue
  4. onPCM16Frame callback invoked (line 395)
  5. Task { try? await aai.feedPCM16(data) } spawned
  6. Callback task may interact with provider state

Risk: 
  - If feedPCM16() throws, exception propagates through Task
  - No error handling on callback (see line 94: try? - errors silently swallowed)
  - Could theoretically trigger state changes in provider
  - Could indirectly cause stopRecording() if exception handler mishandles
```

---

## Issue #5: stopRecording() / stopStreamingPCM16() Ordering Problem

### stopAndProcess() - Lines 140-154

```swift
private func stopAndProcess(userPrompt: String) async {
    guard state == .recording else { return }
    
    // LINE 143: Stop streaming first
    recorder.stopStreamingPCM16()
    
    // LINE 144-152: Abort provider sessions
    if let aai = transcriber as? AssemblyAIStreamingProvider {
        await aai.abortRealtimeSession()
    } else if let dg = transcriber as? DeepgramStreamingProvider {
        await dg.abort()
    } else if let groq = transcriber as? GroqStreamingProvider {
        await groq.abort()
    } else if let soniox = transcriber as? SonioxStreamingProvider {
        await soniox.abort()
    }

    // LINE 154: Stop file recording
    let recordingFileURL = await recorder.stopRecordingAndWait()
    // ...
}
```

### stopStreamingPCM16() - Lines 465-496

```swift
func stopStreamingPCM16() {
    guard isStreaming else { return }

    audioQueue.async { [weak self] in
        guard let self = self else { return }

        self.isStreaming = false                           // LINE 471

        // Stop audio engine
        self.audioEngine.stop()                            // LINE 474
        self.inputNode.removeTap(onBus: 0)                // LINE 475

        // Log health metrics
        self.logAudioHealth()

        print("🛑 Streaming stopped")

        // Clear all references (must be done after stopping engine)
        self.audioEngine = nil                             // LINE 483
        self.inputNode = nil                               // LINE 484
        self.audioFormat = nil                             // LINE 485
        self.audioConverter = nil                          // LINE 486
        self.audioBufferList.removeAll(keepingCapacity: false)
        self.onPCM16Frame = nil                            // LINE 488
        
        // ... additional cleanup
    }
}
```

### Problem: Asynchronous Cleanup During Concurrent Operations

```
Timeline:
T0: stopAndProcess() called
    ├─ recorder.stopStreamingPCM16() called (line 143)
    │   ├─ Queues cleanup on audioQueue.async
    │   ├─ Returns IMMEDIATELY
    │   └─ isStreaming still = true for brief moment

T0+1ms: abort providers called (lines 144-152)
        ├─ These ARE awaited
        └─ But audioEngine cleanup is still pending on audioQueue

T0+10ms: stopRecordingAndWait() called (line 154)
         ├─ Awaits AVAudioRecorder.stop()
         └─ May race with audioEngine still processing final buffers

RACE CONDITION:
- stopStreamingPCM16() cleanup is ASYNC
- stopRecordingAndWait() may complete BEFORE audioEngine is cleaned
- If onPCM16Frame callback fires during this window:
  ├─ May attempt to send data to aborted provider
  ├─ May access nil audioEngine
  └─ May crash or corrupt state
```

---

## Issue #6: Order of State Transitions vs. Audio Start

### Critical Timing Question

```swift
// Line 80-81 in toggle()
let url = try recorder.startRecording()     // Audio actively capturing
state = .recording                           // State set

// Problem: What if exception thrown between these two lines?
// - Audio recording active, but state not updated
// - Next call to toggle() would see state != .recording
// - Could start SECOND recording!
```

### Current vs. Ideal Order

**CURRENT ORDER:**
1. startRecording() -> audio streams to file ✓
2. state = .recording -> UI updates
3. beginRealtime*() awaited
4. startStreamingPCM16() -> dual capture potentially active
5. Return from toggle()

**CRITICAL ISSUE:** After line 80 but before line 81, if ANY error occurs:
- State is NOT .recording
- But AVAudioRecorder IS recording
- Next toggle() call will see state != .recording, attempt RESTART

---

## Issue #7: Multiple Recording Attempts - Concrete Scenario

### Scenario: User presses hotkey, then immediately presses ESC

**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/DictationViewModel.swift`

```swift
// Lines 485-514: updateEscapeMonitor()
private func updateEscapeMonitor(isRecording: Bool) {
    // ...
    escapeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) in
        guard let self = self else { return }
        if event.keyCode == 53 { // kVK_Escape
            self.cancel()  // LINE 511 - SYNCHRONOUS
        }
    }
}

// Lines 474-483: cancel()
func cancel() {
    Task {
        // Optimistically update UI
        await MainActor.run { self.isRecording = false }  // LINE 477
        await controller.cancel()                          // LINE 478
        // ...
    }
}
```

### Timeline

```
T=0ms: User presses Fn+E (hotkey)
       ├─ DictationViewModel.toggle() called
       ├─ currentState() checked = .idle
       └─ isRecording = true (UI updated immediately)

T=20ms: DictationController.toggle() executing
        ├─ startRecording() called
        ├─ state = .recording set
        └─ beginRealtimeSession() awaiting (takes ~100ms)

T=25ms: User presses ESC
        ├─ NSEvent monitor fires (synchronous)
        └─ cancel() called
            ├─ Creates Task { ... }
            ├─ Returns immediately
            └─ UI: isRecording = false queued for MainActor

T=30ms: cancel() Task executes
        ├─ isRecording = false set on MainActor
        └─ controller.cancel() called

T=35ms: DictationController.cancel() executing
        ├─ guard state == .recording else { return }  // TRUE - passes
        ├─ recorder.stopStreamingPCM16() called
        ├─ provider.abort() calls
        └─ recorder.stopRecording() called

T=120ms: DictationController.toggle() resuming from await
         ├─ beginRealtimeSession() finally returns
         ├─ startStreamingPCM16() called
         ├─ BUT: isRecording already false (from ESC)
         └─ State machine corruption!

Result: 
  - Recording was stopped (good)
  - BUT: streaming setup happened AFTER cancellation
  - Provider state machine may be corrupted
  - Resources may not be properly cleaned
```

---

## Issue #8: Callback Race During Provider Transition

### setupAudioEngine() Tap Installation

**File:** `/Users/danekapoor/Development/WonderWhisper Mac/WonderWhisper Mac/AudioRecorder.swift`
**Lines:** 340-349

```swift
// Install audio tap with optimized settings
inputNode.installTap(onBus: 0,
                    bufferSize: bufferSize,
                    format: inputFormat) { [weak self] buffer, audioTime in
    guard let self = self, self.isStreaming else { return }      // LINE 344

    self.audioQueue.async {
        self.processAudioBuffer(buffer, at: audioTime)           // LINE 347
    }
}
```

### Problem: isStreaming Flag Check

```
Race condition in tap callback:

T0: startStreamingPCM16() called
    ├─ isStreaming = true set (line 277)
    └─ setupAudioEngine() called
        └─ installTap() called (line 341)

T1: First audio buffer arrives (during setupAudioEngine still running)
    ├─ Tap callback fires
    ├─ guard let self = self, self.isStreaming else { return }
    ├─ isStreaming might be true (good path)
    └─ ... or might race with cleanup (stopStreamingPCM16)

T2: stopStreamingPCM16() called from stopAndProcess()
    ├─ audioQueue.async { ... cleanup ... } (line 468)
    ├─ Returns immediately
    └─ isStreaming = false (line 471) - happens INSIDE async block

Meanwhile:
T1+5ms: Audio buffer arrives from engine
        ├─ Tap callback checks self.isStreaming (from line 344)
        ├─ Race: might be true or false depending on timing
        ├─ If false, returns without processing
        ├─ If true and cleanup already happened:
        │   └─ self.audioQueue.async called but target state corrupted
        └─ Potential nil pointer access or memory corruption
```

---

## Recommendations for Fixes

### Fix #1: Add Mutual Exclusion Lock to Recording Start

```swift
private let recordingLock = NSLock()

func toggle(...) async {
    recordingLock.lock()
    defer { recordingLock.unlock() }
    
    // Check state again under lock
    guard state == .idle || state == .error else {
        recordingLock.unlock()
        return
    }
    
    // Proceed with recording start
    // ...
}
```

### Fix #2: Make Recording Start Atomic

```swift
func startRecording() throws -> URL {
    // ... setup ...
    
    recorder = try AVAudioRecorder(url: url, settings: settings)
    // ... all setup ...
    
    // Atomic state transition
    try recorder?.record()
    isRecording = true  // ONLY set after audio is actually flowing
    return url
}
```

### Fix #3: Add State Version/Generation Number

```swift
private var recordingGeneration: Int = 0

func startRecording() throws -> URL {
    recordingGeneration += 1
    let generation = recordingGeneration
    
    // ... recording setup ...
    
    return url
}

func stopStreamingPCM16() {
    guard isStreaming else { return }
    let targetGeneration = recordingGeneration  // Capture current
    
    audioQueue.async { [weak self, targetGeneration] in
        guard let self = self, self.recordingGeneration == targetGeneration else { return }
        // Cleanup only if still same generation
        // ...
    }
}
```

### Fix #4: Wait for Streaming to Actually Start

```swift
func startRecording() throws -> URL {
    // ... setup ...
    isRecording = true
    startLevelUpdates()
    return url
}

func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {
    if isStreaming {
        throw NSError(...) // Don't silently stop, fail explicitly
    }
    
    isStreaming = true
    self.onPCM16Frame = onFrame
    
    setupAudioEngine()
    
    try audioQueue.sync { [weak self] in  // SYNC not async - wait for start
        guard let self = self else { return }
        try self.audioEngine.start()
        // Confirm engine actually started before returning
        guard self.audioEngine.isRunning else {
            throw NSError(...)
        }
    }
}
```

### Fix #5: Explicit Streaming Ready Signal

```swift
actor DictationController {
    private var streamingReady: Bool = false
    
    func toggle(...) async {
        // ...
        let url = try recorder.startRecording()
        state = .recording
        
        if let aai = transcriber as? AssemblyAIStreamingProvider {
            try await aai.beginRealtimeSession(...)
            streamingReady = false  // Mark not ready
            try recorder.startStreamingPCM16 { ... }
            streamingReady = true   // Mark ready only after successful start
        }
    }
}
```

---

## Summary of Risks

| Risk | Severity | Likelihood | Impact |
|------|----------|------------|--------|
| Duplicate audio capture from dual startRecording() calls | CRITICAL | HIGH | Silent audio duplication, corrupted recordings |
| Race condition between file and stream recording start | CRITICAL | MEDIUM | Resource exhaustion, state corruption |
| Callbacks executing during cleanup | HIGH | MEDIUM | Crashes, memory violations |
| Re-entrance without mutual exclusion | HIGH | MEDIUM | Multiple recording starts |
| Asynchronous cleanup timing issues | HIGH | MEDIUM | Resource leaks, state corruption |
| Provider state machine desynchronization | MEDIUM | MEDIUM | Transcription failures, exceptions |

