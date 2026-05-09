# Claude Code Instructions

## Project Overview
HermesWhisper is a macOS dictation app built with SwiftUI. It provides voice-to-text transcription via Groq Whisper or local Parakeet, with optional LLM processing through OpenRouter.

## Quick Reference

### Build & Run
```bash
# Build
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build

# Run tests
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -destination 'platform=macOS' test

# Run single test
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -destination 'platform=macOS' test -only-testing:HermesWhisperTests/TestClass/testName

# Launch script-built app
open build/Build/Products/Debug/HermesWhisper.app
```

### Key Directories
- `HermesWhisper/` - Main app source (SwiftUI views, view models, services)
- `HermesWhisperTests/` - Unit tests (Swift Testing framework)
- `Scripts/` - Build helper scripts

### Core Architecture
- `DictationViewModel` - Main orchestrator (recording → transcription → LLM → insertion)
- `AudioRecorder` - Audio capture
- `ScreenContextService` - Screen capture for context
- `InsertionService` - Text insertion into active apps
- `HotkeyManager` / `PromptHotkeyManager` - Global keyboard shortcuts
- Providers: `GroqTranscriptionProvider`, `ParakeetTranscriptionProvider`, `OpenRouterLLMProvider`

## Coding Standards

### Swift Style
- 2-space indentation
- ~100 character line limit
- PascalCase for types, camelCase for functions/variables
- One primary type per file, filename matches type
- Avoid force unwraps; use `guard` or optional chaining
- Use `do-catch` or `throws` for error handling

### Import Order
1. Foundation
2. Apple frameworks (SwiftUI, AVFoundation, etc.)
3. Third-party (if any)
4. `@testable import` in tests only

### Testing
- Uses Swift Testing framework (`@Test` annotation, `#expect` assertions)
- NOT XCTest
- Descriptive function names: `func audioPreprocessorProducesNormalized16BitOutput()`

## Commit Guidelines
- Imperative mood: `fix: handle microphone permission denial`
- Never add Claude as co-author or reference Claude in commit messages

## Important Files
- `AGENTS.md` - Detailed project guidelines and changelog
- `datamodel.md` - Data model reference

## Security
- API keys stored in macOS Keychain via `KeychainService`
- Never commit secrets
- User data in `~/Library/Application Support/HermesWhisper/`
- First launch after the app rename copies existing local data from the legacy `WonderWhisper` Application Support directory when needed.
