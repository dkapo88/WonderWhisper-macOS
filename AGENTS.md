# Repository Guidelines

Scope: Entire repository  
Owner: WonderWhisper Development Team
Last updated: July 12, 2026

Note to agents and contributors: Keep this document up to date with any changes.

## Project Structure & Module Organization
WonderWhisper stores SwiftUI sources under `WonderWhisper/`, with views, view models, and helpers grouped by feature. Shared assets live in `WonderWhisper/Assets.xcassets`, while project settings and entitlements sit beside the sources. Unit targets reside in `WonderWhisperTests/`, and UI automation lives in `WonderWhisperUITests/`. Local build artifacts accumulate under `build/`, and Xcode writes derived data to `DerivedData_WW/`.

### Architecture Overview
Core components: `DictationViewModel` (orchestrates recording → transcription → LLM → insertion), `MeetingCoordinator` (orchestrates dual-source meeting capture, streaming transcription, notes, and export), `HistoryStore` & `ConversationHistoryStore` (file-based JSON persistence), provider protocols (`TranscriptionProvider`, `LLMProvider`), and service layers (`AudioRecorder`, `ScreenContextService`, `InsertionService`, `HotkeyManager`). Storage paths remain under `~/Library/Application Support/HermesWhisper/` for compatibility with existing history, meeting audio, screenshots, and conversation state. The bundle identifier and Keychain service likewise retain their Hermes-era values so the WonderWhisper rebrand does not reset macOS permissions, settings, or credentials. API keys are stored in macOS Keychain via `KeychainService`.

### Microphone Selection
The app includes a persistent microphone selection feature accessible from the sidebar. Users can choose between system default (auto-switches with device changes) or override with a specific microphone. Selection is persisted via `AudioInputSelection` in `AudioDeviceManager.swift` and displayed in `MicrophoneSelectionView.swift`.

## Feature Scope & Providers
- The app ships a single window with eleven sidebar tabs: Hermes, Beeper, Meetings, History, Compare, Dictation, Command, Vocabulary, Microphone, Permissions, and Settings. Scratchpad, Pro mode, and file transcription workflows have been removed; keep new work within these surfaces.
- Transcription uses Groq Whisper Large V3 Turbo (`groq-streaming`), local Parakeet V3 (`parakeet-local`), Soniox V5 (`soniox-streaming`), OpenRouter speech-to-text models (`openrouter-transcription`), or xAI Grok Speech-to-Text (`xai-stt`). Users pick the engine in **Settings → Transcription engine**; default is Parakeet. Do not reintroduce other providers without explicitly updating this document.
- Meetings retain separate microphone and system-audio capture tracks. System audio comes from a
  private Core Audio process tap before output volume and device routing, while ScreenCaptureKit
  supplies the selected microphone. Parakeet Unified remains the free on-device default with
  source-specific inference. Soniox V5 is an opt-in cloud beta whose default mode normalizes
  variable capture callbacks into fixed 100 ms source frames,
  timestamp-aligns both sources, uses Accelerate-backed adaptive system-audio echo reduction,
  and sends one mixed WebSocket with speaker metadata for approximately $0.12 per meeting hour. A
  two-WebSocket source-separated mode remains available as a fallback at approximately $0.24 per hour. Audio
  is retained as bounded one-minute CAF segments under `Meetings/<uuid>/`. Manual sessions capture
  all Mac system audio; automatically detected sessions restrict capture to the detected
  application scope. Trigger apps are editable: Slack and supported browsers retain strict
  Huddle/Google Meet evidence, while explicitly configured standalone apps may start on microphone
  use. Automatic starts remain strict, while an active meeting tolerates browser
  title and individual audio-signal dropouts before a two-minute confirmed stop. Soniox non-final
  text is transient UI only; Stop ends local capture immediately while final tokens, notes, and
  export finish in a session-scoped background task. Failed live-stream tails are recovered from
  retained CAF segments with local Parakeet Unified; failed mixed transcripts are replaced by recovery
  from both raw source tracks. Mixed capture runs on a dedicated serial ingestion worker so Soniox
  token and UI callbacks cannot starve audio delivery. If live ingestion falls behind, transcription pauses and is recovered
  later while durable audio capture continues uninterrupted. The companion includes a durable Manual notes
  tab backed by an atomically saved local sidecar; those notes remain separate from generated Markdown,
  appear in history and exports, and join the transcript only when cloud-generated notes are opted in.
  Generated notes are cloud opt-in. Optional live
  context uses its own fast OpenRouter model and sends a bounded recent transcript window to extract useful
  subjects at a rate-limited cadence, ranks Markdown locally inside the chosen Obsidian vault, and
  sends only bounded matching excerpts back to OpenRouter in one batched brief request.
- All LLM requests route through OpenRouter. Additional providers (Groq Chat, Cerebras, Ollama, etc.) are no longer part of the shipping build, so any new integration must be justified and added here.

## Build, Test, and Development Commands
Use `open "WonderWhisper.xcodeproj"` to launch Xcode. For a CLI build, run `xcodebuild -project "WonderWhisper.xcodeproj" -scheme "WonderWhisper" -configuration Debug build`. Execute tests with `xcodebuild -project "WonderWhisper.xcodeproj" -scheme "WonderWhisper" -destination 'platform=macOS' test`. To run a single test, use `xcodebuild -project "WonderWhisper.xcodeproj" -scheme "WonderWhisper" -destination 'platform=macOS' test -only-testing:WonderWhisperTests/WonderWhisperTests/testName`. After a successful script build, `open build/Build/Products/Debug/WonderWhisper.app` launches the latest artifact. The project uses Swift Testing framework (not XCTest) with `@Test` annotations.

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
- 2026-07-12: Stopped forcing reasoning off for generated meeting notes so models with mandatory provider-managed reasoning remain compatible.
- 2026-07-12: Rebranded the macOS app, project, targets, build products, documentation, and release tooling from HermesWhisper back to WonderWhisper while retaining the Hermes-era bundle identifier and local storage path for upgrade compatibility.
- 2026-07-12: Hardened mixed meeting capture across audio-route changes, bounded live-transcription backlog, and preserved partial transcripts when raw recovery is incomplete.
- 2026-07-12: Replaced ScreenCaptureKit system-audio meeting capture with a private Core Audio process tap so muted speakers and headphone route changes do not remove outgoing audio, and preserved forward microphone clock gaps after route changes.
- 2026-07-12: Normalized variable ScreenCaptureKit meeting callbacks into fixed 100 ms frames so queue capacity tracks audio time rather than unstable callback counts.
- 2026-07-12: Isolated mixed Soniox audio ingestion from transcript/UI callbacks to prevent live transcription starvation after sustained token activity.
- 2026-07-12: Vectorized single-stream meeting echo cancellation and made live-transcription backlog degrade to raw-audio recovery without stopping the recording.
- 2026-07-12: Added an experimental echo-reduced single-stream Soniox meeting path with speaker labels, half-rate cloud usage, raw-source recovery, and a separate-stream fallback.
- 2026-07-12: Removed the meeting title from the compact companion toolbar so live timing and recording controls remain legible at the default width.
- 2026-07-12: Refined the meeting companion toolbar with clearer title hierarchy, compact live timing, and balanced minimize and stop controls.
- 2026-07-12: Made the minimized meeting bubble independently draggable without restoring, and retained its custom screen position across minimize cycles.
- 2026-07-12: Removed session-level meeting companion Hide and enlarged the sole Minimize control's hit target.
- 2026-07-12: Split the minimized meeting bubble into its own panel so restoring reveals the untouched full-size companion frame.
- 2026-07-12: Added a reversible minimized meeting-companion bubble with live dual-source audio visualization while preserving session-level Hide.
- 2026-07-12: Split the Obsidian vault root used for live context from the nested meeting-summary export folder.
- 2026-07-12: Made the full Meeting settings header toggle its expanded state.
- 2026-07-12: Replaced meeting AI model text fields with clearly labelled pickers sourced from OpenRouter favorites.
- 2026-07-11: Added a compact durable Manual notes companion tab, history/export display, and final-summary evidence alongside the transcript.
- 2026-07-11: Ported the alternate meeting HUD's compact translucent presentation and trigger-app UX, added menu-bar controls, automatic-start Keep/Discard, meeting-safe dictation muting, separate context/final-note models, local CAF tail recovery, generated titles, and Markdown/audio conveniences.
- 2026-07-11: Prevented Meet detector flapping from stopping and restarting live calls, added transient Soniox non-final captions, fixed the end-of-audio keepalive race, and moved transcript finalization behind an immediate meeting stop.
- 2026-07-11: Reduced automatic meeting confirmation to two one-second observations, replaced the blanket post-meeting cooldown with same-call suppression, and added an opt-in dual-stream Soniox V5 meeting transcription engine while retaining Parakeet as the default.
- 2026-07-11: Resolved Dia's anonymous Arc-branded audio helpers with `proc_pidpath`, added rate-limited subject-aware Obsidian retrieval and batched context briefs, surfaced ticket links and vault errors, suppressed timestamp-aligned system-audio echo from rendered microphone transcripts, and relabeled transcript sources as Microphone/System audio rather than implying speaker diarization.
- 2026-07-10: Fixed equal-timestamp Parakeet token ordering, changed Google Meet detection to a matching foreground or background browser tab plus microphone activity, added detector diagnostics, and made live Obsidian ticket matching tolerate spaced initials and identifiers found in note filenames.
- 2026-07-10: Added Meetings with durable dual-source system/microphone capture, streaming Parakeet Unified transcription, source-separated transcripts, automatic Slack Huddle and Google Meet detection, a floating transcript/context companion, generated notes, and Obsidian Markdown export.
- 2026-06-21: Bumped FluidAudio to 0.15.4 and added Parakeet Unified 0.6B (English, offline-batch via `UnifiedAsrManager`) as a user-selectable on-device model alongside v3 (multilingual); dropped v2. Model choice persists under `parakeet.version` ("unified"/"v3", default unified) and is picked in the Parakeet settings section.
- 2026-06-17: Routed F5 prompt hotkeys through the event-tap path so bare F5 and function-row F5 variants can trigger dictation.
- 2026-06-17: Updated Soniox real-time transcription to V5 and mapped legacy V4 model settings to the V5 default.
- 2026-06-01: Made Beeper response monitoring ambient for the configured chat, surfacing new incoming replies even when the user replies directly in Beeper.
- 2026-05-31: Added a dedicated Beeper voice-send integration with chat ID storage, token storage, configurable shortcut, copied-text context, bounded response polling, and experimental WebSocket-first monitoring.
- 2026-05-21: Added LLM-only history reprocessing for real-time transcripts and a Compare sidebar tab for favorite-model output and timing tests.
- 2026-05-21: Tightened the default medium cleanup prompt body for brevity, voice preservation, and stronger list extraction.
- 2026-05-20: Added an OpenRouter reasoning setting for omitting, disabling, or minimizing model reasoning.
- 2026-05-20: Stopped forcing OpenRouter reasoning parameters by default and preserved failed LLM attempt timing.
- 2026-05-20: Added a separate xAI Grok STT streaming engine with ordered audio draining and async xAI fallback.
- 2026-05-20: Increased streaming PCM conversion buffer capacity to prevent truncated live audio frames.
- 2026-05-20: Made Soniox streaming accept and buffer audio immediately during WebSocket startup.
- 2026-05-20: Added xAI STT keyterm injection, a transcription language selector, and deterministic vocabulary near-miss corrections.
- 2026-05-19: Added reusable dictation prompt templates with save, edit, delete, and built-in defaults.
- 2026-05-19: Added a Permissions sidebar tab for checking and prompting required macOS permissions.
- 2026-05-16: Replaced unsigned preview install notes with signed notarized release install guidance.
- 2026-05-09: Documented unsigned preview install instructions for GitHub release DMGs.
- 2026-05-09: Expanded the README with app overview, dictation, Command Mode, Hermes setup, context, timeout, and prompt-tag documentation.
- 2026-05-09: Updated the HermesWhisper README header image asset.
- 2026-05-09: Updated the menu bar icon, synced menu microphone selection, added voice-model menu controls, and showed pending Hermes response counts in the status item.
- 2026-05-09: Restored the macOS app icon to the original WonderWhisper icon.
- 2026-05-09: Added a copyable Hermes setup prompt to help first-time users collect API URL, key, conversation prefix, and profile settings.
- 2026-05-09: Updated fresh-install defaults for Hermes URL, timeouts, hotkeys, screen context toggles, and OpenRouter favorites.
- 2026-05-09: Removed the stale menu-bar API Keys action and limited Keychain reads/migration to non-interactive current or legacy app-scoped lookups.
- 2026-05-09: Renamed the app, project, module, bundle identifiers, docs, and runtime storage identity to HermesWhisper with legacy local data/keychain migration.
- 2026-05-09: Added a Hermes agent profile setting that maps to the API model and validates against `/v1/models`.
- 2026-05-09: Replaced Hermes request timeout arrows with a whole-minute text field.
- 2026-05-09: Added typed Hermes replies from the chat tab and response windows.
- 2026-05-09: Exposed Hermes copied text timeout as a configurable settings value.
- 2026-05-09: Added clickable Hermes clipboard context preview tags in chat history.
- 2026-05-08: Fixed bounded screen-capture waits, display-aware overlays, Groq streaming upload cleanup, and transcription cache stat locking.
- 2026-05-08: Made Hermes response-window foreground highlighting react immediately on mouse down.
- 2026-05-08: Removed clipped SwiftUI shadow artifact from Hermes response windows.
- 2026-05-08: Cleared Hermes reply recording state when a dictation is cancelled.
- 2026-05-08: Removed redundant Hermes chat intro copy and tightened the tab's top spacing.
- 2026-05-08: Made the Hermes chat tab fill and resize with the available window space.
- 2026-05-08: Restored Hermes Markdown block rendering and made formatted copy preserve rich/plain structure.
- 2026-05-08: Added Hermes LLM session titles, optional Hermes post-processing, clearer response-window focus/reply state, and raw/formatted copy controls.
- 2026-05-07: Restored Hermes response-window minimize by hiding the custom panel directly.
- 2026-05-07: Moved Hermes to the top of the main sidebar above History.
- 2026-05-07: Made Hermes response windows larger by default and manually resizable.
- 2026-05-07: Limited Hermes clipboard context to text copied within one minute before recording start.
- 2026-05-07: Added Hermes Active/Archive session lifecycle with confirmed clear-active and local delete actions.
- 2026-05-07: Recovered stale waiting Hermes sessions after app restart and made waiting sessions interruptible/replyable.
- 2026-05-07: Hid inactive native traffic-light controls on Hermes response panels in favor of the custom window buttons.
- 2026-05-07: Added persistent multi-session Hermes tasks with per-session chat, response windows, replies, and close/minimize controls.
- 2026-05-07: Reduced recording overlay visualizer sensitivity without changing captured audio.
- 2026-05-07: Anchored the Hermes chat tab to the latest messages when opened.
- 2026-05-07: Kept the Hermes response window visible while recording an immediate reply.
- 2026-05-07: Disabled OpenRouter reasoning by default for LLM post-processing requests.
- 2026-05-06: Added persistent Hermes chat history capped to the latest 50 messages by default.
- 2026-05-06: Raised the Hermes request timeout cap to 30 minutes.
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
- 2026-05-06: Tightened modifier hotkeys so alternate shortcuts with extra modifiers do not trigger HermesWhisper.
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
