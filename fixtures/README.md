# Fixtures

Cross-platform compatibility fixtures. Each platform's tests read these files
directly, so a change here is a contract change for every platform.

| Path | Contract |
|---|---|
| `sessions/iphone-room/meta.json` | `meta.json` schema v2 as the iPhone writes it: one `mic` track with speaker `room`, two segments around a recovered interruption. The iPhone tests build it; the macOS tests import and read it. |
| `sessions/iphone-room/transcript.json` | `transcript.json` as the Mac writes it for that session, after the phone call gap. The macOS tests decode it with the Mac's `Transcript`; the iPhone tests read it for the transcript screen. |
