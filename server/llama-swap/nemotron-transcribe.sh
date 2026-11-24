#!/usr/bin/env bash
# Nemotron 3.5 Transcribe for quill, started on demand by llama-swap.
# Same flags as systemd/quill-vllm.service, except a smaller memory share
# (0.33 instead of 0.60) so it can run next to another model. At 0.33 the KV
# cache still fits about 11 concurrent 64k-token requests; --max-num-seqs is 4.
# llama-swap sets PORT and GPU_UTIL (see config.example.yaml).
set -euo pipefail
cd "$HOME/nemo-speech"
# flashinfer compiles kernels for the GPU on first start: it needs ninja (venv) and nvcc.
export PATH="$HOME/nemo-speech/.venv/bin:/usr/local/cuda/bin:/usr/bin:/bin"
export VLLM_PLUGINS=nemo_speechlm
# Each parallel kernel compile can take several GB of the shared memory.
export MAX_JOBS=4
# Recordings up to one hour (the default is 600 seconds).
export VLLM_MAX_AUDIO_DECODE_DURATION_S=3600
export VLLM_MAX_AUDIO_CLIP_FILESIZE_MB=180
# Word timestamps require the V1 model runner.
export VLLM_USE_V2_MODEL_RUNNER=0
exec "$HOME/nemo-speech/.venv/bin/vllm" serve "$HOME/models/Nemotron-3.5-Transcribe-FP8" \
  --served-model-name nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8 nemotron-transcribe \
  --host 127.0.0.1 --port "${PORT:-18092}" \
  --trust-remote-code --dtype bfloat16 --kv-cache-dtype auto --gpu-memory-utilization "${GPU_UTIL:-0.33}" \
  --max-model-len 65536 --max-num-batched-tokens 4096 --max-num-seqs 4 \
  --enable-chunked-prefill --no-enable-prefix-caching \
  --use-replayssm --mamba-backend flashinfer --mamba-cache-mode none \
  --mm-processor-cache-gb 0 --no-async-scheduling \
  --limit-mm-per-prompt '{"audio":{"count":1,"length":57600000}}' \
  --speculative-config '{"method":"mtp","num_speculative_tokens":8}' \
  --reasoning-parser nemotron_v3 \
  --trust-request-mm-kwargs \
  --middleware nemo.collections.speechlm2.vllm.salm.ctc_serving.ctc_timestamp_middleware
