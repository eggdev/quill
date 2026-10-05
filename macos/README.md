# quill for macOS

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

The macOS implementation is a single Swift binary with a menu-bar tray and no
app bundle.

## Install

```sh
cd quill
./scripts/build-macos
sudo ./scripts/install-macos
quill install --launch-at-login   # optional — runs in the background on login
```

For direct development inside this platform package:

```sh
cd macos
swift build -c release
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

While recording, a floating feather capsule sits at the right edge of the
screen with three live level bars — left is your mic, right is the call's
audio, center is whichever is louder. Flat bars on one side mean that side
isn't being heard. Drag it anywhere (the position is remembered); click it to
stop recording or hide it until the next recording. It stays above full-screen
calls and is excluded from screen sharing, so other participants never see
it. Set `"floating_indicator": false` to turn it off.

## Calendar meetings

quill can start recording on its own when a meeting begins. Choose
**Calendar meetings** in the menu:

- **Off** (default) — record only when you click.
- **Ask when a meeting starts** — the floating feather appears with a red
  record dot and a notification; click it → **Record this meeting** or
  **Skip this meeting**.
- **Record automatically** — recording starts a minute before the meeting,
  with a notification and the floating indicator.

The first time either is chosen, macOS asks for calendar access. quill reads
the calendars already set up in macOS Calendar — iCloud, Google, and
Exchange / Microsoft 365 (add the account under System Settings → Internet
Accounts). Everything is read from the local calendar database; nothing is
sent anywhere.

Which events count: timed events with a video-call link (Zoom, Teams, Google
Meet, Webex, and similar) in the URL, location, or notes, that you haven't
declined. All-day, canceled, and 8 h+ events are skipped, and an invite that
appears on two calendars is recorded once. Set `require_video_link: false` to
include in-person meetings too.

When a meeting recording stops:

- after the scheduled end, once both tracks have been quiet for 2 minutes
  (`stop_after_quiet_seconds`) — a meeting that runs over keeps recording;
- after 10 minutes with no audio at all, at any point;
- an hour past the scheduled end, regardless;
- 30 seconds after the meeting app (Teams, Zoom, …) lets go of the
  microphone, if it held it during the recording — usually the moment you
  leave the call, even before the scheduled end;
- at the start of a back-to-back meeting, which gets its own session (in ask
  mode, quill stops and prompts for the next one).

A meeting triggers once: stop it by hand and it won't restart. Recordings you
start yourself are never stopped automatically — if one overlaps a meeting it
still takes the meeting's title. The meeting is recorded in `meta.json`
(`meeting`) and titles `transcript.md` and the notifications.

### Calls without a calendar event

With calendar meetings on, quill also notices ad-hoc calls: when Zoom,
Teams, Webex, Slack, or FaceTime has held the microphone for 5 seconds, the
floating feather appears with a record dot and a notification ("Teams call
detected") — click it → **Record this call** or **Skip this call**. The
recording is titled "Teams call" and stops 30 seconds after the app releases
the mic (a brief drop or device switch doesn't end it). If a calendar meeting
comes due while an ad-hoc call is being recorded, the recording takes the
meeting's title and stop rules.

Ad-hoc calls always ask by default, even in **Record automatically** mode;
set `calendar.adhoc_calls` to `auto` to record them without asking, or `off`
to ignore them. No prompt appears while anything is recording or while a
calendar meeting is in its window — the call is that meeting.

Browser calls (Meet, Teams on the web) are off by default, since browsers
hold the mic for plenty besides calls; `calendar.browser_calls: true` turns
on Chrome, Arc, Edge, Brave, and Firefox. Safari can't be detected — its
audio runs in a shared WebKit process that isn't attributable to Safari.

Detection reads Core Audio's per-process input state, which needs no
permission and sees only which apps are using the mic, never their audio.

Recording laws differ by state and country, and some require every
participant's consent. Auto-recording doesn't change your obligation to tell
people a call is being recorded.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `mic-002.caf`, `system-002.caf`, … | additional segments, present only if capture had to restart mid-session (see below) |
| `meta.json` | start/end timestamps, duration, per-track segments/offsets, capture status (`complete`/`recovered`/`incomplete`), and the calendar `meeting` if there was one |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Capture recovery

macOS audio routes are not stable for the length of a meeting — connecting or
disconnecting AirPods, or changing the default device, can silently stop a
capture stream. Quill watches both tracks (a one-second watchdog over callback
progress, plus route-change notifications) and, if a track stalls, restarts it
on the current route into a new numbered segment (`mic-002.caf`, …). The
already-recorded segment is never modified.

What you see while recording:

- feather red, `● recording · 28:11` — both tracks healthy;
- feather orange, `◐ recovering microphone · 28:11` — a track stalled and is
  being restarted (up to three attempts);
- feather orange, `⚠ microphone capture lost · 28:14` — recovery failed; you
  get one notification, and the session will be marked incomplete;
- `△ system audio silent` — secondary diagnostic: the system track is running
  but delivering exact digital silence (may be legitimate — nothing playing).

At stop you get a notification if the session was anything other than
`complete`, and the transcript header carries the same status. Transcription
still runs — every segment that has audio is transcribed and merged on the
session clock, with the gap left visible in the timestamps.

After an incident, inspect `meta.json` in the session folder: each track lists
its `segments` (with session-clock start/end offsets and frame counts) and
`interruptions` (when the stall was detected, when capture resumed, how many
attempts it took). `status` tells you whether the track is `complete`,
`recovered` (usable, with a bounded gap), or `incomplete` (audio missing at
the tail or an unrecovered stall).

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook",
  "calendar": {
    "mode": "auto",
    "require_video_link": true,
    "ignore_calendars": ["Birthdays", "Holidays"],
    "lead_seconds": 60,
    "stop_after_quiet_seconds": 120,
    "adhoc_calls": "ask",
    "browser_calls": false
  },
  "floating_indicator": true
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.
- `calendar.mode` — `off` (default), `ask`, or `auto`; the menu's **Calendar
  meetings** submenu writes this key. See [Calendar meetings](#calendar-meetings).
- `calendar.require_video_link` — only events with a video-call link count as
  meetings (default `true`).
- `calendar.ignore_calendars` — calendar names never to record from.
- `calendar.lead_seconds` — how early auto-recording starts (default 60).
- `calendar.stop_after_quiet_seconds` — after a meeting's scheduled end, stop
  once both tracks have been quiet this long (default 120).
- `calendar.adhoc_calls` — calls without a calendar event: `off`, `ask`, or
  `auto`. Defaults to `ask` while `calendar.mode` is on, `off` otherwise.
- `calendar.browser_calls` — count a browser holding the mic as a call
  (default `false`).
- `floating_indicator` — show the floating recording indicator (default
  `true`).

Config changes apply within a few seconds; no restart needed.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models, calendar
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **EventKit** — calendar meetings, read from the local calendar database
- **Core Audio process objects** (`kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyIsRunningInput`) — which meeting apps hold the mic
- **NSStatusItem + a non-activating NSPanel** — the menu bar and the floating
  indicator

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- If calendar meetings never start, check System Settings → Privacy &
  Security → Calendars (quill needs **Full Access** — video links live in
  event notes) and that the account shows up in the Calendar app. `quill
  doctor` reports the access state.
- When quill runs from a terminal, macOS attributes microphone and calendar
  permissions to the terminal app rather than quill; the LaunchAgent gets its
  own.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
