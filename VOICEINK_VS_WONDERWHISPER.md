# VoiceInk vs WonderWhisper Mac: Parakeet Implementation Comparison

**Date:** 2025-01-22  
**Purpose:** Document differences causing hallucinations in WonderWhisper Mac

---

## Critical Differences

### 1. Audio Preprocessing

| Component | VoiceInk | WonderWhisper Mac | Impact |
|-----------|----------|-------------------|--------|
| **High-pass filter** | ❌ None | ✅ 60 Hz (configurable) | Removes low-frequency speech info |
| **Pre-emphasis** | ❌ None | ✅ 0.97 coefficient | Amplifies high frequencies/noise |
| **RMS normalization** | ❌ None | ✅ Target 0.06 (configurable) | Creates unnatural amplitude patterns |
| **Auto-adjust** | ❌ None | ✅ Environmental analysis | May misclassify and apply wrong params |

**Verdict:** VoiceInk does **ZERO preprocessing**. WonderWhisper does **extensive preprocessing** that likely distorts audio.

---

### 2. Audio Decoding

**VoiceInk (Simple):**
```swift
// Lines 9844-9862 in repomix-output-Beingpax-VoiceInk.git.xml
private func readAudioSamples(from url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // Skip WAV header (44 bytes)
    let floats = stride(from: 44, to: data.count, by: 2).map {
        let short = Int16(littleEndian: data[$0..<$0 + 2].load(as: Int16.self))
        return max(-1.0, min(Float(short) / 32767.0, 1.0))
    }
    return floats
}
```

**WonderWhisper (Complex):**
- FastPCM16 decoder (optimized but format-sensitive)
- AVAssetReader fallback (robust but may introduce artifacts)
- AVAudioFile fallback (most compatible)
- Multiple format conversions and memory copies

**Verdict:** VoiceInk's simple approach avoids potential decoding artifacts.

---

### 3. VAD (Voice Activity Detection)

**VoiceInk:**
```swift
// Line 9809-9835
let isVADEnabled = UserDefaults.standard.object(forKey: "IsVADEnabled") as? Bool ?? true

if durationSeconds < 20.0 || !isVADEnabled {
    speechAudio = audioSamples  // No VAD for short audio
} else {
    let vadConfig = VadConfig(threshold: 0.7)  // Fixed threshold
    // Apply VAD...
}
```

**WonderWhisper:**
- VAD enabled by default for ALL audio > 3 seconds
- Adaptive threshold (0.5 base, up to 0.7 for long audio)
- Complex segmentation config (minSpeech, minSilence, padding)

**Verdict:** VoiceInk's VAD is simpler and only applied to long audio (>20s).

---

### 4. Transcription API Call

**VoiceInk:**
```swift
// Line 9837
let result = try await asrManager.transcribe(speechAudio)
// NO source hint parameter
```

**WonderWhisper:**
```swift
// Line 290 in ParakeetTranscriptionProvider.swift
result = try await mgr.transcribe(samples, source: .microphone)
// Uses .microphone source hint
```

**Verdict:** Source hint may trigger unwanted internal processing in Parakeet model.

---

### 5. Model Cleanup

**VoiceInk:**
```swift
// Line 9864-9868
func cleanup() {
    asrManager?.cleanup()
    asrManager = nil
    vadManager = nil
}
// Called after EVERY transcription (line 25871)
```

**WonderWhisper:**
- Idle timeout cleanup after 60 seconds
- Keeps model loaded between rapid transcriptions
- Potential state accumulation

**Verdict:** VoiceInk's immediate cleanup prevents state pollution.

---

## Hallucination Examples

### Problem Audio Output (WonderWhisper)
```
"transc.ription" (broken word)
"don't don't think" (stuttering)
"as a as a table" (repetition)
"Y.es." (broken word)
"..what's the best?" (phantom fragment)
"I'm not sure if I can do it" (completely hallucinated)
"If you can't capture if you can capture" (confused repetition)
```

### Expected Output (Reference)
```
"transcription" (clean)
"don't think" (clean)
"as a table" (clean)
"Yes" (clean)
[no phantom fragments]
[no hallucinations]
[no confused repetitions]
```

---

## Root Cause Hypothesis

**Primary Culprit: Preprocessing Cascade**

1. High-pass filter removes low-frequency speech content
2. Pre-emphasis amplifies remaining noise
3. RMS normalization creates unnatural dynamics
4. Model receives distorted audio it wasn't trained on
5. Model becomes "confused" and hallucinates

**Secondary Factors:**
- Source hint may trigger microphone-specific processing
- Idle cleanup allows state accumulation
- Complex decoding may introduce phase artifacts

---

## Solution: Raw Mode

Implement VoiceInk-style minimal processing as an option:

```swift
// Proposed raw mode path
if rawMode {
    let samples = decodeAudioRaw(audioURL)  // Simple WAV parsing
    let result = try await mgr.transcribe(samples)  // No source hint
    scheduleIdleUnload()  // Idle timeout (60s) instead of immediate cleanup
    return result.text
}
```

**Benefits:**
- Eliminates all preprocessing variables
- Direct A/B test of VoiceInk approach
- Fast validation of hypothesis

---

## Testing Plan

1. **Implement raw mode** (Parakeet v2)
2. **Transcribe problem audio** with raw mode enabled
3. **Compare outputs**: hallucinations eliminated?
4. **If yes:** Preprocessing is confirmed culprit
5. **If no:** Investigate source hint and cleanup timing
6. **Matrix test:** Isolate which preprocessing steps are harmful

---

## Expected Outcome

**If raw mode fixes hallucinations:**
- Default new installs to raw mode
- Add warning about preprocessing trade-offs
- Keep preprocessing as opt-in for advanced users

**If raw mode doesn't fix it:**
- Source hint is likely the culprit
- Or FluidAudio library version mismatch
- Or model state accumulation despite cleanup

---

## References

- VoiceInk Parakeet implementation: `repomix-output-Beingpax-VoiceInk.git.xml` lines 9756-9869
- WonderWhisper implementation: `ParakeetTranscriptionProvider.swift`
- Bug report: `BUG_SUMMARY.txt`
- Accuracy fixes: `PARAKEET_ACCURACY_FIXES.md`
