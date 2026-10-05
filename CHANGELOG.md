# Changelog

## Unreleased

- Added calendar-driven recording on macOS: quill reads meetings from macOS
  Calendar through EventKit and either starts recording when a meeting with a
  video link begins (`auto`) or offers to (`ask`). Meeting recordings stop
  once the call goes quiet after its scheduled end, hand over to a
  back-to-back meeting, and never restart after being stopped by hand.
- Added a floating recording indicator: a draggable capsule with live mic and
  system-audio level bars, visible across Spaces and full-screen apps and
  excluded from screen sharing. Clicking it stops the recording or answers
  the meeting prompt.
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
