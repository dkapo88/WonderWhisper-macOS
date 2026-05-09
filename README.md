# HermesWhisper

HermesWhisper is a macOS voice interface for dictation, LLM cleanup, and fast interaction with a Hermes Agent API server. It started as a local dictation app and now centers on a dedicated Hermes workflow: speak a task, send it to Hermes, receive an always-on-top response window, and keep multiple agent sessions running in parallel.

## Features

- Global dictation shortcuts for normal dictation, command mode, and Hermes tasks.
- Hermes Agent integration over an OpenAI-compatible `/v1` API endpoint with API key authentication.
- Multiple parallel Hermes sessions with persistent local history, active/archive views, text replies, voice replies, and independent response windows.
- Always-on-top Hermes response windows with Markdown rendering, raw Markdown copy, formatted rich text copy, reply, minimize, archive, and close controls.
- Optional Hermes request context: active-window screenshot, OCR screen text, and recent clipboard text.
- Configurable clipboard context timeout and Hermes request timeout.
- LLM post-processing for dictation through OpenRouter, with optional vocabulary and screen-context support.
- Transcription engines for local Parakeet, Groq Whisper, Soniox, OpenRouter speech-to-text, and xAI speech-to-text.
- Persistent microphone selection and local dictation history.

## Requirements

- macOS with Xcode installed.
- A Hermes Agent API server for the Hermes workflow.
- API keys for the providers you enable, stored locally in macOS Keychain from inside the app.

## Hermes Setup

1. Launch HermesWhisper.
2. Open the Hermes sidebar item.
3. In Settings, enter your Hermes API base URL, API key, and optional profile/model name.
4. Use the Test button to verify the connection.
5. Configure the dedicated Hermes hotkey and any context options you want to send with each request.

If the profile field is blank, Hermes uses the server default. If it is filled in, HermesWhisper sends that value as the API model/profile identifier.

## Local Data

HermesWhisper stores history, screenshots, audio references, and Hermes chat state locally in:

```text
~/Library/Application Support/HermesWhisper/
```

API keys are stored in macOS Keychain. Optional context features can send screenshots, OCR text, and recent clipboard text to your configured Hermes API server.

After the rename from WonderWhisper, first launch copies existing local data from:

```text
~/Library/Application Support/WonderWhisper/
```

## Build

Open the project in Xcode:

```bash
open "HermesWhisper.xcodeproj"
```

Build from the command line:

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -configuration Debug build
```

Or use the helper script, which writes build output under `build/`:

```bash
./Scripts/build.sh
./Scripts/run.sh
```

## Tests

Run the Swift Testing suite from Xcode, or from the command line:

```bash
xcodebuild -project "HermesWhisper.xcodeproj" -scheme "HermesWhisper" -destination 'platform=macOS' test
```

## Security

Do not commit API keys, local `.xcconfig` secrets, build outputs, result bundles, or local assistant/editor state. Provider credentials belong in macOS Keychain through the app settings.

## License

HermesWhisper is available under the MIT License. See [LICENSE](LICENSE).
