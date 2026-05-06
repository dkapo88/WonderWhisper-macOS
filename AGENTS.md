# Repository Guidelines

Scope: Entire repository  
Owner: WonderWhisper Mac Development Team  
Last updated: November 20, 2025

Note to agents and contributors: Keep this document up to date with any changes.

## Project Structure & Module Organization
WonderWhisper Mac stores SwiftUI sources under `WonderWhisper Mac/`, with views, view models, and helpers grouped by feature. Shared assets live in `WonderWhisper Mac/Assets.xcassets`, while project settings and entitlements sit beside the sources. Unit targets reside in `WonderWhisper MacTests/`, and UI automation lives in `WonderWhisper MacUITests/`. Local build artifacts accumulate under `build/`, and Xcode writes derived data to `DerivedData_WW/`.

### Architecture Overview
Core components: `DictationViewModel` (orchestrates recording → transcription → LLM → insertion), `HistoryStore` & `ConversationHistoryStore` (file-based JSON persistence), provider protocols (`TranscriptionProvider`, `LLMProvider`), and service layers (`AudioRecorder`, `ScreenContextService`, `InsertionService`, `HotkeyManager`). Storage paths: `~/Library/Application Support/WonderWhisper/` for history entries, audio files, screen captures, and conversation state. API keys stored in macOS Keychain via `KeychainService`.

### Microphone Selection
The app includes a persistent microphone selection feature accessible from the sidebar. Users can choose between system default (auto-switches with device changes) or override with a specific microphone. Selection is persisted via `AudioInputSelection` in `AudioDeviceManager.swift` and displayed in `MicrophoneSelectionView.swift`.

## Feature Scope & Providers
- The app ships a single window with seven sidebar tabs: Dictation, Command, Hermes, Vocabulary, History, Microphone, and Settings. Scratchpad, Pro mode, and file transcription workflows have been removed; keep new work within these surfaces.
- Transcription uses Groq Whisper Large V3 Turbo (`groq-streaming`), local Parakeet V3 (`parakeet-local`), Soniox V4 (`soniox-streaming`), OpenRouter speech-to-text models (`openrouter-transcription`), or xAI Grok Speech-to-Text (`xai-stt`). Users pick the engine in **Settings → Transcription engine**; default is Parakeet. Do not reintroduce other providers without explicitly updating this document.
- All LLM requests route through OpenRouter. Additional providers (Groq Chat, Cerebras, Ollama, etc.) are no longer part of the shipping build, so any new integration must be justified and added here.

## Build, Test, and Development Commands
Use `open "WonderWhisper Mac.xcodeproj"` to launch Xcode. For a CLI build, run `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build`. Execute tests with `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test`. To run a single test, use `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test -only-testing:WonderWhisper_MacTests/WonderWhisper_MacTests/testName`. After a successful build, `open build/Debug/WonderWhisper\ Mac.app` launches the latest artifact. The project uses Swift Testing framework (not XCTest) with `@Test` annotations.

## Coding Style & Naming Conventions
Adopt 2-space indentation and keep lines near 100 characters. Name types with PascalCase, functions and variables with camelCase, and prefer `static let` for constants. Match filenames to the primary type (`AudioTranscriber.swift`). Imports should be organized: Foundation first, then Apple frameworks (SwiftUI, AVFoundation, etc.), then `@testable import` in tests. Favor small SwiftUI views, avoid force unwraps (use `guard` or optional chaining), use explicit error handling with `do-catch` or `throws`, and add SwiftUI previews when practical. One primary type per file. Run `swiftformat .` and `swiftlint` before posting changes when tooling is available.

## Testing Guidelines
Tests use Swift Testing framework (not XCTest). Use `@Test` annotation and name functions descriptively: `func audioPreprocessorProducesNormalized16BitOutput()` or `func http2SessionsExposePreferredConfiguration()`. Use `#expect` for assertions, `.disabled("reason")` to skip tests. Target audio, transcription, and provider logic first, then UI flows. Aim for ≥80% coverage on critical modules. Run `xcodebuild ... test` or Xcode's Test action prior to opening a pull request.

## Commit & Pull Request Guidelines
Write imperative, focused commits such as `fix: handle microphone permission denial`. In PRs, describe the approach, link related issues, and flag risks. Include screenshots or GIFs for UI updates and confirm build, tests, and lint all succeed locally. Note any gaps explicitly.

## Security & Configuration Tips
Never commit secrets; use local `.xcconfig` files or Keychain values instead. Review entitlements and Hardened Runtime settings when adding capabilities. Avoid private macOS APIs and audit third-party dependencies periodically.

## Documentation Index
- `datamodel.md` — Canonical data model reference (entities, relationships, invariants, storage). Update this whenever schema/types, field names, relationships, storage paths, or configuration keys change. Include breaking change notes and update tests.

## Agent Workflow & Maintenance
- If you change build/test/run commands, directory layout, coding style/lint rules, or security practices, update this document in the same change.
- If you change the data model, update `datamodel.md` first, then add a brief summary here only if it impacts contributor workflow (e.g., migrations, new storage locations).
- Prefer small, targeted edits and add a one-line entry to the changelog below.
- When in doubt, link to source files/paths instead of duplicating long content.

## External Rules
This repository includes Cursor-specific rules in `.cursor/rules/` covering project structure, Swift style, build/test commands, testing guidelines, security/config, and commit/PR conventions. These rules are automatically applied by Cursor but summarized above for other tools.

## Changelog
- 2026-05-06: Added a Copy button to Hermes response windows.
- 2026-05-06: Added a Hermes Chat/Settings split with current-session chat history in the Hermes tab.
- 2026-05-06: Made Hermes response windows activate independently above other apps.
- 2026-05-06: Added Hermes context toggles for screen text, screenshot images, and clipboard text.
- 2026-05-06: Added current clipboard text context to Hermes voice turns.
- 2026-05-06: Attached active-window screenshots to Hermes voice turns when available.
- 2026-05-06: Added Backslash as a dedicated hotkey option and improved Hermes response Markdown list rendering.
- 2026-05-06: Moved Hermes setup into its own sidebar item with a dedicated hotkey.
- 2026-05-06: Added an HTTP ATS allowance and authenticated remote probe for Hermes API endpoints.
- 2026-05-06: Added Hermes agent voice-loop settings, API client, and response window integration.
- 2026-05-06: Prevented stop-request polling from briefly restoring recording state and replaying chimes.
- 2026-05-06: Improved screen-context OCR accuracy with lossless accurate captures and OCR-noise filtering.
- 2026-05-06: Added full-display OCR preprocessing that uses Apple Intelligence for screen-context terms with a local keyword fallback.
- 2026-05-06: Restored side-specific modifier hotkey detection from the changed key event so right Option taps register promptly.
- 2026-05-06: Disabled the stale legacy recording hotkey listener so only visible prompt activation keys trigger dictation.
- 2026-05-06: Tightened modifier hotkeys so alternate shortcuts with extra modifiers do not trigger WonderWhisper.
- 2026-05-06: Shortened post-insertion hotkey suppression so back-to-back dictation can restart promptly after paste.
- 2026-05-06: Made fast standalone modifier hotkey taps trigger immediately on release instead of requiring the guard delay.
- 2026-05-06: Refined the recording overlay visualizer with quieter metering, modern capsule styling, and compact icon controls.
- 2026-05-05: Updated FluidAudio to 0.14.4 and aligned Parakeet batch transcription with the current async ASR API.
- 2026-05-05: Added OpenRouter Voice transcription engine using `/audio/transcriptions` with selectable STT model IDs.
- 2026-05-05: Added xAI Grok Speech-to-Text cloud transcription engine and `XAI_API_KEY` setting.
- 2026-05-05: Updated Soniox real-time transcription to V4 and reduced finalization/UI update latency.
- 2025-11-20: Added OpenRouter routing priority setting (Auto/Latency/Throughput) to settings; Auto excludes the parameter from API calls.
- 2025-11-20: Active text field capture now skips when selected text exists (to preserve selection), still falls back to clipboard with selection collapse, and logs app/bundle when capture fails.
- 2025-11-14: Added architecture overview, updated testing framework to Swift Testing, clarified import conventions and error handling, corrected sidebar tab count (six tabs), added single-test command.
- 2025-11-13: Added microphone selection feature with persistent device override capability in sidebar menu.
- 2025-11-11: Documented the slimmed-down Dictation/Command surface, Groq/Parakeet transcription engines, and OpenRouter-only LLM stack.
- 2025-10-25: Linked `datamodel.md`, added maintenance notes and agent guidance.
