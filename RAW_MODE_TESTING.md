# Raw Mode Testing Guide

**Quick Start:** Test VoiceInk-style minimal processing to eliminate Parakeet hallucinations

---

## What Was Implemented

✅ **Raw Mode** - VoiceInk-style minimal audio processing
- No high-pass filter
- No pre-emphasis  
- No RMS normalization
- No auto-adjust
- Simple WAV decoding from byte 44
- No source hint in transcribe call
- Idle timeout cleanup (60s) to preserve rapid transcription support

---

## How to Enable

1. **Open WonderWhisper Mac**
2. **Go to Settings** → **Models** → **Parakeet Advanced Settings**
3. **Enable the toggle:** "Raw Mode (VoiceInk-style minimal processing)"
4. **You'll see a warning:** ⚠️ Raw mode bypasses all audio preprocessing...

---

## Testing Steps

### Step 1: Baseline Test (Current Behavior)
1. **Disable** raw mode
2. Record or transcribe your problem audio
3. **Save the output** - note hallucinations like:
   - Broken words: "transc.ription", "Y.es"
   - Stuttering: "don't don't", "as a as a"
   - Phantom fragments: "what's the best?"
   - Confused repetitions: "if you can't capture if you can capture"

### Step 2: Raw Mode Test
1. **Enable** raw mode
2. Transcribe the **SAME audio file**
3. **Compare the output**:
   - Are broken words fixed?
   - Is stuttering eliminated?
   - Are phantom fragments gone?
   - Is overall accuracy better?

### Step 3: Document Results

**If Raw Mode Fixes It:**
```
✅ CONFIRMED: Preprocessing causes hallucinations
- Broken words eliminated
- Stuttering eliminated  
- Phantom fragments eliminated
- Overall accuracy improved by X%
```

**If Raw Mode Doesn't Fix It:**
```
❌ Not preprocessing - investigate:
- Source hint parameter (.microphone)
- Model state accumulation
- FluidAudio library version mismatch
```

---

## What to Look For

### Good Signs (Raw Mode Working)
- **Clean words**: "transcription" instead of "transc.ription"
- **No stuttering**: "don't think" instead of "don't don't think"
- **No repetitions**: "as a table" instead of "as a as a table"
- **No phantom text**: No random fragments appearing
- **Better punctuation**: Periods in correct locations

### Bad Signs (Still Broken)
- Same hallucinations persist
- Different hallucinations appear
- Audio quality issues (clipping, distortion)
- Model errors or crashes

---

## Console Logs to Monitor

Open **Console.app** and filter for "Parakeet":

**Raw mode enabled:**
```
[Parakeet] Raw mode enabled - using VoiceInk-style minimal processing
[Parakeet] Raw mode: decoding audio
[Parakeet] Raw mode samples=384000 meanAbs=0.0453 peak=0.8923
[Parakeet] Raw mode: skipping VAD (duration: 12.5s)
[Parakeet] Raw mode: transcribing (no source hint)
[Parakeet] Raw mode: result length=425 preview=One, just call it audio file...
[Parakeet] Raw mode: immediate cleanup
```

**Raw mode disabled (normal path):**
```
[Parakeet] ensureModelsLoaded dir=/path/to/models
[Parakeet] External preprocess begin
[Parakeet] Decode (FastPCM16): samples=384000
[Parakeet] VAD begin
[Parakeet] ASR begin
[Parakeet] result length=425 preview=One, just call it audio file or file transc.ription...
```

---

## Troubleshooting

### Raw Mode Toggle Not Appearing
- Check you're in **Parakeet Advanced Settings**
- Rebuild the app if necessary
- Verify `parakeet.raw.mode` UserDefaults key exists

### Raw Mode Enabled But Still Using Normal Path
- Check Console.app for "Raw mode enabled" log
- Verify toggle is actually ON (should show orange warning)
- Try restarting the app

### Audio Decoding Fails
- Raw mode requires standard WAV format (16-bit PCM, mono, 16kHz)
- If files are in different format, they'll fall back to normal processing
- Check logs for "Raw mode: Failed to decode WAV audio"

### Model Not Initializing
- Raw mode still requires Parakeet models to be downloaded
- Check model directory has required files
- Verify FluidAudio framework is linked

---

## Expected Performance

**Raw Mode:**
- ✅ Faster transcription (no preprocessing overhead)
- ✅ Better accuracy (if preprocessing was the issue)
- ✅ Immediate cleanup (no memory accumulation)
- ⚠️ May be more sensitive to poor audio quality
- ⚠️ No automatic environment adaptation

**Normal Mode (with preprocessing):**
- ⚠️ Slower transcription (preprocessing takes ~35-45ms)
- ❌ Potential hallucinations (if preprocessing distorts audio)
- ⚠️ Idle timeout cleanup (60s)
- ✅ Auto-adjust for different environments
- ✅ High-pass filtering for rumble reduction

---

## Next Steps After Testing

### If Raw Mode Eliminates Hallucinations

1. **Consider defaulting to raw mode** for new installations
2. **Add prominent warning** about preprocessing risks in UI
3. **Systematically test each preprocessing component** to isolate culprit:
   - Test high-pass filter alone
   - Test pre-emphasis alone
   - Test RMS normalization alone
   - Test combinations
4. **Update presets** to use minimal preprocessing
5. **Document best practices** for when to use each mode

### If Raw Mode Doesn't Help

1. **Test without source hint** in normal mode:
   - Modify line 290: `mgr.transcribe(samples)` instead of `mgr.transcribe(samples, source: .microphone)`
   - See if `.microphone` parameter triggers unwanted processing
2. **Test immediate cleanup** in normal mode:
   - Add cleanup call after every transcription
   - Check if model state accumulation was the issue
3. **Check AudioPreprocessor conflicts**:
   - Verify AudioPreprocessor isn't also active
   - Could be double-processing the audio
4. **Compare FluidAudio library versions** with VoiceInk

---

## Files Modified

- `ParakeetTranscriptionProvider.swift` - Raw mode implementation
- `ParakeetAdvancedSettingsView.swift` - UI toggle
- `VOICEINK_VS_WONDERWHISPER.md` - Comparison documentation
- `PARAKEET_ACCURACY_FIXES.md` - Updated with raw mode section

---

## Feedback & Results

Please document your results:

**Problem Audio Characteristics:**
- Duration: _____ seconds
- Environment: (quiet/noisy/balanced)
- Recording device: _____

**With Preprocessing (Normal Mode):**
- Hallucinations: _____ count
- Broken words: _____
- Overall accuracy: _____%

**With Raw Mode:**
- Hallucinations: _____ count
- Broken words: _____
- Overall accuracy: _____%
- Improvement: _____%

**Conclusion:**
- [ ] Raw mode fixes hallucinations → Preprocessing is confirmed culprit
- [ ] Raw mode doesn't help → Investigate source hint/cleanup
- [ ] Raw mode makes it worse → Revert, investigate different approach
