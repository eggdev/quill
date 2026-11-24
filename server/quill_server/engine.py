"""One track to Nemotron 3.5 Transcribe (served by vLLM) and back.

A track's segment files are joined into one recording, so the model sees
the whole conversation and keeps each voice's tag across an interruption.
The timed words then split back into the files they came from.
"""

import base64
import io
import logging
import os
import re
import tempfile
import wave
from dataclasses import dataclass

import av
import httpx
import numpy as np

from .align import Segment, Word, collapse_loops, number_speakers, segments

VLLM_URL = os.environ.get("QUILL_VLLM_URL", "http://127.0.0.1:8092")
MODEL = os.environ.get("QUILL_MODEL", "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-FP8")
SAMPLE_RATE = 16_000

# The model is trained on recordings up to one hour. Longer tracks go in
# windows; a voice's number can change from one window to the next.
WINDOW_SECONDS = 55 * 60

# Prompts from the model card's prompt guide. Speaker tags make the model
# attribute every turn; without them the transcript aligns as one speaker.
SPEAKERS_PROMPT = (
    "Transcribe this audio with punctuation and capitalization. "
    "Include all spoken words and verbal fillers. "
    "Write numbers in their standard written form. "
    "Put speaker tags <spk:0> <spk:1> <spk:2> <spk:3> on the transcription."
)
SINGLE_PROMPT = (
    "Transcribe this audio with punctuation and capitalization. "
    "Include all spoken words and verbal fillers. "
    "Write numbers in their standard written form."
)

log = logging.getLogger("quill_server")


class AudioError(ValueError):
    """The upload can't be decoded."""


@dataclass
class FileResult:
    duration: float
    segments: list[Segment]


def decode(data: bytes) -> np.ndarray:
    """Any container ffmpeg reads (CAF/AAC from quill) to 16 kHz mono float32."""
    try:
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
    except av.error.FFmpegError as e:
        raise AudioError(str(e)) from e
    return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)


def wav(pcm: np.ndarray) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())
    return out.getvalue()


def speaker_index(tag) -> int | None:
    """The model's tag for a word: an int, or text such as "<spk:1>"."""
    if tag is None or isinstance(tag, int):
        return tag
    m = re.search(r"\d+", str(tag))
    return int(m.group()) if m else None


class Engine:
    def __init__(self, client: httpx.Client | None = None):
        self.client = client or httpx.Client(base_url=VLLM_URL, timeout=httpx.Timeout(1800, connect=5))

    @property
    def model(self) -> str:
        return MODEL.split("/")[-1]

    def health(self) -> bool:
        try:
            return self.client.get("/health").status_code == 200
        except httpx.HTTPError:
            return False

    def transcribe(self, files: list[bytes], diarize: bool) -> list[FileResult]:
        pcms = [decode(f) for f in files]
        starts = np.cumsum([0] + [len(p) for p in pcms]) / SAMPLE_RATE
        track = np.concatenate(pcms) if pcms else np.zeros(0, dtype=np.float32)

        words: list[Word] = []
        window = WINDOW_SECONDS * SAMPLE_RATE
        for offset in range(0, len(track), window):
            words += self._words(track[offset : offset + window], offset / SAMPLE_RATE, diarize)
        words = number_speakers(collapse_loops(words))
        log.info("%.0fs audio in %d file(s) · %d words", starts[-1], len(files), len(words))

        results = []
        for i, pcm in enumerate(pcms):
            start, end = starts[i], starts[i + 1]
            mine = [
                Word(w.text, w.start - start, w.end - start, w.speaker)
                for w in words
                if start <= w.start < end or (i == len(pcms) - 1 and w.start >= end)
            ]
            results.append(FileResult(len(pcm) / SAMPLE_RATE, segments(mine)))
        return results

    def _words(self, pcm: np.ndarray, offset: float, diarize: bool) -> list[Word]:
        if len(pcm) < SAMPLE_RATE // 10:
            return []
        audio = base64.b64encode(wav(pcm)).decode()
        response = self.client.post(
            "/v1/chat/completions",
            json={
                "model": MODEL,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": SPEAKERS_PROMPT if diarize else SINGLE_PROMPT},
                            {"type": "audio_url", "audio_url": {"url": f"data:audio/wav;base64,{audio}"}},
                        ],
                    }
                ],
                "temperature": 0,
                "top_p": 1.0,
                "seed": 0,
                # A dense hour is about 20,000 tokens.
                "max_tokens": 32768,
                "chat_template_kwargs": {"enable_thinking": False},
                "skip_special_tokens": False,
                "spaces_between_special_tokens": False,
                "mm_processor_kwargs": {"capture_ctc_timestamps": True},
            },
        )
        response.raise_for_status()
        alignment = response.json().get("ctc_timestamps") or {}
        if alignment.get("error"):
            raise RuntimeError(f"timestamp alignment failed: {alignment['error']}")
        return [
            Word(w["word"], w["start"] + offset, w["end"] + offset, speaker_index(w.get("speaker")))
            for w in alignment.get("words", [])
            if w["word"].strip()
        ]
