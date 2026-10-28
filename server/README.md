# quill server

A transcription server for quill on a GPU host on your own network. It adds speaker labels: an iPhone room recording reads `speaker 1`, `speaker 2` in place of one `room` label. Decision record: [ADR-003](../docs/decisions/003-remote-transcription-server.md).

- Words and timestamps: [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), the same model the Mac runs locally.
- Speakers: [Streaming Sortformer 4spk v2](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2), up to 4 voices per file.

On a DGX Spark, 12 minutes of audio takes about 15 seconds. Both models stay on the GPU and use about 3 GB.

## 1. Install

Tested on a DGX Spark (GB10, Ubuntu 24.04, CUDA 13) with [uv](https://docs.astral.sh/uv/):

```sh
rsync -a --exclude .venv server/ spark:quill-server/
ssh spark
cd ~/quill-server && uv sync --frozen
cp systemd/quill-server.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now quill-server
loginctl enable-linger "$USER"   # keep it running while logged out
```

The first start downloads the two models (about 1.3 GB) from Hugging Face.

The server listens on `127.0.0.1:8091` only. Publish it to your tailnet with HTTPS:

```sh
tailscale serve --bg --https=8091 http://127.0.0.1:8091
curl https://<host>.<tailnet>.ts.net:8091/health
```

The server has no authentication. Do not expose it outside a private network. macOS refuses plain HTTP to it (App Transport Security), so use the `tailscale serve` HTTPS address.

## 2. Point the Mac at it

In `~/.config/quill/config.json`:

```json
{
  "transcription": { "engine": "remote", "url": "https://<host>.<tailnet>.ts.net:8091" }
}
```

Run `quill doctor` to check the connection. If the server is down, the Mac transcribes the session with local Parakeet and writes the reason to the session's `transcribe.log`.

## 3. API

| Request | Response |
|---|---|
| `GET /health` | `{"ok": true, "model": "..."}` |
| `POST /v1/transcribe?diarize=true`, body: raw audio bytes (any format ffmpeg reads) | `{"engine", "model", "duration", "segments": [{"start", "end", "text", "speaker"}]}` |

`speaker` is a 0-based index in order of first appearance. It is `null` when `diarize=false` or when the diarizer finds only one voice. The Mac sends `diarize=false` for the `me` track.

## 4. Development

```sh
uv run pytest
```

The tests cover the word-to-speaker rules in `quill_server/align.py` and need no GPU.

## 5. Known limits

- The CUDA-graph decoder in NeMo crashes on GB10 (`illegal memory access`), so the server turns it off.
- Speaker numbers restart in each segment file. After an interruption splits a recording, the same person can get a different number.
- A speaker change in the middle of a sentence can land a few words early or late.
