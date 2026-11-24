# quill server

A transcription server for quill on a GPU host on your own network. It labels who spoke: an iPhone room recording reads `speaker 1`, `speaker 2` in place of one `room` label. Decision record: [ADR-003](../docs/decisions/003-remote-transcription-server.md).

It has two parts:

- `quill-vllm`: [Nemotron 3.5 Transcribe 30B-A4B (FP8)](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8) on vLLM. One model gives words, timestamps, and speakers.
- `quill-server`: this package. It takes one track from the Mac, joins its segment files so each voice keeps one number through the whole track, and splits the timed words back per file.

## 1. Install

Tested on a DGX Spark (GB10, Ubuntu 24.04, CUDA 13) with [uv](https://docs.astral.sh/uv/).

1. Install vLLM and NeMo Speech, as on the model card:

   ```sh
   git clone https://github.com/NVIDIA-NeMo/Speech.git ~/nemo-speech && cd ~/nemo-speech
   # The checkout pins 3.12 in .python-version. Use uv's 3.13: Triton builds
   # need Python.h, which the system Python may not have.
   export UV_PYTHON=3.13
   uv venv --python 3.13 .venv
   UV_PROJECT_ENVIRONMENT=$PWD/.venv uv sync --extra asr --extra vllm --locked --no-install-project
   uv pip install --python .venv/bin/python --no-deps -e .
   # Run from outside the checkout: its uv settings exclude OpenCV.
   cd ~ && uv pip install --python ~/nemo-speech/.venv/bin/python --no-deps av==19.0.2 opencv-python-headless==5.0.0.93
   ```

2. Download the checkpoint (35 GB):

   ```sh
   uvx --from huggingface_hub hf download nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8 \
     --local-dir ~/models/Nemotron-3.5-Transcribe-FP8
   ```

3. Install this adapter and both units:

   ```sh
   rsync -a --exclude .venv server/ spark:quill-server/
   ssh spark
   cd ~/quill-server && uv sync --frozen
   cp systemd/*.service ~/.config/systemd/user/
   systemctl --user daemon-reload && systemctl --user enable --now quill-vllm quill-server
   loginctl enable-linger "$USER"   # keep them running while logged out
   ```

   vLLM takes a few minutes to load. `quill-vllm.service` takes 60% of GPU memory; change `--gpu-memory-utilization` to suit the host. On a DGX Spark, the GPU shares memory with everything else: leave room for other services, or the host can run out of memory and stop responding.

4. Publish the adapter to your tailnet with HTTPS:

   ```sh
   tailscale serve --bg --https=8091 http://127.0.0.1:8091
   curl https://<host>.<tailnet>.ts.net:8091/health
   ```

Both servers listen on `127.0.0.1` only and have no authentication. Do not expose them outside a private network. macOS refuses plain HTTP to the adapter (App Transport Security), so use the `tailscale serve` HTTPS address.

## 2. Point the Mac at it

In `~/.config/quill/config.json`:

```json
{
  "transcription": { "engine": "remote", "url": "https://<host>.<tailnet>.ts.net:8091" }
}
```

Run `quill doctor` to check the connection. If the server fails or does not answer, the Mac tries it again after 30 seconds, 2 minutes and 5 minutes. If it is still down, the Mac transcribes the session with local Parakeet and writes the reason to the session's `transcribe.log`.

## 3. Share the GPU host: load the model on demand

`quill-vllm.service` keeps the model loaded, and the model keeps its share of memory. On a host that also runs other models, [llama-swap](https://github.com/mostlygeek/llama-swap) can start Nemotron for the first request and stop it after a quiet period.

1. Use llama-swap in place of `quill-vllm`. Both listen on `127.0.0.1:8092`, so the adapter needs no change:

   ```sh
   systemctl --user disable --now quill-vllm
   mkdir -p ~/.config/llama-swap/models
   cp llama-swap/nemotron-transcribe.sh ~/.config/llama-swap/models/
   cp llama-swap/config.example.yaml ~/.config/llama-swap/config.yaml
   ```

2. Run `llama-swap --config ~/.config/llama-swap/config.yaml --listen 127.0.0.1:8092` as a user service, and make `quill-server.service` start after it in place of `quill-vllm.service`.

What changes for quill:

- **The first transcription after a quiet period is slow.** vLLM needs 5 to 7 minutes to load the model on a DGX Spark (most of that reads 33 GB of weights). The Mac waits up to 30 minutes for one answer, so the request does not fail. Later requests run at about 10 times real time until `ttl` seconds pass without one.
- **`GET /health` answers `ok` while the model is not loaded.** It reports that llama-swap is up, which is what the Mac needs to know before it sends audio.
- **Another model can push Nemotron out.** If llama-swap or a memory guard stops Nemotron during a request, the request fails with a 5xx status. The Mac then tries again, as described in section 2.

## 4. API

| Request | Response |
|---|---|
| `GET /health` | `{"ok": true, "model": "..."}`, or 503 when the model server does not answer |
| `POST /v1/transcribe?diarize=true`, multipart with one `audio` part per segment file, in order | `{"engine", "model", "files": [{"duration", "segments": [{"start", "end", "text", "speaker"}]}]}` |

Times are relative to each file. `speaker` is a 0-based index in order of first appearance across the whole track. It is `null` when `diarize=false` or when the model hears only one voice. The Mac sends `diarize=false` for the `me` track.

## 5. Development

```sh
uv run pytest
```

The tests need no GPU. They cover the grouping rules in `quill_server/align.py` and run the engine against a fake vLLM.

## 6. Known limits

- The model is trained on recordings up to one hour. Longer tracks go in 55-minute windows, and a voice's number can change between windows.
- The speaker prompt from the model card names four tags. More voices than that may share a tag.
