# Quill hub API

Version: `1` · Last updated: `2026.11.21`

The hub is one always-on Mac that keeps every recording. Other devices
(clients) upload finished recordings to it and read transcripts back from it.
Decision record: [ADR-004](decisions/004-hub.md).

This file is the contract between the hub (`macos/`, `hub.serve`) and its
clients (`macos/` with `hub.url`, and `ios/`). Change it before changing
either side.

## 1. Transport

- HTTP/1.1. The hub listens on `127.0.0.1:<port>` only (default port `8090`).
  `tailscale serve --bg --https=8090 http://127.0.0.1:8090` publishes it to
  the tailnet with HTTPS. Clients use the `https://<host>.<tailnet>.ts.net:8090`
  address.
- There is no authentication in the hub. The tailnet is the boundary. Do not
  publish the hub outside a private network.
- Request and response bodies are JSON with `snake_case` keys, except file
  uploads and downloads, which are raw bytes.
- Times are ISO 8601 UTC strings (`2026-11-21T14:30:00Z`).
- An error response is `{"error": "<code>", "message": "<text for a log>"}`
  with a 4xx or 5xx status. Clients branch on `error`, never on `message`.

## 2. Session object

```json
{
  "id": "0B5C6E0E-6E0B-4B0C-9A39-1C5B0C2E7D11",
  "name": "2026.11.21-0930-macbook",
  "device": { "id": "7F1D…", "name": "Sam's MacBook Pro", "kind": "mac" },
  "title": "Weekly sync",
  "started": "2026-11-21T14:30:00Z",
  "duration_seconds": 1830,
  "status": "transcribed",
  "error": null,
  "engine": "nemotron",
  "model": "NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8",
  "preview": "Ideally, what I have for next week is…",
  "revision": 42,
  "updated": "2026-11-21T15:02:11Z"
}
```

| Field | Meaning |
|---|---|
| `id` | UUID string the client makes before its first upload. It never changes. The hub returns ids in upper case; clients make them as upper-case UUID strings (`UUID().uuidString`). |
| `name` | The session's folder name on the hub. Unique. Display only. |
| `device.id` | A UUID the client makes once and keeps for the life of the install. |
| `device.kind` | `mac` or `iphone`. |
| `title` | The calendar meeting's title from `meta.json`, or `null`. |
| `status` | `queued`, `transcribing`, `transcribed`, or `failed`. |
| `error` | One line of text when `status` is `failed`, else `null`. |
| `engine`, `model` | From `transcript.json`. `null` until transcribed. |
| `preview` | The first 200 characters of transcript text. Empty until transcribed. |
| `revision` | A hub-wide counter. Every change to a session gives it a new, higher `revision`. |

## 3. Endpoints

### `GET /health`

`200 {"ok": true, "service": "quill-hub", "api": 1, "catalog": "5E2A…"}`

`catalog` is the catalog id described under `GET /v1/sessions`.

### `PUT /v1/uploads/{id}/{file}`

Uploads one audio file of session `{id}`. The body is the raw file. The hub
writes it to a staging area and replaces any earlier upload of the same file,
so a client retries by sending the whole file again.

- `{id}` is the session id. `400 bad_request` when it is not a UUID.
- `{file}` is a segment file name from the session's `meta.json`
  (`mic.caf`, `system-002.caf`, `mic.wav`). Letters, digits, `.`, `_` and `-`
  only, no leading `.`, with an audio extension (`caf`, `wav`, `m4a`).
  Otherwise `400 bad_file_name`.
- `200 {"file": "mic.caf", "bytes": 3512345}` when the whole body is stored.
- `409 already_committed` when session `{id}` was committed before, also when
  the commit happens while this upload is still arriving.

### `POST /v1/sessions`

Commits an uploaded session. The hub then owns the recording and queues it
for transcription.

```json
{
  "id": "0B5C6E0E-…",
  "name": "2026.11.21-0930",
  "device": { "id": "7F1D…", "name": "Sam's MacBook Pro", "kind": "mac" },
  "files": [ { "name": "mic.caf", "bytes": 3512345 }, { "name": "system.caf", "bytes": 4100200 } ],
  "meta": { "schema_version": 2, "…": "the session's meta.json, unchanged" }
}
```

- `name` is the client's local folder name: letters, digits, `.`, `_` and `-`
  only, with no leading `.`. The hub derives its own unique folder name from
  it (it adds a short device tag when the name has none, and a counter on a
  collision). A name ending in `-iphone` or `-iphone-N` already has a tag.
- `files` lists every segment file in `meta` with its size in bytes. Every
  segment that `meta` names must be uploaded: a client that no longer has one
  of them cannot commit the session (partial sessions are not supported in
  version 1).
- `201` with the session object when the commit succeeds.
- `200` with the session object when `id` was committed before. A client that
  did not see the first answer can send the commit again.
- `409 {"error": "missing_files", "missing": ["system.caf"]}` when a file is
  absent from staging, or its uploaded size differs from its `bytes` in
  `files` (a size mismatch counts as missing). The client uploads those files
  again and repeats the commit.
- `400 bad_request` when the body does not decode, `id` is not a UUID, `name`
  has other characters, `meta.schema_version` is below 2, or `files` does not
  cover every segment in `meta`.
- `400 bad_file_name` when `meta` names a segment file that breaks the file
  name rule above.

### `GET /v1/sessions?after={revision}&limit={n}`

Lists sessions in ascending `revision` order. `after` defaults to `0` (every
session). `limit` defaults to `500`, which is also the maximum.

```json
{ "sessions": [ { "…": "session object" } ], "revision": 42, "catalog": "5E2A9C1D-3F4B-4E8A-9B6C-7D1E2F3A4B5C" }
```

`revision` is the hub's current counter: the highest revision the hub has
given any change. It is the same whatever `after` and `limit` were.

`catalog` is the catalog id: an upper-case UUID string the hub makes when it
creates its catalog, and never changes afterwards. A rebuilt catalog (for
example after its database file was deleted) has a new id, and its
revisions start again, so revisions from different catalogs can't be
compared.

- **Paging.** A full page (`limit` sessions) means more may follow. Ask again
  with `after` set to the `revision` of the last session in that page, not
  the top-level `revision`. Repeat while pages are full.
- **Storing the cursor.** Once a page is not full, the client has every
  change. It stores the top-level `revision` and sends it as `after` next
  time.
- **Rebuilt catalog.** The client stores `catalog` with its cursor. When the
  `catalog` in an answer differs from the stored one, or the client has none
  stored, the client discards its cached sessions and its cursor, and asks
  again with `after=0`.
- `400 bad_request` when `after` or `limit` is not a whole number, or `limit`
  is `0`.

### `GET /v1/sessions/{id}`

`200` with the session object.

Every `/v1/sessions/{id}…` route answers `404 not_found` when `{id}` is not
a known session (also when it is not a UUID).

### `GET /v1/sessions/{id}/meta`

`200` with the session's `meta.json`.

### `GET /v1/sessions/{id}/transcript`

`200` with `transcript.json` (the canonical transcript: `created_at`,
`engine`, `model`, `segments[]` of `start_ms`, `end_ms`, `speaker`, `text`).
`404 not_ready` until the session is `transcribed`.

### `GET /v1/sessions/{id}/transcript.md`

`200 text/markdown` with the readable transcript. `404 not_ready` as above.

### `GET /v1/sessions/{id}/audio/{file}`

`200` with the audio file, or `206` for a `Range` request (single ranges).
`{file}` is a segment file name from the session's `meta.json`.
`400 bad_file_name` when it breaks the file name rule, `404 not_found` when
`meta.json` does not name it. A `Range` header with several ranges gets the
whole file (`200`); a range that starts past the end gets
`416` with `Content-Range: bytes */<size>`.

## 4. Client rules

- A client keeps a recording until the commit returns `200` or `201`. Only
  then does it mark the recording as sent.
- A client makes the session `id` once, stores it next to the recording, and
  uses the same `id` on every retry.
- The hub is the only device that transcribes. A client that cannot reach the
  hub keeps the recording and tries again later. It does not transcribe
  locally.
- A client finds new and changed sessions with `GET /v1/sessions?after=`. It
  does not poll single sessions on a timer, except a Mac client that waits for
  the transcript of a recording it just sent.

## 5. Reserved

Deleting sessions, renaming speakers, summaries, and full-text search are not
in version 1. New fields may appear in any object. Clients ignore fields they
do not know.
