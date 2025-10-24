# Soniox Streaming Integration Notes

_Compiled 2025-10-24 from <https://soniox.com/docs>_

## Core Endpoints & Session Lifecycle

- **WebSocket URL:** `wss://stt-rt.soniox.com/transcribe-websocket`
  Source: “WebSocket API → WebSocket endpoint”.
- **Handshake payload (JSON, first message):**
  ```json
  {
    "api_key": "<SONIOX_API_KEY|TEMP_KEY>",
    "model": "stt-rt-v3",
    "audio_format": "pcm_s16le",
    "sample_rate": 16000,
    "num_channels": 1,
    "language_hints": ["en"],
    "context": "<optional domain prompt>",
    "enable_endpoint_detection": true,
    "client_reference_id": "<optional UUID>"
  }
  ```
  Parameters described in “WebSocket API → Configuration”.
- **Audio streaming:** send binary PCM frames after handshake. 60 min max session duration (“WebSocket API → Audio streaming”, “Limits & quotas”).
- **Graceful close:** send `{"type":"finalize"}` (optional `trailing_silence_ms`) followed by an empty WS frame to force final tokens, then wait for `{"finished":true}` (“Manual finalization”, “WebSocket API → Ending the stream”).

## Control Messages

| Purpose             | Payload                           | Notes |
|--------------------|-----------------------------------|-------|
| Manual finalise     | `{"type":"finalize","trailing_silence_ms":150}` | Emits `<fin>` marker, finalises all pending tokens. |
| Keep connection alive | `{"type":"keepalive"}`            | Required every ≤20 s during silence (“Connection keepalive”). |
| Endpoint detection   | `enable_endpoint_detection: true` | Finalizes tokens immediately on pause; reduces tail latency. |

## Response Semantics

- Responses always JSON; primary fields documented under “WebSocket API → Response”.
- `tokens`: array of token objects with `text`, `is_final`, optional timestamps (`start_ms`, `end_ms`), `confidence`, etc.
- Tokens arrive as a rolling window (`is_final=false` first, then re-emitted with `is_final=true` when stabilised).  
  Example in “Real-time transcription → Example token evolution”.
- `final_audio_proc_ms` vs `total_audio_proc_ms` show how much audio is fully finalised vs tentatively processed.
- `finished: true` indicates the stream has ended and the socket is closing.
- Error responses include `error_code`, `error_message` and close the connection (“Error handling”).

## Reliability Considerations

1. **First-frame capture:** buffer PCM frames before and during handshake, then flush once the socket is ready. We maintain a provider-level prebuffer plus a session buffer for reliability.
2. **Final words:** always send `finalize` with a small `trailing_silence_ms`, then an empty frame, and wait for `finished`. Flush any locally buffered PCM before shutdown to avoid truncation.
3. **Keepalive:** when VAD mutes output, start a 10 s heartbeat that sends `{"type":"keepalive"}`; cancel once audio resumes to keep the session alive without extra latency.
4. **Endpoint detection:** enable to reduce tail latency—Soniox emits `<end>` once speech stops; treat it as a reliable “segment complete” marker but omit it from the rendered transcript.
5. **Error recovery:** handle `503` “Cannot continue request” by retrying the WebSocket session (“Error handling”).

## Suggested Defaults for WonderWhisper

- **Model ID:** `stt-rt-v3` (current low-latency Soniox streaming model). `stt-rt-preview-v2` is deprecated.
- **Language hints:** derive from user preference (`transcription.language`, fallback `["en"]`).
- **Latency tuning:**
  - Send approx. 30 ms PCM chunks (current recorder default) for balance between responsiveness and bandwidth.
  - On stop: add ~150 ms silence locally before finalising or set `trailing_silence_ms` to match the captured silence.
- **UI surface:**
  - Provider option `Soniox (Streaming)` in transcription picker.
  - API key entry stored under Keychain alias `SONIOX_API_KEY`.
  - Advanced toggles (optional future work): endpoint detection, language hints override, context prompt.

## Open Questions / Follow-ups

- **Temporary API keys:** server-side helper required if exposing Soniox directly to clients (not needed for WonderWhisper desktop yet).
- **Speaker diarisation & translation:** available via flags; defer until baseline reliability is validated.
- **Adaptive chunk sizing:** monitor for token drift on very long sessions; consider dynamic chunk window or periodic manual finalisation.
