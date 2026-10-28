# ADR-003 :: Remote transcription server

Last updated: `2026.10.28`

> Add a `server/` root: an HTTP service on a GPU host on the user's own
> network that transcribes and labels speakers. The Mac sends it each audio
> file and falls back to its local engine when the host can't be reached.

## 1. Decision

- `server/` is a Python service (NVIDIA NeMo): Parakeet TDT 0.6B v2 for words
  and Sortformer for speakers. It runs on a DGX Spark under a user systemd
  unit and publishes on the tailnet through `tailscale serve` HTTPS.
- The Mac gets a `remote` engine (`transcription.engine`, `transcription.url`).
  It uploads each segment file unchanged and reads back timed segments with an
  optional speaker index.
- A diarized voice gets a label inside its track: `speaker N` on the iPhone
  `room` track, `them N` on a call's system track. The `me` track is never
  diarized.
- If the server can't be reached or fails, the coordinator transcribes the
  session with local Parakeet and logs why. The transcript records the engine
  that made it.

## 2. Rationale

The iPhone's one microphone hears everyone in the room, so its transcripts
had one speaker for all voices. Speaker diarization needs a model the Core ML
port does not supply, and a GPU host runs it in seconds. The Mac keeps the
same ASR model locally, so a transcript reads the same whichever engine made
it, apart from the speaker labels.

The recording still goes only to machines the user owns. "Local-only"
in the shared contract now means the user's own network, not one machine.

## 3. Alternatives

- **WhisperX (Whisper + pyannote):** Whisper can hallucinate text on silence,
  and pyannote needs a gated Hugging Face token.
- **Canary-Qwen 2.5B:** NVIDIA lists it as more accurate for English. Its
  support for word timestamps, which speaker matching needs, is unconfirmed.
- **Diarization on the Mac:** possible with FluidAudio's diarizer later; it
  would remove the second host. Revisit if the server is a burden.

## 4. When to Revisit

Reconsider if an on-device diarizer is good enough, if Canary-class accuracy
with word timestamps becomes available, or if per-file speaker numbering
across interruptions causes confusion.
