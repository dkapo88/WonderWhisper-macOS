Groq Streaming Chunking

Overview

- Multi‑second chunking with overlap significantly improves accuracy over micro‑chunks.
- This provider now defaults to 6.0s chunks with 1.2s overlap and sequential uploads.
- Merging uses punctuation‑insensitive token overlap (up to 24 tokens) for boundary de‑dup.

Tunable Keys (UserDefaults)

- groq.stream.chunkSeconds (Double)
  - Default 6.0; clamps to 2.0–15.0
- groq.stream.overlapSeconds (Double)
  - Default 1.2; clamps to 0.5–4.0
- groq.stream.maxInflight (Int)
  - Default 1; clamps to 1–3
- groq.stream.promptTrailChars (Int)
  - Default 200; clamps to 80–600
- groq.stream.warmupSeconds (Double)
  - Default 0.30; clamps to 0.15–0.60

Notes

- For faster first tokens with acceptable accuracy, try 4–6s chunks, 1–1.5s overlap.
- For higher accuracy and fewer boundary artifacts, try 8–12s chunks, 1.5–2.5s overlap.
- Keep in‑flight uploads sequential (1) to ensure the next chunk’s prompt includes latest text.
- Based on Groq community guidance for chunking longer audio (see community.groq.com topic 162).

