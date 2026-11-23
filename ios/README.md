# Quill for iPhone

Records the microphone for in-person meetings and quick notes. Each finished
recording goes to your hub: the one always-on Mac that keeps every recording
and transcribes it. The app also shows every transcript the hub has, from
your Macs as well as this iPhone.

Requires iOS 18+. See [ADR-002](../docs/decisions/002-ios-capture-companion.md)
for what it does and doesn't do (it can't record phone calls). The hub API is
[docs/hub-api.md](../docs/hub-api.md).

## Set up

1. Open `Quill.xcodeproj` in Xcode and sign in under **Xcode → Settings →
   Accounts** with your Apple Developer account.
2. Select the **Quill** and **QuillWidgetsExtension** targets in turn, and under
   **Signing & Capabilities** choose your team. Xcode registers the bundle IDs
   (`com.eggdev.quill`, `com.eggdev.quill.widgets`).
3. Connect your iPhone, choose it as the run destination, and run.
4. On the iPhone: **Settings → Action Button → Shortcut → Quill → Record**.

## Connect to your hub

The hub is reached over your private Tailscale network. Install Tailscale on
the iPhone and sign in to the same tailnet as the hub Mac.

1. In Quill, tap the gear button, then enter the **Hub address**, for
   example `https://<host>.<tailnet>.ts.net:8090`. If you leave out
   `https://`, Quill adds it.
2. Tap **Check Connection**. "Connected to your hub" means it works.

Tailscale must be connected whenever Quill sends or reads. If it isn't, the
list shows the recordings and transcripts it saved last time, with a note
that it can't reach your hub.

## How it works

- Press the Action Button (or tap Record) to start; press again, or tap Stop
  on the Lock Screen, to finish. A Live Activity shows the elapsed time.
- A phone call or Siri pauses the recording; it resumes on its own as a new
  segment at its true offset, so the gap shows in the transcript.
- When a recording stops, Quill uploads it to the hub. The upload keeps
  going after you lock the phone or leave the app. The hub then transcribes
  it. Speaker labels read `room`: one microphone hears everyone.
- If the hub can't be reached, the recording waits on the iPhone and sends
  later: when you open the app, when you stop another recording, or when
  the open app finds the hub again. Nothing is transcribed on the iPhone.
- The list shows every session on the hub, grouped by day. Each row shows
  where it is: sending, transcribing, transcribed, or failed. Search covers
  titles and transcript text. Transcripts download in the background after
  each refresh, so search works offline too.
- Open a recording to read it. Recordings made on this iPhone keep their
  audio for 30 days after the hub has them: tap a line to play from there,
  and the line being spoken stays highlighted. Audio recorded on other
  devices stays on the hub.
- The app follows the system's light or dark appearance.

What the iPhone keeps:

- Each recording folder holds `.hub.json`: the session id (made once, used
  on every retry) and which uploads are done. A recording counts as sent
  only after the hub accepts the commit.
- Folders sent through iCloud by older versions have a `.sent` marker. That
  marker only means iCloud took the folder, not that a Mac imported it. Once
  Quill has read the hub's list, a marked folder the hub doesn't have is
  uploaded like a new recording. Its audio is never deleted until the hub
  has it.
- The session list and downloaded transcripts are kept in
  `Application Support/Hub/`.

## Develop

```sh
cd ios/QuillKit && swift test       # timeline, metadata, hub models and sync — no simulator needed
xcodebuild -project ios/Quill.xcodeproj -scheme Quill \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

The Simulator records from the Mac's microphone but has no Action Button;
test that on a device. To see transcripts in the Simulator, run a hub on your
Mac and launch a debug build with
`SIMCTL_CHILD_QUILL_HUB_URL=http://localhost:8090`, or set `QUILL_HUB_URL` in
the scheme's environment. The Simulator shares the Mac's network, so
`localhost` reaches the hub directly. In debug builds this setting overrides
the address saved in Settings. Plain `http://` works only for local
addresses; anything else needs `https://`.
