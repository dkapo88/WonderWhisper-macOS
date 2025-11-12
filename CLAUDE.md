# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WonderWhisper Mac is a voice dictation and AI assistant application for macOS that combines local and cloud-based transcription (Parakeet V3 local or Groq Whisper Turbo) with OpenRouter LLM processing. The app provides a single window with four tabs: Dictation, Command, History, and Settings.

**Key Technologies:**
- Swift/SwiftUI for the macOS application
- Parakeet V3 (local, on-device transcription) or Groq Whisper Large V3 Turbo (cloud)
- OpenRouter for LLM processing
- FluidAudio framework for audio processing
- Local file-based history storage in `~/Library/Application Support/WonderWhisper/`

## Common Development Commands

### Building and Running
```bash
# Open in Xcode
open "WonderWhisper Mac.xcodeproj"

# Build (Debug)
xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug -derivedDataPath build/ build

# Or use the build script
./Scripts/build.sh

# Run the app after building
./Scripts/run.sh

# Build and run in one command
./Scripts/build-and-run.sh

# Build artifacts are located in: build/Build/Products/Debug/WonderWhisper Mac.app
```

### Testing
```bash
# Run all tests
xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test

# Test file structure:
- WonderWhisper MacTests/ (Unit tests)
- WonderWhisper MacUITests/ (UI tests)
```

### Code Quality (if configured)
```bash
# Format Swift code
swiftformat .

# Lint Swift code
swiftlint
```

## Code Architecture

### Directory Structure
```
WonderWhisper Mac/              # Main app source (46 Swift files)
├── AppConfig.swift             # API endpoints and app-wide constants
├── DictationViewModel.swift    # Core view model (87KB, state management)
├── DictationController.swift   # Coordinates dictation workflow
├── AudioRecorder.swift         # Audio capture and preprocessing
├── Transcription Providers:
│   ├── GroqStreamingProvider.swift      # Cloud streaming transcription
│   ├── GroqTranscriptionProvider.swift  # Cloud batch transcription
│   └── ParakeetTranscriptionProvider.swift  # Local transcription
├── LLM Providers:
│   └── OpenRouterLLMProvider.swift  # OpenRouter API client
├── Storage:
│   ├── HistoryStore.swift      # File-based history storage
│   ├── ConversationHistoryStore.swift  # Conversation persistence
│   └── KeychainService.swift   # Secure API key storage
├── Services:
│   ├── ScreenCaptureService.swift    # Screen context capture
│   ├── ScreenContextService.swift    # Screen OCR/analysis
│   ├── HotkeyManager.swift           # Global hotkey handling
│   └── InsertionService.swift        # Text insertion into apps
└── UI Views:
    ├── ContentView.swift              # Main window
    ├── SimpleModeSettingsView.swift   # Settings UI
    └── SimpleHistoryView.swift        # History UI

WonderWhisper MacTests/         # Unit tests
WonderWhisper MacUITests/       # UI automation tests
Scripts/                        # Build and maintenance scripts
```

### Key Data Models

The app uses several core entities defined in `datamodel.md`:

**1. HistoryEntry** (`WonderWhisper Mac/HistoryEntry.swift`)
- Persisted dictation records with transcripts, output, audio, and screen context
- Stored in `~/Library/Application Support/WonderWhisper/History/entries/`
- Includes metadata: app name, timing, LLM prompts, performance metrics

**2. PromptConfiguration** (`WonderWhisper Mac/PromptConfiguration.swift`)
- User-defined templates for processing voice input
- Supports conversation mode, model overrides, context capture settings
- Stored in UserDefaults as JSON

**3. SimplePromptSettings** (`WonderWhisper Mac/SimpleModeModels.swift`)
- Simplified configuration for Dictation and Command modes
- Contains formatting rules and context settings
- Separate from complex PromptConfiguration but rendered similarly

### Core Providers

**TranscriptionProvider Protocol** - Two implementations:
- `ParakeetTranscriptionProvider`: On-device transcription using Parakeet V3 (private, fast)
- `GroqStreamingProvider`: Cloud-based chunked streaming (6.0s chunks, 1.2s overlap)

**LLMProvider Protocol** - Single implementation:
- `OpenRouterLLMProvider`: Routes to various OpenRouter models (default: moonshotai/kimi-k2-0905)

### Storage Locations

**Application Support:**
```
~/Library/Application Support/WonderWhisper/
├── History/
│   ├── entries/           # JSON history files
│   ├── audio/             # M4A/WAV recordings
│   └── images/            # Screen captures
└── ConversationHistory/   # Per-prompt conversation context
```

**UserDefaults Keys:**
- `simpleMode.voiceEngine`: `"parakeet-local"` or `"groq-streaming"`
- `simpleMode.selectedModel`: OpenRouter model ID
- `prompts.library`: Array of PromptConfiguration
- `llm.model`: Active LLM model
- `transcription.model`: Active transcription model

**Keychain (secure):**
- `GROQ_API_KEY`
- `OPENROUTER_API_KEY`

## Development Conventions

### Swift Style (from `.cursor/rules/002-swift-style.mdc`)
- **Indentation**: 2 spaces
- **Line length**: ~100 characters
- **Naming**: `PascalCase` for types, `camelCase` for methods/variables
- **Constants**: `static let`
- **Files**: One primary type per file, filename matches type
- **UI**: Small, composable SwiftUI views with previews
- **Error handling**: Explicit, avoid force unwrapping

### Project Structure (from `.cursor/rules/001-project-structure.mdc`)
- SwiftUI sources under `WonderWhisper Mac/`
- Views, view models, and helpers grouped by feature
- Shared assets in `Resources/Assets.xcassets`
- Project settings beside sources
- Tests in `WonderWhisper MacTests/` and `WonderWhisper MacUITests/`

## Key Features

### Simple Mode (Primary UI)
The app ships with two simple modes:
- **Dictation**: Voice-to-text with formatting rules
- **Command**: Selected-text aware assistant mode (OCR context)

Both modes use:
- Rules-based text replacement
- Screen/clipboard/selected text context (configurable)
- Hotkey activation (push-to-talk or toggle)
- Optional LLM processing via OpenRouter

### Streaming (from `WonderWhisper Mac/Streaming/README.md`)
Groq streaming uses multi-second chunking with overlap for improved accuracy:
- **Default**: 6.0s chunks with 1.2s overlap
- Sequential uploads (max 1 in-flight by default)
- Punctuation-insensitive token overlap (up to 24 tokens)
- **Tunable via UserDefaults**:
  - `groq.stream.chunkSeconds` (2.0–15.0, default 6.0)
  - `groq.stream.overlapSeconds` (0.5–4.0, default 1.2)
  - `groq.stream.maxInflight` (1–3, default 1)
  - `groq.stream.promptTrailChars` (80–600, default 200)
  - `groq.stream.warmupSeconds` (0.15–0.60, default 0.30)

## Security & Configuration

**API Keys**: Never commit secrets. Store in:
- Keychain at runtime via `KeychainService`
- Local `.xcconfig` files for development

**Entitlements**: Review `WonderWhisper_Mac.entitlements` and Hardened Runtime settings when adding capabilities.

**Third-party dependencies**: Audit periodically, avoid private macOS APIs.

## Testing Guidelines

- **Naming**: `test_<UnitUnderTest>_<Behavior>()`
- **Focus**: Audio/transcription logic first, then UI flows
- **Target**: ≥80% coverage on critical modules
- Run tests before opening PRs

## Provider Management

The app uses a **Provider Cache Pattern**:
- HTTP clients cached by configuration signature
- Separate cache keys for streaming vs. batch modes
- Debounced updates (500ms) on settings changes
- Lazy initialization (providers created only when needed)

## Documentation References

- **`AGENTS.md`**: Repository guidelines, coding style, commit guidelines
- **`datamodel.md`**: Complete data model documentation with ER diagrams (661 lines)
- **`.cursor/rules/`**: Cursor-specific development rules
  - `001-project-structure.mdc`: File organization
  - `002-swift-style.mdc`: Swift coding conventions
  - `003-build-and-test.mdc`: Build/test commands
  - `004-testing-guidelines.mdc`: Testing practices
  - `005-security-config.mdc`: Security guidelines
  - `006-commit-pr.mdc`: Commit/PR guidelines

## Build Configurations

- **Debug**: Development builds with logging
- **Release**: Production builds
- **DerivedData**: Stored in `build/` directory
- Use absolute paths in all commands

## Important Notes

1. **Two-tier UI**: Simple Mode (Dictation/Command tabs) is the primary interface. Advanced pro mode features were removed.

2. **Provider choice**: Users select between Parakeet V3 (local, default) and Groq streaming in Settings.

3. **LLM-only**: All LLM requests use OpenRouter. Other providers (Groq Chat, Cerebras, Ollama) are not in the shipping build.

4. **File-based history**: Uses JSON files with pagination (20 entries at a time) for performance.

5. **Conversation isolation**: Each prompt maintains separate conversation history. Provider changes clear history automatically.

6. **Persistence model**: History entries are individual JSON files, not a database. All I/O operations are asynchronous.

7. **Build scripts**: Use Scripts/build.sh and Scripts/run.sh for consistent builds, or open in Xcode directly.

## Troubleshooting

**Build issues**: Check `build/` directory for artifacts. Clear with `rm -rf build/` if needed.

**Runtime issues**: Check logs in `~/Library/Logs/WonderWhisper/` or Console.app.

**API issues**: Verify Keychain has required API keys (GROQ_API_KEY, OPENROUTER_API_KEY).

**Permission issues**: Ensure microphone access granted in System Settings → Privacy & Security → Microphone.
