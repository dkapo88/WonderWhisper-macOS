# WonderWhisper product spec

Paper is the source of truth for look and flow:
<https://app.paper.design/file/01M6GKS8FVWXGT8D1EYZP0F4DQ>. Each section below names its Paper
page. Take design values (copy, colours, spacing) from the Paper file, not from screenshots.
Decisions and the alternatives they rule out are in [decisions.md](decisions.md).

## Transcription

Paper pages "Settings › Transcription" (Soniox V6 selected, the dictation model menu, spoken
formatting commands notes) and "Meetings › Transcription" (Soniox V6 Cloud selected, the meeting
engine menu). Issue #23.

### Engines

- Dictation engines: Parakeet (on-device), Qwen3-ASR 0.6B (on-device), Groq Whisper Turbo,
  Soniox V6 (Real-time Cloud), OpenRouter Voice, Grok STT / xAI and Grok STT / xAI Streaming.
- Meeting engines: Parakeet Unified (On-device), Soniox V6 (Cloud) and Grok Voice Transcribe 2.0
  (Cloud).
- Soniox dictation and both live meeting streams use `stt-rt-v6`. Saved model values that are
  empty, `soniox-streaming` or `stt-rt-v3`/`v4`/`v5` run as `stt-rt-v6`; any other explicit value
  is sent as is. Persisted engine ids (`soniox-streaming`, `soniox-separate`, `soniox`) never
  change.
- Every Soniox WebSocket sends the key in the `Authorization: Bearer` header. The start message
  carries model, audio format, sample rate, channels, language hints, language identification,
  endpointing, diarization and `context.terms`, never the key.
- Meeting streams: the microphone is never diarized, the call side is. Both send the same
  `context.terms`: the user and attendees first, then the user's vocabulary and spelling
  correction targets, then the fixed meeting terms (case-insensitive duplicates removed, at most
  100 terms of at most 50 characters).
- When a Soniox meeting loses both live streams, recovery sends both retained tracks to
  `stt-async-v6` with the same terms policy, evaluated once when recovery starts (live context is
  not stored, so recovery does not replay the exact historic terms). If that fails, local
  Parakeet recovery is used.

### Spoken formatting commands

- Applied by the default dictation cleanup rules whenever LLM cleanup runs, whatever the
  transcription engine: "new line" (one line break), "new paragraph" (blank line), "period" or
  "full stop", "comma", "question mark", "exclamation mark", and "scratch that".
- "Scratch that" drops only the sentence spoken just before it in the same dictation, never
  earlier dictations, selected text or anything else in the app.
- Literal and quoted uses stay as words ("the trial period", "type the words new line").
- Cleanup off, or cleanup failed: the words are inserted as spoken. Meeting transcripts and
  notes never apply these commands. There is no local command parser.
- A saved rules text that exactly matches an earlier default is upgraded to the new default once.
  Edited rules, prompt templates, header, footer and every other setting stay as saved.

## Meetings › Webhooks

Paper page "Meetings › Webhooks": the webhook editor with a MausBot address pasted (new
webhook), the webhook list statuses (including orange "ignored" and grey "setup check only"
rows), and behaviour notes. Issue #20.

### Why

Meeting webhooks were first tuned for a receiver that only kept the first ~4,000 characters of
a request. MausBot (OpenMausBot) webhook automations work differently:

- Each accepted request starts its own bot run: at most 3 unfinished runs per automation, then
  HTTP 429 (no `Retry-After`); at most 10 requests a minute.
- The run sees the payload only inside its prompt, re-indented as JSON with 2 spaces and cut at
  48,000 characters. Bodies over 256 KB are refused with 413.
- Duplicates are detected by `Idempotency-Key` (also `X-Webhook-Id`, `Webhook-Id`). Event
  filters read `X-GitHub-Event` first, then `X-Webhook-Event`, `X-Event-Type`, `CE-Type`.
- The address carries its secret in the path (`/hooks/wh_<id>/whsec_<secret>`); MausBot also
  accepts it as `Authorization: Bearer <secret>`.
- Success is `202` with JSON `{accepted, runId, deliveryId, duplicate, ignored}`, or
  `{captured: true}` when the automation is still off and only stores the request as a setup
  check.

The outcome for the user: a meeting note reaches a MausBot automation in full, once per
request, with honest statuses, and the receiving bot can put a long note back together exactly.

### Behaviour

1. **Headers.** Every request (completed, resent, test; split or not) also sends
   `Idempotency-Key` and `X-Webhook-Event: <event>`. Body `deliveryId`, `Idempotency-Key` and
   `X-WonderWhisper-Delivery` are one identical string (the body's form, an uppercase UUID).
   Retries of one request repeat it; resends get new ids. Signature and the other
   `X-WonderWhisper-*` headers are unchanged. Custom headers can't use `Content-Type`,
   `Idempotency-Key`, `X-Webhook-Event` or `X-WonderWhisper-*` (any case); for a MausBot address
   also not `X-GitHub-Event`, `X-Event-Type`, `CE-Type`, `X-Webhook-Id` or `Webhook-Id`. A saved
   header that is now reserved is not sent and the editor flags it.
2. **Receiver reply.** For a 2xx response at most 4 KB of the body is read. Only literal JSON
   booleans count:
   - `ignored: true`: delivered, orange warning "Reached <name>, but it ignored this event
     type", no retry.
   - `captured: true`: delivered, grey "Reached <name>. Its automation is off, so it saved this
     as a setup check only", no retry.
   - `duplicate: true`, a body over 4 KB, not JSON, not an object, `"true"` strings, and a body
     read failure after the 2xx status: a normal "Sent".
   - Redirects stay refused. The body is never stored, logged or put in an error message; the
     delivery record keeps only the outcome. A split send's row looks at the newest record of
     every part: any ignored or captured part shows that status.
3. **MausBot address in the editor.** Recognised only when the whole URL is a complete MausBot
   address on a host the URL validator accepts: path `/hooks/wh_<id>/<secret>` where the secret,
   percent-decoded once, is `whsec_` plus 43 base64url characters. A partly typed secret is left
   alone.
   - The secret leaves the URL at once and becomes a masked `Authorization: Bearer <secret>`
     header draft, replacing any Authorization draft whatever its case. It reaches the Keychain
     only on Save; Cancel discards it. If the URL then points to another destination, an
     Authorization header filled this way is cleared.
   - Green badge under the URL: "MausBot address recognised. Its secret moves to the
     Authorization header below and is saved in Keychain on Save."
   - New webhook only, once per draft: Full note, split on, max body 40,000 bytes, 30 s between
     parts, 30 s between notes, with the line "MausBot settings applied: the full note in parts
     of up to 40,000 bytes, 30 seconds apart, so MausBot reads every part in full. You can change
     them." above the existing Delivery footnote. Editing an existing webhook never changes
     delivery settings.
   - Name placeholder "MausBot". The max body label reads "Max body size (bytes)". The custom
     headers footnote lists the reserved names.
   - Any other address: no badge, no settings line, no automatic header.
   - No migration: an address saved earlier with its secret keeps working.
4. **48,000-character guard (MausBot addresses).** Before sending, each part's length as MausBot
   shows it (JSON re-indented with 2 spaces, counted in UTF-16 code units as JavaScript does)
   must stay at or under 47,000 (48,000 less a safety margin). The Markdown is cut into smaller
   parts when needed. If even a part without any Markdown can't fit (for example a huge
   attendee list), or splitting is off and the single body would be cut, the send fails with a
   "Too long for MausBot" status instead of sending. Resends check the same limit.
5. **Part checksum.** Each split part carries `part.sha256`: lowercase hex SHA-256 of the part's
   Markdown chunk (UTF-8, without the end-marker suffix). Additive; `schemaVersion` stays 1.
6. **Receiver helper.** `Scripts/webhook-receiver/assemble_meeting_note.py` (Python 3 standard
   library, nothing MausBot-specific) checks the end marker and `part.sha256`, stores each part
   atomically under `<store>/<sendId>/`, and, under a per-send lock, writes the assembled note
   and a completion record exactly once when every index from 1 to total is present. It prints
   one JSON status line (`waiting`, `complete`, `already_complete`, `mismatch`, `conflict`,
   `invalid`) and flags a `meeting.note.resent` note that already has a completed earlier send.
   See [webhooks.md](webhooks.md).

Out of scope: switching on the real receiving automation, migrating saved endpoints, reply
handling for receivers other than MausBot's reply shape, other payload changes.
