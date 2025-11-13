# Repository Guidelines

Scope: Entire repository  
Owner: WonderWhisper Mac Development Team  
Last updated: October 25, 2025

Note to agents and contributors: Keep this document up to date with any changes.

## Project Structure & Module Organization
WonderWhisper Mac stores SwiftUI sources under `WonderWhisper Mac/`, with views, view models, and helpers grouped by feature. Shared assets live in `Resources/Assets.xcassets`, while project settings and entitlements sit beside the sources. Unit targets reside in `WonderWhisper MacTests/`, and UI automation lives in `WonderWhisper MacUITests/`. Local build artifacts accumulate under `build/`, and Xcode writes derived data to `DerivedData_WW/`.

### Microphone Selection
The app includes a persistent microphone selection feature accessible from the sidebar. Users can choose between system default (auto-switches with device changes) or override with a specific microphone. Selection is persisted via `AudioInputSelection` in `AudioDeviceManager.swift` and displayed in `MicrophoneSelectionView.swift`.

## Feature Scope & Providers
- The app ships a single window with four tabs: Dictation, Command, History, and Settings. Scratchpad, Pro mode, and file transcription workflows have been removed; keep new work within these surfaces.
- Transcription uses either Groq Whisper Large V3 Turbo (`groq-streaming`) or local Parakeet V3 (`parakeet-local`). Users pick the engine in **Settings → Transcription engine**; default is Parakeet. Do not reintroduce other providers without explicitly updating this document.
- All LLM requests route through OpenRouter. Additional providers (Groq Chat, Cerebras, Ollama, etc.) are no longer part of the shipping build, so any new integration must be justified and added here.

## Build, Test, and Development Commands
Use `open "WonderWhisper Mac.xcodeproj"` to launch Xcode. For a CLI build, run `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build`. Execute tests with `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test`. After a successful build, `open build/Debug/WonderWhisper\ Mac.app` launches the latest artifact.

## Coding Style & Naming Conventions
Adopt 2-space indentation and keep lines near 100 characters. Name types with PascalCase, functions and variables with camelCase, and prefer `static let` for constants. Match filenames to the primary type (`AudioTranscriber.swift`). Favor small SwiftUI views, avoid force unwraps, and add previews when practical. Run `swiftformat .` and `swiftlint` before posting changes when tooling is available.

## Testing Guidelines
Tests use XCTest. Name methods `test_<UnitUnderTest>_<Behavior>()`, e.g. `test_AudioService_handlesPermissionDenied`. Target audio and transcription logic first, then UI flows. Aim for ≥80% coverage on critical modules. Run `xcodebuild ... test` or Xcode's Test action prior to opening a pull request.

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

## Changelog
- 2025-11-13: Added microphone selection feature with persistent device override capability in sidebar menu.
- 2025-11-11: Documented the slimmed-down Dictation/Command surface, Groq/Parakeet transcription engines, and OpenRouter-only LLM stack.
- 2025-10-25: Linked `datamodel.md`, added maintenance notes and agent guidance.
