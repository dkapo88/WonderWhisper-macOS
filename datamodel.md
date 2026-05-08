# WonderWhisper Mac - Data Model Documentation

Note to agents and contributors: Keep this document up to date with any changes.

## Overview

WonderWhisper Mac is a voice dictation and AI assistant application. This document provides comprehensive entity relationship diagrams and data model documentation for database schemas, service models, and UI data structures.

---

## Table of Contents

1. [Core Domain Models](#core-domain-models)
2. [Entity Relationship Diagrams](#entity-relationship-diagrams)
3. [Storage & Persistence](#storage--persistence)
4. [Service Models](#service-models)
5. [UI State Models](#ui-state-models)
6. [Configuration Models](#configuration-models)
7. [Maintenance](#maintenance)

---

## Core Domain Models

### 1. Prompt & Configuration System

```mermaid
erDiagram
    PromptConfiguration ||--o{ PromptConversationMessage : "has conversation history"
    PromptConfiguration {
        UUID id PK
        String name
        String systemPrompt
        String userPrompt
        Shortcut shortcut "optional"
        Selection selection "optional"
        String llmModelOverride "optional"
        String llmProviderOverride "optional"
        String openrouterRoutingOverride "optional"
        String voiceModelOverride "optional"
        String voiceLanguageOverride "optional"
        Bool screenContextOverride "optional"
        Bool clipboardContextOverride "optional"
        Bool selectedTextOverride "optional"
        Bool activeTextFieldOverride "optional"
        ScreenContextCaptureMode screenContextCaptureOverride "optional"
        Bool includeScreenImageOverride "optional"
        Bool triggerOnSelectedText
        Bool conversationModeEnabled
        Int conversationContextMessages
    }
    
    PromptConversationMessage {
        UUID id PK
        UUID promptID FK
        String role "user or assistant"
        String content
        Date timestamp
    }
    
    ConversationHistoryMetadata {
        String lastProvider "optional"
        String lastProviderEndpoint "optional"
        Date createdAt
        Date updatedAt
    }
    
    PromptConfiguration ||--o| ConversationHistoryMetadata : "has metadata"
```

**PromptConfiguration**: User-defined prompt templates that control how voice transcriptions are processed and formatted. Each prompt can have:
- Custom system/user prompts
- LLM/voice model overrides
- Context capture settings
- Hotkey bindings
- Conversation mode settings

**PromptConversationMessage**: Messages in conversation history for prompts with conversation mode enabled. Stores the dialogue context between user and assistant.

**ConversationHistoryMetadata**: Tracks provider information and timestamps for conversation sessions. Metadata is stored one file per prompt (filenames keyed by `promptID`).

---

### 2. Transcription History System

```mermaid
erDiagram
    HistoryEntry {
        UUID id PK
        Date date
        String appName "optional"
        String bundleID "optional"
        String transcript
        String output
        String audioFilename "optional"
        String screenContext "optional"
        String screenContextMethod "optional - AX, Image-Window, Image-Display, AppleIntelligenceTerms, LocalKeywordTerms"
        String screenImageFilename "optional"
        String screenImageMimeType "optional"
        Int screenImageWidth "optional"
        Int screenImageHeight "optional"
        String selectedText "optional"
        String activeTextField "optional"
        String llmSystemMessage "optional"
        String llmUserMessage "optional"
        String transcriptionModel "optional"
        String llmModel "optional"
        Double transcriptionSeconds "optional"
        Double llmSeconds "optional"
        Double totalSeconds "optional"
    }
```

**HistoryEntry**: Records of completed dictation sessions. Each entry captures:
- Raw transcription and processed output
- Application context (where dictation occurred)
- Audio recording reference
- Screen context and captures. Text context may be raw OCR or a comma-delimited term list generated from full-display OCR.
- Focused text field contents
- Performance metrics
- LLM prompts used (for transparency)

**Storage**: Files persisted in `~/Library/Application Support/WonderWhisper/History/`
- `entries/` - JSON files (one per entry)
- `audio/` - M4A/WAV recordings
- `images/` - PNG/JPG screen captures

---

### 3. Hermes Persistent Chat System

```mermaid
erDiagram
    HermesChatSession ||--o{ HermesChatMessage : "contains"

    HermesChatSession {
        UUID id PK
        String title
        String conversationName "unique Hermes API conversation"
        String serverSessionID "optional X-Hermes-Session-Id"
        Date createdAt
        Date updatedAt
        String status "open, waiting, responded, error, interrupted, archived, closed"
    }

    HermesChatMessage {
        UUID id PK
        String role "user, assistant, or error"
        String text
        Date createdAt
        String[] contextLabels "screen text, screenshot, clipboard"
    }
```

**HermesChatSession**: Persistent Hermes task thread. Each session owns a unique API `conversation` value derived from the configured Hermes conversation prefix plus the session id, allowing simultaneous background Hermes tasks to continue independently.
New sessions start with the generic title `New Hermes Task`; after the first user
turn is captured, the app asks the configured OpenRouter LLM model for a concise
local title and updates only the matching session id. Title generation is local to
WonderWhisper state and is not sent through Hermes.

**HermesChatMessage**: Messages shown in the selected Hermes sidebar Chat session. Messages are appended from the dedicated Hermes voice loop:
- User messages show the spoken transcript after optional Hermes LLM post-processing, not the enriched payload sent to the API.
- Assistant messages show the Hermes response with Markdown rendering.
- Error messages preserve failed transcription or API turn feedback.
- Context labels indicate which optional payloads were sent with the user turn.
- Clipboard context is eligible only when the copied text was captured within 60
  seconds before the Hermes recording starts. The request may finish later; the
  recording start time determines whether copied text is included.
- `hermes.postProcessing.enabled` controls whether Hermes dictation text is cleaned
  through the existing OpenRouter post-processing/vocabulary flow before it is sent
  to the Hermes API. When disabled, the raw transcript is sent.

**Persistence**: `HermesSessionStore` persists recent Hermes sessions in `~/Library/Application Support/WonderWhisper/HermesChat/sessions.json`. The default retention limit is 25 sessions, controlled by `hermes.sessions.maxSessions`; each session keeps the latest 50 messages by default, controlled by `hermes.chat.maxMessages`. `messages.json` from the previous flat chat history format is migrated into a `Previous Hermes Chat` session when `sessions.json` does not exist. Completed Hermes turns also write to the general `HistoryEntry` store with transcript, output, screen context, screenshot metadata, and LLM message payloads.

Persisted sessions found in `waiting` state after app launch are recovered as `interrupted`,
because the remote Hermes task may have continued after the local app process was restarted.
Interrupted sessions remain replyable so the user can reinitiate the same Hermes conversation.

Hermes sessions have an Active/Archive lifecycle in the app UI. Archiving removes a
session from the active list but keeps the local session record and message history
available in the Archive tab; legacy `closed` sessions are treated as archived.
Restoring an archived session returns it to a replyable active state inferred from its
latest message. Deleting a session permanently removes only the local WonderWhisper
record; it does not delete remote Hermes VPS context unless the API later adds a
separate remote delete operation.

---

### 4. Simple Mode System

```mermaid
erDiagram
    SimplePromptSettings {
        SimplePromptRule[] rules
        String header
        String footer
        Bool enableScreenContext
        Bool enableClipboardContext
        Bool enableSelectedText
        Bool enableActiveTextField
        Selection selection "optional hotkey"
        Bool includeScreenImage
    }
    
    SimplePromptRule {
        UUID id PK
        String text
    }
    
    SimplePromptSettings ||--|{ SimplePromptRule : "contains"
```

**SimplePromptSettings**: Simplified configuration for the two user-facing modes. Each mode can independently toggle OCR screen context, clipboard history, selected text, and the full active text field payload.
- **Dictation**: Voice-to-text formatting
- **Command**: Selected-text/OCR aware assistant mode

**SimplePromptRule**: Individual formatting/behavior rules as plain text statements

**SimpleVoiceEngine**: User-facing toggle that selects the transcription backend.

| Case | Description | Underlying Model |
|------|-------------|------------------|
| `parakeet-local` | On-device Parakeet V3 for maximum privacy/latency | `parakeet-local` |
| `groq-streaming` | Groq Whisper Large V3 Turbo over HTTPS chunks | `whisper-large-v3-turbo` (via Groq) |
| `openrouter-transcription` | OpenRouter speech-to-text endpoint for cloud voice models | `openai/gpt-4o-mini-transcribe` by default |
| `xai-stt` | xAI Grok Speech-to-Text over HTTPS multipart upload | `xai-stt` service endpoint |
| `soniox-streaming` | Soniox V4 real-time streaming with live preview | `stt-rt-v4` |

---

## Service Models

### Provider Settings

```mermaid
erDiagram
    TranscriptionSettings {
        URL endpoint
        String model
        TimeInterval timeout
        String language "optional ISO-639-1 or auto"
        String context "optional - request origin label"
    }
    
    LLMSettings {
        URL endpoint
        String model
        String systemPrompt "optional"
        TimeInterval timeout
        Bool streaming
        Double temperature
    }
```

**TranscriptionSettings**: Configuration for speech-to-text providers (Parakeet V3 local capture, Groq Whisper Turbo, OpenRouter speech-to-text, xAI Grok Speech-to-Text, and Soniox streaming)

**LLMSettings**: Configuration for language model providers (OpenRouter only; legacy Cerebras keychain support remains). OpenRouter chat requests explicitly send `reasoning.effort = "none"` and `reasoning.exclude = true` for post-processing and command LLM calls; this is a request default, not a persisted UserDefaults setting.

---

### Hotkey & Input System

```mermaid
erDiagram
    Shortcut {
        UInt32 keyCode "kVK_ constant"
        UInt32 modifiers "Carbon modifier mask"
    }
    
    Selection {
        String value "enum: fnGlobe, leftCommand, rightCommand, etc."
    }
```

**Shortcut**: Key combination (e.g., Cmd+V) using Carbon API constants

**Selection**: Single modifier key for push-to-talk/toggle recording:
- `.fnGlobe` - Fn/Globe key
- `.leftCommand` - Left ⌘
- `.rightCommand` - Right ⌘
- `.leftOption` - Left ⌥
- `.rightOption` - Right ⌥
- `.control` - Either Control key
- `.commandRightShift` - ⌘ + Right Shift
- `.optionRightShift` - ⌥ + Right Shift
- `.f5` - F5 function key

---

### Mode & Enums

```mermaid
erDiagram
    ScreenContextCaptureMode {
        String value "image or text"
    }
    
    SimpleSidebarItem {
        String value "hermes, history, dictation, command, vocabulary, microphone, settings"
    }
    
    SimpleVoiceEngine {
        String value "parakeetLocal or groqStreaming"
    }
```

---

## Entity Relationship Diagrams

### Complete System Overview

```mermaid
erDiagram
    DictationViewModel ||--|{ PromptConfiguration : "manages"
    DictationViewModel ||--|| HistoryStore : "uses"
    DictationViewModel ||--|| ConversationHistoryStore : "uses"
    DictationViewModel ||--|{ FavoriteLLMModel : "tracks"
    DictationViewModel ||--|| HermesAgentSettings : "uses when enabled"
    DictationViewModel ||--|| HermesSessionStore : "loads and saves"
    DictationViewModel ||--o{ HermesChatSession : "tracks Hermes sessions"
    
    HistoryStore ||--|{ HistoryEntry : "stores"
    
    ConversationHistoryStore ||--|{ PromptConversationMessage : "stores"
    ConversationHistoryStore ||--|{ ConversationHistoryMetadata : "tracks"

    HermesSessionStore ||--o{ HermesChatSession : "persists"
    HermesChatSession ||--o{ HermesChatMessage : "contains"
    
    PromptConfiguration ||--o| Shortcut : "has shortcut"
    PromptConfiguration ||--o| Selection : "has selection"
    
    DictationViewModel {
        UUID selectedPromptID FK "optional"
        String status
        Bool isRecording
        Float audioLevel
        SimplePromptSettings simpleDictationSettings
        SimplePromptSettings simpleCommandSettings
        SimpleVoiceEngine simpleVoiceEngine
        String transcriptionModel
        String transcriptionLanguage
        Bool llmEnabled
        String llmModel
        Bool screenContextEnabled
        ScreenContextCaptureMode screenContextCaptureMode
        Bool hermesAgentEnabled
        UUID selectedHermesSessionID FK "optional"
        HermesChatSession[] hermesSessions
        HermesChatMessage[] hermesChatMessages
    }
    
    HistoryStore {
        Int maxEntries
        Bool hasMoreEntries
        Bool isLoadingMore
    }

    HermesSessionStore {
        Int maxMessagesPerSession
        Int maxSessions
        URL fileURL
    }
    
    FavoriteLLMModel {
        UUID id PK
        String provider
        String model
    }

    HermesAgentSettings {
        String baseURLString
        String model
        String conversationName
        TimeInterval timeout
    }
```

---

## Storage & Persistence

### File System Layout

```
~/Library/Application Support/WonderWhisper/
├── History/
│   ├── entries/           # JSON files (HistoryEntry)
│   │   ├── <uuid>.json
│   │   └── ...
│   ├── audio/             # M4A/WAV recordings
│   │   ├── <uuid>.m4a
│   │   └── ...
│   └── images/            # PNG/JPG screen captures
│       ├── <uuid>.png
│       └── ...
├── ConversationHistory/
│   └── conversations/
│       ├── <promptID>_messages.json    # PromptConversationMessage[]
│       └── <promptID>_metadata.json    # ConversationHistoryMetadata
└── HermesChat/
    ├── sessions.json      # Last retained HermesChatSession[] rows
    └── messages.json      # Legacy flat HermesChatMessage[] rows, migrated on load
```

### UserDefaults Keys

| Key | Type | Description |
|-----|------|-------------|
| `prompts.library` | Data | JSON-encoded `[PromptConfiguration]` |
| `prompts.selected.id` | String | UUID of selected prompt |
| `transcription.model` | String | Active transcription model |
| `transcription.language` | String | Transcription language code |
| `transcription.timeout` | Double | Network timeout (seconds) |
| `llm.enabled` | Bool | LLM processing enabled |
| `llm.model` | String | Active LLM model |
| `llm.streaming` | Bool | Streaming mode enabled |
| `llm.temperature` | Double | LLM temperature (0.0-1.0) |
| `llm.systemPrompt` | String | Last-selected system prompt text |
| `llm.userMessage` | String | Last-selected user prompt text |
| `llm.openrouter.routing` | String | OpenRouter routing priority (auto/latency/throughput) |
| `screenContext.enabled` | Bool | Screen context capture enabled |
| `screenContext.captureMode` | String | Capture mode (image/text) |
| `screenContext.preprocessMode` | String | Preprocessing mode |
| `screenContext.organizePrompt` | String | Organization prompt |
| `clipboardContext.enabled` | Bool | Clipboard context enabled |
| `vocab.custom` | String | Custom vocabulary list |
| `vocab.spelling` | String | Text replacement rules |
| `audio.input.uid` | String | Selected microphone UID |
| `hotkey.selection` | String | Hotkey selection mode |
| `pasteShortcut.keyCode` | Int | Paste shortcut key code |
| `pasteShortcut.modifiers` | Int | Paste shortcut modifiers |
| `insertion.useAX` | Bool | Use accessibility API for insertion |
| `insertion.pasteFormatted` | Bool | Paste as formatted text |
| `audio.preprocess.enabled` | Bool | Audio preprocessing enabled |
| `audio.voiceProcessing.enabled` | Bool | Voice processing enabled |
| `history.maxEntries` | Int | Maximum history entries to keep |
| `simple.llm.enabled` | Bool | LLM enabled in simple mode |
| `simple.model.selected` | String | Selected OpenRouter model |
| `simple.model.custom` | Array<String> | Custom OpenRouter model IDs |
| `simple.voice.engine` | String | Selected transcription engine (`parakeet-local`, `groq-streaming`, `openrouter-transcription`, `xai-stt`, or `soniox-streaming`) |
| `transcription.openrouter.model` | String | Selected OpenRouter speech-to-text model ID |
| `simple.dictation.settings` | Data | Dictation prompt settings |
| `simple.command.settings` | Data | Command prompt settings |
| `simple.sidebar.selection` | String | Selected sidebar item |
| `audio.stream.eq.enabled` | Bool | Stream EQ enabled |
| `audio.stream.dynamics.enabled` | Bool | Stream dynamics enabled |
| `audio.stream.chunkMs` | Int | Stream chunk size (ms) |
| `network.http_protocol_preference` | String | HTTP protocol preference |
| `hermes.agent.enabled` | Bool | Enable the dedicated Hermes voice hotkey |
| `hermes.api.baseURL` | String | Hermes API server URL; root and `/v1` URLs are both accepted |
| `hermes.conversation.name` | String | Hermes conversation prefix used when creating new sessions |
| `hermes.model` | String | Cosmetic Hermes API model field |
| `hermes.timeout` | Double | Hermes request timeout (seconds), clamped from 15 seconds to 1,800 seconds |
| `hermes.shortcut.selection` | String | Dedicated Hermes activation key; accepts `backslash`, `f5`, and modifier-key selections |
| `hermes.context.screenText.enabled` | Bool | Include Hermes OCR/screen text context |
| `hermes.context.screenshot.enabled` | Bool | Attach Hermes active-window screenshot images |
| `hermes.context.clipboard.enabled` | Bool | Include Hermes copied text / clipboard context only when copied within 60 seconds before recording start |
| `hermes.postProcessing.enabled` | Bool | Clean Hermes dictations through the OpenRouter post-processing flow before sending |
| `hermes.chat.maxMessages` | Int | Maximum persisted Hermes chat messages to retain; default 50 |
| `hermes.sessions.maxSessions` | Int | Maximum persisted Hermes sessions to retain; default 25 |

### Keychain Storage

Secure storage via `KeychainService` for API keys:

| Key Alias | Purpose |
|-----------|---------|
| `GROQ_API_KEY` | Groq API authentication (Whisper Turbo) |
| `OPENROUTER_API_KEY` | OpenRouter API authentication |
| `XAI_API_KEY` | xAI API authentication (Grok Speech-to-Text) |
| `SONIOX_API_KEY` | Soniox API authentication |
| `HERMES_API_SERVER_KEY` | Hermes API server bearer token |

---

## UI State Models

### View Models

```mermaid
erDiagram
    DictationViewModel {
        String status
        Bool isRecording
        Float audioLevel
        PromptConfiguration[] prompts
        UUID selectedPromptID "optional"
        String systemPrompt
        String userPrompt
        SimplePromptSettings simpleDictationSettings
        SimplePromptSettings simpleCommandSettings
        SimpleVoiceEngine simpleVoiceEngine
        String simpleSelectedModel
        String[] simpleCustomModels
        Bool simpleLLMEnabled
        SimpleSidebarItem simpleSidebarSelection
        Bool hermesAgentEnabled
        Bool hermesScreenContextEnabled
        Bool hermesScreenshotEnabled
        Bool hermesClipboardContextEnabled
        UUID selectedHermesSessionID "optional"
        HermesChatSession[] hermesSessions
        HermesChatMessage[] hermesChatMessages
        HermesResponseWindowState[] hermesResponseWindowStates
    }
```

---

## Configuration Models

### Application Configuration

```swift
struct AppConfig {
    // API Endpoints
    static let groqAudioTranscriptions: URL
    static let groqChatCompletions: URL
    static let openrouterChatCompletions: URL
    static let openrouterModels: URL
    
    // Default Models
    static let defaultTranscriptionModel: String = "whisper-large-v3-turbo"
    static let defaultLLMModel: String = "moonshotai/kimi-k2-instruct"
    
    // Default Prompts
    static let defaultSystemPromptTemplate: String
    static let defaultDictationPrompt: String
    static let defaultScreenOrganizePrompt: String
    
    // Keychain Aliases (active)
    static let groqAPIKeyAlias: String = "GROQ_API_KEY"
    static let openrouterAPIKeyAlias: String = "OPENROUTER_API_KEY"
    static let hermesAPIKeyAlias: String = "HERMES_API_SERVER_KEY"
    static let defaultHermesBaseURLString: String = "http://127.0.0.1:8642"
    static let defaultHermesModel: String = "hermes-agent"
    static let defaultHermesConversationName: String = "wonderwhisper-mac"
    
    // Network
    static let httpProtocolPreference: HTTPProtocolPreference
}
```

---

## Maintenance

- Update this document whenever you change entities, fields, relationships, storage locations, configuration keys, or persistence formats.
- Record notable breaking changes inline near the affected section.
- After updates: adjust migrations (if applicable), update tests, and verify any storage paths referenced in code and in AGENTS.md.

### Changelog

- **v1.8 (May 8, 2026)**: Added Hermes LLM title generation, optional Hermes post-processing, clearer response-window focus/reply state, selectable message bodies, and raw/formatted copy actions.
- **v1.7 (May 7, 2026)**: Limited Hermes clipboard context to copied text captured within one minute before recording start.
- **v1.6 (May 7, 2026)**: Added persistent multi-session Hermes storage and per-session response windows.
- **v1.5 (May 7, 2026)**: Documented OpenRouter chat requests disabling reasoning by default.
- **v1.4 (May 6, 2026)**: Added persistent Hermes chat history storage capped to the latest 50 messages by default.
- **v1.3 (May 6, 2026)**: Raised the Hermes request timeout maximum from 600 to 1,800 seconds.
- **v1.2 (May 6, 2026)**: Added `HermesChatMessage` as the current-session Hermes chat UI model and documented Hermes as a first-class sidebar item.
- **v1.1 (Nov 14, 2025)**: Removed non-existent `ScreenContextPreprocessingMode`, added vocabulary & microphone to `SimpleSidebarItem`, clarified legacy keychain aliases, updated LLM provider documentation to reflect OpenRouter-only architecture.

### Simple Mode Defaults

```swift
enum SimpleModeDefaults {
    static let defaultModelID = "moonshotai/kimi-k2-0905"
    
    // Predefined model options
    static let modelOptions: [SimpleModelOption] = [
        // Moonshot, Meta LLaMA, OpenAI, Google Gemini, Anthropic Claude, Mistral
    ]
    
    // Default rules for dictation mode (17 rules)
    // Default rules for command mode (16 rules)
}
```

---

## Data Flow Diagrams

### Dictation Flow

```mermaid
sequenceDiagram
    participant User
    participant DictationViewModel
    participant AudioRecorder
    participant TranscriptionProvider
    participant LLMProvider
    participant HistoryStore
    participant InsertionService
    
    User->>DictationViewModel: Trigger hotkey
    DictationViewModel->>AudioRecorder: Start recording
    AudioRecorder-->>DictationViewModel: Audio level updates
    User->>DictationViewModel: Release hotkey
    DictationViewModel->>AudioRecorder: Stop recording
    AudioRecorder-->>DictationViewModel: Audio file URL
    
    DictationViewModel->>TranscriptionProvider: transcribe(fileURL)
    TranscriptionProvider-->>DictationViewModel: Raw transcript
    
    alt LLM Enabled
        DictationViewModel->>LLMProvider: process(transcript)
        LLMProvider-->>DictationViewModel: Formatted output
    else LLM Disabled
        DictationViewModel->>DictationViewModel: Use raw transcript
    end
    
    DictationViewModel->>HistoryStore: append(entry)
    DictationViewModel->>InsertionService: insert(text)
    InsertionService-->>User: Text inserted in app
```

### Conversation Mode Flow

```mermaid
sequenceDiagram
    participant User
    participant DictationViewModel
    participant ConversationHistoryStore
    participant LLMProvider
    
    User->>DictationViewModel: Trigger with conversation prompt
    DictationViewModel->>ConversationHistoryStore: getContextMessages(promptID)
    ConversationHistoryStore-->>DictationViewModel: Previous messages
    
    DictationViewModel->>DictationViewModel: Record & transcribe
    DictationViewModel->>LLMProvider: process(with context)
    LLMProvider-->>DictationViewModel: Response
    
    DictationViewModel->>ConversationHistoryStore: addMessage(user)
    DictationViewModel->>ConversationHistoryStore: addMessage(assistant)
```

### Hermes Voice Flow

```mermaid
sequenceDiagram
    participant User
    participant DictationViewModel
    participant DictationController
    participant HermesAPI
    participant HermesSessionStore
    participant HistoryStore

    User->>DictationViewModel: Trigger Hermes hotkey
    DictationViewModel->>DictationViewModel: Reply to visible response window session, else create a new session
    DictationViewModel->>DictationViewModel: Start screenshot capture and 60-second clipboard eligibility check
    DictationViewModel->>DictationController: Start recording
    User->>DictationViewModel: Trigger Hermes hotkey again
    DictationViewModel->>DictationController: Finish transcription-only turn
    DictationController-->>DictationViewModel: Transcript + audio/context metadata
    DictationViewModel->>DictationViewModel: Optionally clean transcript and generate local session title
    DictationViewModel->>HermesSessionStore: append user message and mark session waiting
    DictationViewModel->>HermesAPI: POST /v1/responses with session conversation and enabled context
    HermesAPI-->>DictationViewModel: Assistant response
    DictationViewModel->>HermesSessionStore: append assistant message and mark session responded
    DictationViewModel->>HistoryStore: append transcript/response entry and screenshot metadata
    DictationViewModel-->>User: Show response window for that session
    User->>DictationViewModel: Interrupt stale or active waiting session
    DictationViewModel->>HermesSessionStore: mark session interrupted and keep it replyable
    User->>DictationViewModel: Archive, restore, or delete a local session record
    DictationViewModel->>HermesSessionStore: persist active/archive lifecycle changes
```

---

## Key Design Patterns

### 1. Provider Cache Pattern
- `DictationViewModel` maintains provider caches to avoid recreating HTTP clients
- Providers are keyed by configuration signature and keyed separately for streaming/file modes
- Cache invalidation on settings change

### 2. Debounced Updates
- Provider updates debounced (500ms) to prevent excessive recreation
- Navigation should not trigger provider updates (performance optimization)

### 3. File-Based Persistence
- History entries stored as individual JSON files
- Paginated loading (20 entries at a time)
- Background queue for I/O operations

### 4. Conversation History Isolation
- Each prompt maintains separate conversation history
- Provider changes clear history automatically
- Configurable context window (message count)

### 5. Simple/Pro Mode Abstraction
- Simple mode generates `PromptConfiguration` internally
- Settings persisted separately but rendered as prompts
- Seamless switching preserves pro settings

---

## Migration Notes

### Legacy Compatibility

- `organizeScreenContextOverride` (Bool) field removed; legacy key ignored during decoding
- `shortcut` field in `SimplePromptSettings` ignored during decoding (simple mode uses `selection` only)
- Conversation history tracks provider changes to handle model switches
- Legacy Cerebras, Ollama, AssemblyAI, Soniox keychain aliases preserved but unused in shipping build

---

## Performance Considerations

### History Store
- **Pagination**: Load 20 entries at a time to avoid blocking UI
- **Background I/O**: All file operations on background queue
- **Lazy metadata**: File dates fetched only when needed

### Provider Management
- **Cache warmth**: HTTP connections pre-warmed on init
- **Debouncing**: 500ms debounce on settings changes
- **Lazy initialization**: Providers created only when needed

### Conversation History
- **Bounded context**: Limit to N most recent messages
- **Auto-cleanup**: Clear on provider/model change
- **Async writes**: All I/O operations asynchronous

---

## Security & Privacy

### API Key Management
- All API keys stored in macOS Keychain
- Never persisted to UserDefaults or JSON
- Retrieved on-demand via `KeychainService`

### Audio & Screen Captures
- Stored locally in Application Support directory
- No cloud sync or external transmission
- User controls retention via `maxEntries` setting

### Prompt Library
- User-created prompts stored locally
- System prompts embedded in app bundle
- No telemetry or external sharing

---

## Future Considerations

### Potential Schema Extensions

1. **Tags/Categories for Prompts**
   - Add `tags: [String]` to `PromptConfiguration`
   - Enable filtering and organization

2. **Multi-Language Vocabulary**
   - Extend vocabulary storage per language
   - Support language-specific custom dictionaries

3. **Prompt Sharing/Import**
   - Export prompt as JSON
   - Import community-created prompts

4. **Advanced History Filtering**
   - Filter by app, model, date range
   - Full-text search across transcripts

5. **Cloud Sync (Optional)**
   - CloudKit integration for prompt library
   - End-to-end encrypted conversation history

---

## API Contract Summary

### Core Protocols

```swift
protocol TranscriptionProvider {
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String
}

protocol LLMProvider {
    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String
}
```

### Provider Implementations

- **TranscriptionProvider**:
  - `GroqTranscriptionProvider` (Groq Whisper API - batch)
  - `GroqStreamingProvider` (Groq chunked streaming)
  - `OpenRouterTranscriptionProvider` (OpenRouter speech-to-text JSON API)
  - `XAITranscriptionProvider` (xAI Grok Speech-to-Text REST API)
  - `ParakeetTranscriptionProvider` (local V3 on-device)
  - `SonioxStreamingProvider` (Soniox V4 real-time streaming)

- **LLMProvider**:
  - `OpenRouterLLMProvider` (OpenRouter multiplexed models)

---

## Glossary

| Term | Definition |
|------|------------|
| **Prompt Configuration** | Template defining how voice input is processed and formatted |
| **Conversation Mode** | Stateful interaction maintaining context across multiple dictations |
| **Screen Context** | Information about active application and on-screen content |
| **Simple Mode** | Primary UI with Dictate and Command presets |
| **Push-to-Talk** | Hold hotkey to record, release to process |
| **Toggle Mode** | Tap hotkey to start/stop recording |
| **Provider** | External or local service for transcription or LLM processing |

---

**Document Version**: 1.5
**Last Updated**: May 7, 2026
**Maintainer**: WonderWhisper Mac Development Team
