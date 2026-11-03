# Decisions

Product and technical decisions, newest first, with what they rule out. The behaviour itself is
in [spec.md](spec.md).

## 2026-11-04: Soniox STT v6 for dictation and meetings (issue #23)

| Choice | Rejected | Why |
|---|---|---|
| Switch to v6 now | Wait for the 15 Dec 2026 auto-route | We see the format changes in testing rather than in users' dictation. |
| Spoken commands applied by the cleanup rules | A local parser on the transcript | Telling a command from a literal word ("trial period") needs context; a parser would misfire. |
| Raw output stays verbatim | Applying commands without cleanup | Raw mode promises the words as heard. |
| Upgrade only exact previous defaults | Overwrite all saved rules, or never upgrade | Keeps every customisation while unedited installs get the new rule. |
| Auth header fix in this issue | A separate issue | Same file and the same live sessions to test; deadline 15 Jan 2027. |
| Key in the header only, no `api_key` in the start message | Send both during the transition | A live v6 session confirmed the header alone authenticates, and a wrong header key is refused. |
| Agent features unused | Turning on agent text input | They need the agent's own reply text, which dictation and meetings do not have. |
| Recovery terms rebuilt at recovery time from the session's names | Persist the live terms with the session | Same builder policy as the live streams without a new stored field; names, the main win, come from the session either way. |

## 2026-11-03: Meeting webhooks for MausBot automations (issue #20)

| Choice | Rejected | Why |
|---|---|---|
| Add `Idempotency-Key` and `X-Webhook-Event` alongside the existing headers | Rename the `X-WonderWhisper-*` headers | Existing receivers and signature checks keep working. |
| One delivery id string in body and headers | Leave header and body casing different | A receiver comparing them, or a bot reading MausBot's "Delivery ID", sees one value. |
| Move a pasted secret into a Keychain header | Keep it in the URL | URLs sit in plain preferences; header values stay in Keychain. (Endpoints are already left out of settings sync.) |
| Don't migrate saved endpoints | Migrate on load | A saved secret-in-URL address works; migration adds a Keychain write that could lose a working secret, for no gain. |
| MausBot defaults 40,000 bytes / 30 s / 30 s plus a formatted-length guard | Today's 3,800 / 7 s / 30 s, or no split | Few runs per note; 30 s apart usually stays under 3 unfinished runs (retries cover the rest); the guard catches notes where bytes alone would still be cut. |
| `ignored` and `captured` are delivered with a status, no retry | Treat as failure and retry | A retry gets the same answer; the fix is on the receiver. |
| Read at most 4 KB of a 2xx body, never store it | Ignore bodies, as today | Needed to tell these outcomes apart; the cap and no storage keep it safe. |
| Ship a receiver helper and `part.sha256` now | Leave assembly to each receiver after release | A run only sees its own part; without durable assembly a long note arrives as unrelated fragments. The checksum lets the helper prove the bot copied each part exactly. |
| An unsplit send to a MausBot address that would be cut fails with "turn on Split" | Split it anyway | Splitting changes the payload shape the user chose to turn off; failing is honest and the fix is one toggle. |
| Take the status as soon as the response headers arrive (per-task `URLSession` delegate) | `URLSession.bytes(for:)` | A connection that drops after a 2xx status must still count as delivered; the async bytes call can throw before handing back the status. |
