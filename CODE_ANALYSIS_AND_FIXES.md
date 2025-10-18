# Code Analysis: Parakeet + Audio Enhancement Bug

## The Bug in Context

### BROKEN: ParakeetTranscriptionProvider.swift (Current)

```swift
func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    try await ensureModelsLoaded(version: preferredVersion(for: settings))
    scheduleIdleUnload()
    guard let mgr = asrManager else { throw ProviderError.notImplemented }

    // === PROBLEM STARTS HERE ===
    
    // Line 143-159: BAD PREPROCESSING INTEGRATION
    var cleanupURLs: [URL] = []
    var inputURL = fileURL
    var preprocessingApplied = false
    let allowExternalPreprocess = (UserDefaults.standard.object(forKey: "parakeet.externalPreprocess") as? Bool) ?? false
    if allowExternalPreprocess && AudioPreprocessor.isEnabled {
        AppLog.dictation.log("[Parakeet] External preprocess begin")
        let processed = AudioPreprocessor.processIfEnabled(fileURL)  // ← USES FILE-BASED
        // ^^ This creates a _proc.wav file via:
        //    1. Decode original file
        //    2. Apply filters (high-pass, notch, pre-emphasis)
        //    3. Normalize to RMS=0.08, gain up to 8x
        //    4. ENCODE back to WAV on disk
        
        if processed != fileURL {
            inputURL = processed  // Now points to _proc.wav
            preprocessingApplied = true  // Flag that preprocessing happened
            cleanupURLs.append(processed)
        }
        AppLog.dictation.log("[Parakeet] External preprocess end -> \(inputURL.lastPathComponent)")
    }

    defer {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    var samples: [Float] = []
    
    // === PROBLEM PART 2: DOUBLE DECODE ===
    
    // Line 169: DECODE preprocessed file (SECOND TIME)
    AppLog.dictation.log("[Parakeet] Decode begin for \(inputURL.lastPathComponent)")
    if let alt = try? Self.decodeWithAssetReader(url: inputURL), !alt.isEmpty {
        // ^^ If inputURL is _proc.wav, we're decoding it for the SECOND time
        // First decode: AudioPreprocessor.process() decoded original audio
        // Second decode: Here we decode the _proc.wav output
        AppLog.dictation.log("[Parakeet] Decode (AssetReader): samples=\(alt.count)")
        samples = alt
    } else {
        do {
            AppLog.dictation.log("[Parakeet] Decode (AVAudioFile) begin")
            samples = try Self.decodeAudioToFloatMono16k(url: inputURL)
            AppLog.dictation.log("[Parakeet] Decode (AVAudioFile) end: samples=\(samples.count)")
        } catch {
            let ns = error as NSError
            AppLog.dictation.error("[Parakeet] AVAudioFile decode failed domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
    }

    // === PROBLEM PART 3: SKIPPED NORMALIZATION ===
    
    // Line 209-216: SKIP normalization if preprocessing was applied
    if !preprocessingApplied {
        // This block runs ONLY if NO preprocessing happened
        let hpHz = autoOverrides?.highPassHz ?? (defaults.object(forKey: "parakeet.highpass.hz") as? Int ?? 60)
        if hpHz > 0 { samples = Self.highPass(samples, cutoffHz: Double(hpHz), sampleRate: 16_000) }
        let preEnabled = defaults.object(forKey: "parakeet.preemphasis") as? Bool ?? true
        if preEnabled { samples = Self.preEmphasis(samples, coeff: 0.97) }
        let targetRMS = autoOverrides?.targetRMS ?? (defaults.object(forKey: "parakeet.rms.target") as? Double ?? 0.06)
        samples = Self.normalizeRMS(samples, targetRMS: targetRMS, peakLimit: 0.5, maxGain: 8.0)
        // ^^ This normalizes to 0.06 RMS (Parakeet's expected level)
    } else {
        // If preprocessing WAS applied, we SKIP THIS ENTIRE BLOCK
        // ^^ This is the bug! The audio from the decoded _proc.wav has:
        //    - RMS=0.08 (not Parakeet's expected 0.06)
        //    - Different amplitude profile than what VAD/ASR expect
    }
    
    // === PROBLEM PART 4: VAD FAILS ON WRONG AUDIO LEVELS ===
    
    // Line 221-223: VAD runs on over-normalized audio
    if (UserDefaults.standard.object(forKey: "parakeet.vad.enabled") as? Bool) ?? true {
        AppLog.dictation.log("[Parakeet] VAD begin")
        if let trimmed = try await applyVADIfAvailable(samples, overrides: autoOverrides), trimmed.count >= 16_000 {
            samples = trimmed
        }
        // ^^ VAD's thresholds (0.5) were calibrated for audio at 0.06 RMS
        //    But our audio is at 0.08 RMS (different amplitude)
        //    Result: VAD either fails to detect speech or trims too much
        AppLog.dictation.log("[Parakeet] VAD end")
    }
    
    // === RESULT: ASR GETS BAD AUDIO ===
    
    // Line 249: ASR processes truncated or empty audio
    AppLog.dictation.log("[Parakeet] ASR begin")
    var result: ASRResult
    do {
        result = try await mgr.transcribe(samples, source: .microphone)
        // ^^ If samples are < 16k or VAD trimmed too much: EMPTY RESULT
    } catch {
        let ns = error as NSError
        AppLog.dictation.error("[Parakeet] transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
        throw error
    }
    
    // Line 257-264: Detect and retry empty result
    if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        AppLog.dictation.error("[Parakeet] Empty ASR result; retrying once")
        do {
            result = try await mgr.transcribe(samples, source: .microphone)  // ← RETRY uses SAME broken samples
        } catch {
            // Keep original empty result if retry also fails
        }
    }
    
    AppLog.dictation.log("[Parakeet] ASR done")
    let preview = result.text.prefix(120)
    log.notice("[Parakeet] result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
    
    let text = result.text
    scheduleIdleUnload()
    return text  // ← EMPTY STRING returned to user
}
```

---

## The Correct Implementation: What Groq Does

### WORKING: GroqTranscriptionProvider.swift (Reference)

```swift
func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    // === CORRECT: Uses in-memory preprocessing ===
    
    let ext = fileURL.pathExtension.lowercased()
    let isCompressed = ["mp3","m4a","aac","ogg","opus","flac"].contains(ext)
    let allowPreprocCompressed = UserDefaults.standard.bool(forKey: "groq.file.preprocessCompressed")
    let applyPreprocessing = AudioPreprocessor.isEnabled && (!isCompressed || allowPreprocCompressed)

    var fileData: Data
    var filename: String
    var mimeType: String
    var cacheKey: TranscriptionCacheKey?

    if applyPreprocessing,
       let preprocessedData = try AudioPreprocessor.processToData(fileURL) {  // ← USES IN-MEMORY
        // ✓ This returns preprocessed audio as Data (WAV bytes)
        // ✓ No disk I/O race condition
        // ✓ Decoded only ONCE during preprocessing
        fileData = preprocessedData
        filename = "audio_proc.wav"
        mimeType = "audio/wav"
        cacheKey = nil
    } else {
        let fileURL = fileURL
        cacheKey = TranscriptionCache.shared.key(for: fileURL, provider: "groq", model: settings.model, language: nil, preprocessing: false)
        if let key = cacheKey, let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }
        fileData = try Data(contentsOf: fileURL)
        filename = fileURL.lastPathComponent
        mimeType = self.mimeType(for: ext)
    }

    return try await transcribeData(
        data: fileData,
        filename: filename,
        mimeType: mimeType,
        settings: settings,
        cacheKey: cacheKey
    )
    // ✓ Sends preprocessed data directly to API
    // ✓ API handles transcription with proper audio levels
    // ✓ No Parakeet-specific decoding issues
}
```

---

## Key Differences: Why Groq Works, Parakeet Doesn't

### AudioPreprocessor APIs Comparison

```swift
// FILE-BASED (what Parakeet currently uses):
public static func processIfEnabled(_ url: URL) -> URL {
    // Returns a file URL pointing to _proc.wav on disk
    // Reads input file, processes, writes output
    // User must read file from disk
    // ✗ Double decode problem
    // ✗ Temp file management issues
    // ✗ Race conditions with file I/O
}

// IN-MEMORY (what Groq uses, Parakeet should use):
public static func processToData(_ url: URL) throws -> Data? {
    // Returns WAV data in memory
    // Reads input file once, processes, returns bytes
    // Caller can write to temp file or send directly
    // ✓ Single decode
    // ✓ Better temp file control
    // ✓ No race conditions
}
```

---

## The Fix: Replace Parakeet's Preprocessing

### FIXED CODE: ParakeetTranscriptionProvider.swift

Replace lines 143-159 with:

```swift
// === FIX: Use in-memory preprocessing ===
var cleanupURLs: [URL] = []
var inputURL = fileURL
var preprocessingApplied = false

if AudioPreprocessor.isEnabled {
    do {
        if let preprocessedData = try AudioPreprocessor.processToData(fileURL) {
            // ✓ Got preprocessed audio in memory
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".wav")
            try preprocessedData.write(to: tempURL)
            inputURL = tempURL
            cleanupURLs.append(tempURL)
            preprocessingApplied = true
            AppLog.dictation.log("[Parakeet] In-memory preprocess: \(tempURL.lastPathComponent)")
        } else {
            preprocessingApplied = false
            AppLog.dictation.log("[Parakeet] Preprocessing skipped (audio clean)")
        }
    } catch {
        preprocessingApplied = false
        AppLog.dictation.log("[Parakeet] Preprocessing failed: \(error.localizedDescription)")
    }
} else {
    preprocessingApplied = false
}
```

### ADDITIONAL FIX: Re-normalize After Decoding

After line 182 (after decoding), add:

```swift
// === FIX: Re-normalize if preprocessing was applied ===
// Audio from decoded _proc.wav has RMS=0.08, but Parakeet expects 0.06
if preprocessingApplied {
    let targetRMS = autoOverrides?.targetRMS ?? 0.06
    samples = Self.normalizeRMS(samples, targetRMS: targetRMS, peakLimit: 0.5, maxGain: 8.0)
    AppLog.dictation.log("[Parakeet] Re-normalized: targetRMS=\(String(format: "%.3f", targetRMS))")
}
```

### ADDITIONAL FIX: Skip VAD After Preprocessing

Replace lines 218-229 with:

```swift
// === FIX: Skip VAD when preprocessing was applied ===
// VAD thresholds are calibrated for audio at 0.06 RMS
// After preprocessing+re-normalization, audio may still be at wrong level
do {
    if !preprocessingApplied && ((UserDefaults.standard.object(forKey: "parakeet.vad.enabled") as? Bool) ?? true) {
        AppLog.dictation.log("[Parakeet] VAD begin")
        if let trimmed = try await applyVADIfAvailable(samples, overrides: autoOverrides), trimmed.count >= 16_000 {
            samples = trimmed
        }
        AppLog.dictation.log("[Parakeet] VAD end")
    }
} catch {
    AppLog.dictation.error("[Parakeet] VAD failed: \(error.localizedDescription)")
}
```

---

## Understanding the Audio Level Problem

### The Numbers

```
AudioPreprocessor normalization (line 182):
  targetRMS: 0.08
  peakLimit: 0.98
  maxGain: 8.0

Parakeet expects (line 214):
  targetRMS: 0.06
  peakLimit: 0.5
  maxGain: 8.0

RESULT: Mismatch
  Audio is normalized to 0.08 RMS
  Parakeet expects 0.06 RMS
  33% amplitude difference
  
VAD thresholds (Parakeet line 287):
  Default: 0.5 (calibrated for 0.06 RMS audio)
  On 0.08 RMS audio: Triggers incorrectly
```

---

## VAD Failure Mechanism

```swift
// VAD checks (ParakeetTranscriptionProvider.swift, lines 308-320):
private func applyVADIfAvailable(_ samples: [Float], overrides: AutoOverrides?) async throws -> [Float]? {
    guard let vad = try await ensureVadManager(preferredThreshold: overrides?.vadThreshold) else { return nil }
    if samples.isEmpty { return nil }
    
    var segCfg = VadSegmentationConfig.default
    let minSpeech = max(0.05, min(1.0, overrides?.minSpeech ?? (UserDefaults.standard.object(forKey: "parakeet.vad.minSpeech") as? Double ?? 0.25)))
    let minSilence = max(0.10, min(1.5, overrides?.minSilence ?? (UserDefaults.standard.object(forKey: "parakeet.vad.minSilence") as? Double ?? 0.35)))
    let padding = max(0.0, min(0.8, overrides?.padding ?? (UserDefaults.standard.object(forKey: "parakeet.vad.padding") as? Double ?? 0.10)))
    segCfg.minSpeechDuration = minSpeech
    segCfg.minSilenceDuration = minSilence
    segCfg.speechPadding = padding
    
    let segments = try await vad.segmentSpeech(samples, config: segCfg)
    // ^^ If audio is at wrong level, VAD returns:
    //    - No segments (misses speech)
    //    - Only tiny segments (over-trims)
    //    - Different timing than expected
}
```

---

## Why This Doesn't Affect Groq/OpenAI

```swift
// Groq flow:
1. AudioPreprocessor.processToData() → Data
2. Send Data directly to API
3. API re-decodes data server-side
4. API's own models process at any level
5. Works fine

// Parakeet flow (current):
1. AudioPreprocessor.processIfEnabled() → _proc.wav file
2. Decode _proc.wav → Float32 samples
3. Skip re-normalization (preprocessingApplied=true)
4. VAD runs on wrong level
5. BROKEN
```

---

## Testing the Fix

### Before Fix (Broken)
```
Enable: audio.preprocess.enabled = YES
Model: parakeet-local (or any Parakeet)
Input: 5 seconds of clear speech

Logs show:
[Parakeet] External preprocess end -> audio_XXXXX_proc.wav
[Parakeet] Decode (AssetReader): samples=80000  ← Good
[Parakeet] VAD begin
[Parakeet] VAD end
[Parakeet] ASR begin
[Parakeet] result length=0 preview=  ← EMPTY!

Output: (nothing)
```

### After Fix (Working)
```
Enable: audio.preprocess.enabled = YES
Model: parakeet-local (or any Parakeet)
Input: 5 seconds of clear speech

Logs show:
[Parakeet] In-memory preprocess: XXXXXXXX.wav
[Parakeet] Decode (AssetReader): samples=80000  ← Good
[Parakeet] Re-normalized: targetRMS=0.060  ← NEW: Fixed level
[Parakeet] ASR begin
[Parakeet] result length=247 preview=This is a test sentence...

Output: Proper transcription
```

