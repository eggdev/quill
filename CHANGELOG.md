# Changelog

## Unreleased

- Added the hub (ADR-004, `docs/hub-api.md`): one always-on Mac with
  `hub.serve` keeps every recording, transcribes it, and serves an HTTP API on
  `127.0.0.1` for `tailscale serve` to publish on the tailnet. A SQLite
  catalog with a revision counter tells clients what changed; the session
  folders stay the source of truth, and the catalog is rebuilt from them at
  every start, including recordings made before the hub.
- Added Mac clients (`hub.url`): a Mac uploads each finished recording to the
  hub instead of transcribing it, waits for the transcript, and saves it next
  to the audio. When the hub is unreachable, recordings wait on the Mac and
  upload later. The menu shows upload progress. A Mac that becomes a client
  also sends the recordings it transcribed itself, one at a time and after
  any new recording, and takes the hub's transcript in their place.
- When the transcription server fails or does not answer, quill now tries it
  again after 30 seconds, 2 minutes and 5 minutes before it transcribes the
  session locally. A server that restarts, or that loads its model on demand,
  no longer costs a session its speaker labels.
- Added `server/llama-swap/`: a setup that loads the Nemotron model on demand
  and unloads it when idle, for a GPU host that also runs other models.
- Added `scripts/install-ios`: builds Quill for iPhone, signs it, and installs
  it on a paired iPhone in one step. The Apple Developer team now comes from
  `ios/Config/Local.xcconfig`, which is not in git.
- `quill doctor` reports the hub role, the hub's catalog, and, on a client,
  whether the hub answers.
- Added Quill for iPhone (`ios/`): records the microphone from the Action
  Button with a Live Activity, pauses and resumes around phone calls as
  separate segments, and uploads each finished recording to the hub.
- The iPhone app lists every transcript from the hub, the Mac's included,
  grouped by day and searchable. Recordings made on the iPhone play back with
  the transcript: tap a line to play from it. A live level meter shows the
  microphone while recording.
- Added `fixtures/sessions/iphone-room/` (`meta.json`, `transcript.json`), the
  session contract shared by the iPhone and the Mac.
- Added calendar-driven recording on macOS: quill reads meetings from macOS
  Calendar through EventKit and either starts recording when a meeting with a
  video link begins (`auto`) or offers to (`ask`). Meeting recordings stop
  once the call goes quiet after its scheduled end, hand over to a
  back-to-back meeting, and never restart after being stopped by hand.
- Added a floating recording indicator: a draggable capsule with live mic and
  system-audio level bars, visible across Spaces and full-screen apps and
  excluded from screen sharing. Clicking it stops the recording. In ask mode
  it becomes a labeled "Record “…”?" prompt with a ✕ to skip, which expires
  after 10 minutes unanswered.
- Added ad-hoc call detection: when Zoom, Teams, Webex, Slack, or FaceTime
  holds the microphone with no calendar meeting due, quill offers to record
  the call (or records it, with `calendar.adhoc_calls: "auto"`) and stops 30 s
  after the app releases the mic. The same signal now ends calendar-meeting
  recordings as soon as the call does.
- Recorded the calendar meeting in `meta.json` (optional `meeting` field) and
  used its title for the transcript and notifications.

## 0.1.3 - 2026-08-04

- Fixed macOS route changes silently truncating capture: both tracks now have
  callback-progress health monitoring, route-change observation, and automated
  recovery that restarts a stalled track on the current audio route into a new
  numbered segment without touching audio already written.
- Introduced session metadata schema v2 (`tracks[].segments[]` with monotonic
  session-clock offsets, interruption records, and a
  complete/recovered/incomplete status); v1 sessions remain transcribable.
- Made the menu bar and notifications surface recovering, degraded, and
  incomplete capture instead of always showing a healthy recording, and
  carried the capture status into the readable transcript header.
- Added a deterministic macOS test suite covering the health state machine,
  recovery orchestration, stop races, schema compatibility, and
  offset-preserving transcript merges.
- Organized Quill as a multiplatform repository with native macOS, Windows,
  and Linux platform roots, stable macOS build scripts, and an explicit shared
  architecture boundary.

## 0.1.2 - 2026-08-02

- Made Windows WAV checkpoints durably order PCM and header updates so an
  interrupted recording remains decodable without declaring unwritten audio.
- Added subprocess crash tests that abort at every checkpoint boundary and
  verify the resulting files with an independent WAV decoder.

## 0.1.1 - 2026-08-02

- Fixed Windows capture startup so recording is reported only after the WAV
  file and WASAPI stream are ready.
- Resolved audio renderer processes to their user-facing application roots
  without broadening capture into shell, terminal, or service processes.
- Made process-loopback recording stop with a diagnostic when its target exits
  instead of silently continuing against an obsolete PID.
