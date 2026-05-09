# HermesWhisper Open Source Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename WonderWhisper to HermesWhisper thoroughly, add open-source licensing/docs, and prepare the repository for public GitHub release.

**Architecture:** Treat this as a staged migration with commit boundaries: first preserve the current Hermes feature work, then rename product/build identifiers, then migrate local storage safely, then clean publication artifacts, then add the MIT license and README. The app should keep existing user data and Keychain secrets available after the rename through explicit compatibility fallbacks.

**Tech Stack:** macOS SwiftUI, Xcode project/schemes, Swift Testing, UserDefaults, Application Support file storage, macOS Keychain, Markdown documentation.

---

## File Structure

- Modify: `WonderWhisper Mac.xcodeproj/project.pbxproj`
  Rename app/test/UI test targets, product names, bundle identifiers, test hosts, source group paths, entitlements path, and bridging header path.
- Rename: `WonderWhisper Mac.xcodeproj` -> `HermesWhisper.xcodeproj`
- Rename: `WonderWhisper Mac/` -> `HermesWhisper/`
- Rename: `WonderWhisper MacTests/` -> `HermesWhisperTests/`
- Rename: `WonderWhisper MacUITests/` -> `HermesWhisperUITests/`
- Rename: `WonderWhisper Mac-Info.plist` -> `HermesWhisper-Info.plist`
- Rename: `WonderWhisper Mac/WonderWhisper_MacApp.swift` -> `HermesWhisper/HermesWhisperApp.swift`
- Rename: `WonderWhisper Mac/WonderWhisper_Mac.entitlements` -> `HermesWhisper/HermesWhisper.entitlements`
- Rename: `WonderWhisper Mac/WonderWhisper-Mac-Bridging-Header.h` -> `HermesWhisper/HermesWhisper-Bridging-Header.h`
- Modify: `HermesWhisper/AppConfig.swift`
  Update public app name, bundle/subsystem constants, OpenRouter title/referer, default Hermes conversation prefix, and add legacy constants for migration.
- Modify: `HermesWhisper/HistoryStore.swift`, `HermesWhisper/ConversationHistoryStore.swift`, `HermesWhisper/HermesChatHistoryStore.swift`, `HermesWhisper/HermesChatSession.swift`
  Move Application Support storage to `~/Library/Application Support/HermesWhisper`, with read/migration fallback from `WonderWhisper`.
- Modify: `HermesWhisper/KeychainService.swift`
  Change Keychain service to the new bundle namespace while supporting reads from the old service if a secret is missing.
- Modify: app UI files with visible product names: `ContentView.swift`, `MenuBarController.swift`, `VocabularyView.swift`, `MicrophoneSelectionView.swift`, `HermesAgentView.swift`, `SimplePromptEditorView.swift`, `ScreenContextPreprocessor.swift`, `DictationViewModel.swift`.
- Modify: logging files using old subsystem strings: `Log.swift`, `DictationController.swift`, `GroqHTTPClient.swift`, `GroqTranscriptionProvider.swift`, `OpenRouterHTTPClient.swift`, `OpenRouterLLMProvider.swift`, `OpenRouterTranscriptionProvider.swift`, `ParakeetTranscriptionProvider.swift`, `XAIHTTPClient.swift`, `XAITranscriptionProvider.swift`.
- Modify: test imports and class names in `HermesWhisperTests/` and `HermesWhisperUITests/`.
- Modify: `Scripts/build.sh`, `Scripts/run.sh`, `Scripts/build-and-run.sh`.
- Modify: `.gitignore`
  Ignore generated `*.xcresult`, `logs/`, local assistant config directories, and transient Xcode artifacts.
- Remove from git: tracked generated artifacts under `build.xcresult/` and `logs/`.
- Create: `LICENSE`
  MIT license with recommended copyright line `Copyright (c) 2026 Dane Kapoor`.
- Create or replace: `README.md`
  Public-facing installation, setup, feature, privacy, and development guide.
- Modify: `AGENTS.md`, `CLAUDE.md`, `datamodel.md`
  Update repository guidance and data model references after the rename.

## Task 0: Preserve Current Hermes Work

**Files:**
- Stage existing Hermes feature files only after reviewing their diff.

- [ ] **Step 1: Review current dirty state**

Run:

```bash
git status --short --branch
git diff --stat
```

Expected: dirty state includes recent Hermes profile, typed reply, clipboard, response-window, and settings work.

- [ ] **Step 2: Build current state before rename**

Run:

```bash
xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit current feature work before rename**

Run:

```bash
git add AGENTS.md datamodel.md \
  "WonderWhisper Mac/ClipboardContextMonitor.swift" \
  "WonderWhisper Mac/DictationViewModel.swift" \
  "WonderWhisper Mac/HermesAgentClient.swift" \
  "WonderWhisper Mac/HermesAgentView.swift" \
  "WonderWhisper Mac/HermesChatMessage.swift" \
  "WonderWhisper Mac/HermesResponseWindowController.swift" \
  "WonderWhisper MacTests/HermesAgentClientTests.swift" \
  "WonderWhisper MacTests/HermesChatHistoryStoreTests.swift" \
  "WonderWhisper MacTests/HermesClipboardContextPolicyTests.swift" \
  "WonderWhisper MacTests/HermesResponseWindowLifecycleTests.swift"
git commit -m "feat: refine Hermes session settings and replies"
```

Expected: a commit containing the current Hermes work. Do not stage unrelated performance/debug files unless intentionally included.

## Task 1: Rename Build Product And Project

**Files:**
- Modify: `WonderWhisper Mac.xcodeproj/project.pbxproj`
- Rename: project, source, test, UI test, plist, entitlements, bridging header, and app entrypoint files.

- [ ] **Step 1: Rename folders and top-level Xcode files**

Run:

```bash
git mv "WonderWhisper Mac" HermesWhisper
git mv "WonderWhisper MacTests" HermesWhisperTests
git mv "WonderWhisper MacUITests" HermesWhisperUITests
git mv "WonderWhisper Mac-Info.plist" HermesWhisper-Info.plist
git mv "WonderWhisper Mac.xcodeproj" HermesWhisper.xcodeproj
git mv "HermesWhisper/WonderWhisper_MacApp.swift" "HermesWhisper/HermesWhisperApp.swift"
git mv "HermesWhisper/WonderWhisper_Mac.entitlements" "HermesWhisper/HermesWhisper.entitlements"
git mv "HermesWhisper/WonderWhisper-Mac-Bridging-Header.h" "HermesWhisper/HermesWhisper-Bridging-Header.h"
```

Expected: `git status --short` shows renames, not delete/add churn for these paths.

- [ ] **Step 2: Update Xcode project names and build settings**

Use a structured script or careful editor pass to replace:

```text
WonderWhisper Mac -> HermesWhisper
WonderWhisper MacTests -> HermesWhisperTests
WonderWhisper MacUITests -> HermesWhisperUITests
WonderWhisper_Mac -> HermesWhisper
com.slumdev88.wonderwhisper.WonderWhisper-Mac -> com.danekapoor.hermeswhisper
com.slumdev88.wonderwhisper.WonderWhisper-MacTests -> com.danekapoor.hermeswhisper.tests
com.slumdev88.wonderwhisper.WonderWhisper-MacUITests -> com.danekapoor.hermeswhisper.uitests
WonderWhisper Mac-Info.plist -> HermesWhisper-Info.plist
WonderWhisper_Mac.entitlements -> HermesWhisper.entitlements
WonderWhisper-Mac-Bridging-Header.h -> HermesWhisper-Bridging-Header.h
```

Expected: `xcodebuild -list -project HermesWhisper.xcodeproj` lists the renamed app scheme and targets.

- [ ] **Step 3: Update Swift app entrypoint**

Change `HermesWhisper/HermesWhisperApp.swift` type name:

```swift
@main
struct HermesWhisperApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appDelegate.viewModel)
    }
  }
}
```

Expected: no `WonderWhisper_MacApp` type remains.

- [ ] **Step 4: Verify rename build**

Run:

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit build rename**

Run:

```bash
git add -A
git commit -m "refactor: rename app to HermesWhisper"
```

Expected: one rename-focused commit.

## Task 2: Runtime Naming, Storage, And Keychain Migration

**Files:**
- Modify: `HermesWhisper/AppConfig.swift`
- Modify: `HermesWhisper/HistoryStore.swift`
- Modify: `HermesWhisper/ConversationHistoryStore.swift`
- Modify: `HermesWhisper/HermesChatHistoryStore.swift`
- Modify: `HermesWhisper/HermesChatSession.swift`
- Modify: `HermesWhisper/KeychainService.swift`
- Modify: logging and visible UI files listed above.

- [ ] **Step 1: Add app identity constants**

Add constants in `AppConfig.swift`:

```swift
static let appDisplayName = "HermesWhisper"
static let legacyAppDisplayName = "WonderWhisper"
static let appSupportDirectoryName = "HermesWhisper"
static let legacyAppSupportDirectoryName = "WonderWhisper"
static let bundleIdentifier = "com.danekapoor.hermeswhisper"
static let legacyBundleIdentifier = "com.slumdev88.wonderwhisper.WonderWhisper-Mac"
static let defaultHermesConversationName = "hermeswhisper-mac"
static let openrouterTitle = "HermesWhisper"
static let openrouterReferer = "https://github.com/danekapoor/HermesWhisper"
```

Expected: visible strings can reference constants instead of duplicating old names.

- [ ] **Step 2: Migrate Application Support directories**

Create a helper in a small support file such as `HermesWhisper/AppStoragePaths.swift`:

```swift
import Foundation

enum AppStoragePaths {
  static func appSupportRoot() -> URL {
    let fm = FileManager.default
    let appSupport = (try? fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? URL(fileURLWithPath: "/tmp")

    let newRoot = appSupport.appendingPathComponent(AppConfig.appSupportDirectoryName, isDirectory: true)
    let oldRoot = appSupport.appendingPathComponent(AppConfig.legacyAppSupportDirectoryName, isDirectory: true)

    if !fm.fileExists(atPath: newRoot.path), fm.fileExists(atPath: oldRoot.path) {
      try? fm.copyItem(at: oldRoot, to: newRoot)
    }

    try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
    return newRoot
  }
}
```

Then replace direct `WonderWhisper` Application Support construction with `AppStoragePaths.appSupportRoot()`.

Expected: existing users retain history, audio, screenshots, and Hermes sessions after upgrade.

- [ ] **Step 3: Add Keychain fallback**

Update `KeychainService` to read from the new service first and old service second:

```swift
private static let service = AppConfig.bundleIdentifier
private static let legacyService = AppConfig.legacyBundleIdentifier
```

In `getSecret(forKey:)`, try `service`; if missing, try `legacyService`.

Expected: existing saved provider keys still work after the bundle/service rename.

- [ ] **Step 4: Update visible product strings**

Replace user-facing `WonderWhisper` references with `HermesWhisper` in:

```text
ContentView.swift
MenuBarController.swift
VocabularyView.swift
MicrophoneSelectionView.swift
HermesAgentView.swift
SimplePromptEditorView.swift
ScreenContextPreprocessor.swift
WonderWhisper Mac-Info.plist -> HermesWhisper-Info.plist
```

Expected: menu bar tooltip, quit menu, navigation title, microphone permission prompt, and explanatory copy use HermesWhisper.

- [ ] **Step 5: Update logging subsystems and queues**

Replace old subsystem strings with `AppConfig.bundleIdentifier`, and update queue labels from `com.wonderwhisper.*` to `com.hermeswhisper.*`.

Expected: `rg "com\\.slumdev88\\.wonderwhisper|com\\.wonderwhisper|WonderWhisper" HermesWhisper HermesWhisperTests HermesWhisperUITests` only returns intentional legacy migration constants.

- [ ] **Step 6: Build and commit runtime migration**

Run:

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build
git add -A
git commit -m "refactor: migrate runtime identity to HermesWhisper"
```

Expected: build succeeds and migration code is isolated in its own commit.

## Task 3: Open Source Hygiene

**Files:**
- Modify: `.gitignore`
- Remove: tracked generated artifacts under `build.xcresult/` and `logs/`
- Review: `.claude/`, `.cursor/`, `.kilocode/`, `.roo/`

- [ ] **Step 1: Update ignore rules**

Add:

```gitignore
# Generated test/build outputs
*.xcresult/
logs/

# Local assistant/tool state
.claude/
.cursor/
.kilocode/
.roo/
```

Expected: local-only assistant config and generated outputs do not reappear in public commits.

- [ ] **Step 2: Remove tracked generated outputs**

Run:

```bash
git rm -r --cached build.xcresult logs
```

Expected: files are removed from git tracking but can remain locally if needed.

- [ ] **Step 3: Secret scan before public release**

Run:

```bash
rg -n "sk-[A-Za-z0-9]|OPENROUTER_API_KEY|GROQ_API_KEY|XAI_API_KEY|SONIOX_API_KEY|HERMES_API_SERVER_KEY|Bearer [A-Za-z0-9._-]+" .
```

Expected: only placeholder keys, Keychain alias names, and documentation references. No real API keys or bearer tokens.

- [ ] **Step 4: Commit hygiene cleanup**

Run:

```bash
git add .gitignore
git add -u build.xcresult logs
git commit -m "chore: remove generated artifacts from source control"
```

Expected: generated artifacts are removed from source control before publication.

## Task 4: MIT License

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Add MIT license**

Create `LICENSE`:

```text
MIT License

Copyright (c) 2026 Dane Kapoor

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Expected: GitHub detects the project as MIT licensed.

- [ ] **Step 2: Commit license**

Run:

```bash
git add LICENSE
git commit -m "chore: add MIT license"
```

Expected: license is isolated and easy to audit.

## Task 5: Public README

**Files:**
- Create or replace: `README.md`

- [ ] **Step 1: Add README structure**

Create `README.md` with these sections:

```markdown
# HermesWhisper

HermesWhisper is a macOS voice interface for dictation, LLM cleanup, and fast interaction with a Hermes Agent API server.

## What It Does

- Dictate into any app with a global hotkey.
- Clean transcripts through OpenRouter post-processing and custom vocabulary.
- Send voice or typed tasks to Hermes Agent.
- Keep multiple Hermes sessions active in parallel.
- Attach optional active-window screenshots, screen text, and recent clipboard context.
- Show always-on-top response windows with reply, copy, minimize, archive, and delete flows.
- Persist local Hermes chat history and session archive.

## Requirements

- macOS 15.5 or newer.
- Xcode 16 or newer for local development.
- Microphone permission.
- Optional screen recording permission for screenshot and screen context.
- API keys for the transcription and LLM providers you enable.
- A local or remote Hermes Agent API server for Hermes mode.

## Hermes Setup

1. Run Hermes Agent locally or on a VPS with the API server enabled.
2. Open HermesWhisper -> Hermes -> Settings.
3. Set the Hermes API URL, for example `http://127.0.0.1:8642/v1`.
4. Save the bearer key matching `API_SERVER_KEY` on the Hermes server.
5. Leave Agent profile blank for the server default, or enter the advertised profile/model name from `/v1/models`.
6. Press Test connection.

## Privacy And Local Data

HermesWhisper stores history, audio references, screenshots, and Hermes chat state locally in `~/Library/Application Support/HermesWhisper/`. API keys are stored in macOS Keychain. Optional context features can send screenshots, OCR text, and recent clipboard text to your configured Hermes API server.

## Development

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/HermesWhisper.app
```

## License

MIT
```

Expected: README is useful to both users and developers without exposing private credentials.

- [ ] **Step 2: Commit README**

Run:

```bash
git add README.md
git commit -m "docs: add public README"
```

Expected: README is ready for the GitHub repo landing page.

## Task 6: Final Verification And Repo Rename Prep

**Files:**
- Modify: `AGENTS.md`, `CLAUDE.md`, `datamodel.md`

- [ ] **Step 1: Update contributor docs**

Replace project names, paths, build commands, and storage paths in:

```text
AGENTS.md
CLAUDE.md
datamodel.md
```

Expected: no stale WonderWhisper contributor guidance remains except migration notes.

- [ ] **Step 2: Search for stale names**

Run:

```bash
rg -n "WonderWhisper|Wonder Whisper|WWMac|WWMac-lite|wonderwhisper|WonderWhisper_Mac|WonderWhisper Mac" . \
  --glob '!DerivedData_WW/**' \
  --glob '!build/**' \
  --glob '!*.xcresult/**' \
  --glob '!logs/**' \
  --glob '!.git/**'
```

Expected: only explicit legacy migration constants and changelog references remain.

- [ ] **Step 3: Build final renamed app**

Run:

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Optional manual smoke test**

Run:

```bash
open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/HermesWhisper.app
```

Expected: app launches, sidebar opens, Hermes Settings show the configured profile field, and existing local history migrates.

- [ ] **Step 5: Commit docs and final verification fixes**

Run:

```bash
git add AGENTS.md CLAUDE.md datamodel.md
git commit -m "docs: update project guidance for HermesWhisper"
```

Expected: final docs commit is separate from code rename.

## Self-Review

- Spec coverage: app rename, repo rename readiness, MIT license, and public README are all covered.
- Risk surfaced: existing dirty Hermes work should be committed before broad rename.
- Migration covered: Application Support and Keychain compatibility are explicitly required.
- Open-source hygiene covered: generated artifacts, local assistant config, and secret scanning are included.
- Verification covered: build after each risky phase, final stale-name search, and manual launch smoke test.

