"""Model loading and inference. Both models stay resident on the GPU (about
3 GB together); requests run one at a time behind a lock."""

import logging
import tempfile
import threading
from pathlib import Path

import av
import numpy as np
import soundfile as sf
import torch
from omegaconf import open_dict

from .align import Segment, Word, parse_turns, segments

ASR_MODEL = "nvidia/parakeet-tdt-0.6b-v2"
DIAR_MODEL = "nvidia/diar_streaming_sortformer_4spk-v2"
SAMPLE_RATE = 16_000

# Full attention handles about 24 minutes in one pass. Past that, local
# attention keeps memory linear in length, at a small accuracy cost.
FULL_ATTENTION_MAX_SECONDS = 20 * 60

log = logging.getLogger("quill_server")


def decode(data: bytes) -> np.ndarray:
    """Any container ffmpeg reads (CAF/AAC from quill) to 16 kHz mono float32."""
    with tempfile.NamedTemporaryFile() as f:
        f.write(data)
        f.flush()
        with av.open(f.name) as container:
            resampler = av.AudioResampler(format="flt", layout="mono", rate=SAMPLE_RATE)
            chunks = [
                out.to_ndarray().reshape(-1)
                for frame in container.decode(audio=0)
                for out in resampler.resample(frame)
            ]
            chunks += [out.to_ndarray().reshape(-1) for out in resampler.resample(None)]
    return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)


class Engine:
    def __init__(self):
        from nemo.collections.asr.models import ASRModel, SortformerEncLabelModel

        self.lock = threading.Lock()
        self.asr = ASRModel.from_pretrained(ASR_MODEL).eval()
        # The CUDA-graph greedy decoder hits an illegal memory access on GB10
        # (sm_121) with torch 2.14 + CUDA 13; the plain loop is fast enough.
        decoding = self.asr.cfg.decoding
        with open_dict(decoding):
            decoding.greedy.use_cuda_graph_decoder = False
        self.asr.change_decoding_strategy(decoding, verbose=False)
        self.local_attention = False

        self.diar = SortformerEncLabelModel.from_pretrained(DIAR_MODEL).eval()
        # Streaming settings from the model card for long-form audio.
        m = self.diar.sortformer_modules
        m.chunk_len = 340
        m.chunk_right_context = 40
        m.fifo_len = 40
        m.spkcache_update_period = 300
        m.spkcache_len = 188

    @property
    def model(self) -> str:
        return f"{ASR_MODEL.split('/')[1]}+{DIAR_MODEL.split('/')[1]}"

    def transcribe(self, pcm: np.ndarray, diarize: bool) -> tuple[float, list[Segment]]:
        duration = len(pcm) / SAMPLE_RATE
        if duration == 0:
            return 0.0, []
        with self.lock, tempfile.TemporaryDirectory() as tmp, torch.inference_mode():
            wav = str(Path(tmp) / "audio.wav")
            sf.write(wav, pcm, SAMPLE_RATE)
            self._set_attention(duration > FULL_ATTENTION_MAX_SECONDS)
            result = self.asr.transcribe([wav], timestamps=True, batch_size=1, verbose=False)[0]
            words = [Word(w["word"], w["start"], w["end"]) for w in result.timestamp["word"]]
            turns = []
            if diarize and words:
                turns = parse_turns(self.diar.diarize(audio=[wav], batch_size=1, verbose=False)[0])
            log.info("%.0fs audio · %d words · %d turns", duration, len(words), len(turns))
            return duration, segments(words, turns)

    def _set_attention(self, local: bool):
        if local == self.local_attention:
            return
        if local:
            self.asr.change_attention_model("rel_pos_local_attn", [256, 256])
            self.asr.change_subsampling_conv_chunking_factor(1)
        else:
            self.asr.change_attention_model("rel_pos")
            self.asr.change_subsampling_conv_chunking_factor(-1)
        self.local_attention = local
