# ADR-002 :: iOS capture companion

Last updated: `2026.10.26`

> Add an `ios/` platform root for an iPhone app that records the microphone
> and hands each finished session to the Mac through iCloud. The iPhone
> records; the Mac transcribes and keeps every recording in one place.

## 1. Decision

- The iPhone app records one microphone track into a session folder in the
  shared `meta.json` schema v2 format, with speaker `room`: one microphone
  hears everyone present.
- Recording starts and stops from the Action Button through an
  `AudioRecordingIntent`, with a Live Activity for the length of the
  recording, as iOS requires.
- A finished session moves into the app's iCloud container
  (`Documents/Inbox`). The Mac imports complete sessions from there into its
  recordings root and transcribes them with its existing engine.
- No transcription runs on the iPhone. The Mac publishes every transcript
  (and its meta.json, never audio) to the container's `Documents/Library`, so
  the iPhone can read the whole archive.
- The iPhone keeps its own recordings' audio for 30 days after sending, for
  playback alongside the transcript.

## 2. Feasibility

- **In-person meetings and notes:** supported. iOS allows background
  microphone recording with the `audio` background mode, and a phone call or
  Siri interrupting it is recorded as an interruption with a new segment on
  resume, which the schema already describes.
- **Phone calls:** not supported. iOS gives the microphone to the call and
  interrupts other apps' recording, including on speakerphone. Calls are
  recorded on the Mac (Continuity) or by the Phone app's own call recording.
- **Action Button cold start:** unverified. Reports suggest iOS may refuse to
  activate a recording audio session for an app launched in the background.
  The fallback is an intent that brings the app forward and starts recording.
  This needs testing on a device.

## 3. Rationale

Transcribing on the Mac keeps one engine, one output, and one archive. An
iPhone engine would add a second model, a second set of transcripts to
reconcile, and battery cost, for no benefit when the Mac is always on. iCloud
works from anywhere without the Mac being reachable; a direct network upload
would only work at home.

## 4. Design Implications

- Compatibility is held by `fixtures/sessions/iphone-room/meta.json`: the
  iPhone tests build it and the macOS tests import and read it.
- iPhone logic that does not touch the system (timeline, metadata, naming)
  lives in the `QuillKit` package so `swift test` covers it on a Mac.
- The Mac reads the iCloud container path directly; `inbox_dir` in the Mac
  config overrides it.

## 5. When to Revisit

Reconsider if the Mac is not reliably on, if iCloud sync proves too slow for
how soon transcripts are needed, or if on-device transcription becomes good
enough to make the round trip unnecessary.
