# Quill for iPhone

Records the microphone for in-person meetings and quick notes, then sends
each recording to your Mac through iCloud, where quill transcribes it and
files it next to your Mac recordings.

Requires iOS 18+. See [ADR-002](../docs/decisions/002-ios-capture-companion.md)
for what it does and doesn't do (it can't record phone calls).

## Set up

1. Open `Quill.xcodeproj` in Xcode and sign in under **Xcode → Settings →
   Accounts** with your Apple Developer account.
2. Select the **Quill** and **QuillWidgetsExtension** targets in turn, and under
   **Signing & Capabilities** choose your team. Xcode registers the bundle IDs
   (`com.eggdev.quill`, `com.eggdev.quill.widgets`) and the iCloud container
   (`iCloud.com.eggdev.quill`).
3. Connect your iPhone, choose it as the run destination, and run.
4. On the iPhone: **Settings → Action Button → Shortcut → Quill → Record**.

If you change the bundle ID, change the container in
`Config/Quill.entitlements`, `Outbox.containerID`, and the Mac's
`Config.defaultInbox` (or set `inbox_dir` in the Mac config) to match.

## How it works

- Press the Action Button (or tap Record) to start; press again, or tap Stop
  on the Lock Screen, to finish. A Live Activity shows the elapsed time.
- A phone call or Siri pauses the recording; it resumes on its own as a new
  segment at its true offset, so the gap shows in the transcript.
- A copy of each finished recording goes to iCloud Drive (the app's container,
  `Documents/Inbox`). The Mac imports it into `~/Recordings/<yyyy.MM.dd-HHmm>-iphone/`
  and transcribes it. Speaker labels read `room`: one microphone hears
  everyone.
- Without iCloud, recordings stay on the iPhone and send once it's available.
- Every transcript the Mac makes, for its own recordings too, comes back
  through iCloud. The list groups them by day, and search covers titles and
  transcript text.
- Open a recording to read it. Recordings made on this iPhone keep their
  audio for 30 days after sending: tap a line to play from there, and the
  line being spoken stays highlighted. Mac recordings' audio stays on the Mac.
- The app follows the system's light or dark appearance.

## Develop

```sh
cd ios/QuillKit && swift test       # timeline, metadata, naming — no simulator needed
xcodebuild -project ios/Quill.xcodeproj -scheme Quill \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

The Simulator records from the Mac's microphone but has no iCloud and no
Action Button; test those on a device. To see transcripts there, launch a
debug build with `SIMCTL_CHILD_QUILL_LIBRARY_DIR=<folder>`, a folder of
`<session>/transcript.json` + `meta.json` as the Mac publishes them.
