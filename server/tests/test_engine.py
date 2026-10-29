import json

import httpx
import numpy as np

from quill_server.engine import SAMPLE_RATE, Engine, speaker_index, wav


def silence(seconds):
    return wav(np.zeros(int(seconds * SAMPLE_RATE), dtype=np.float32))


def fake_vllm(words, requests):
    def handle(request):
        requests.append(json.loads(request.content))
        return httpx.Response(200, json={"choices": [], "ctc_timestamps": {"error": None, "words": words}})

    return httpx.Client(base_url="http://vllm", transport=httpx.MockTransport(handle))


def test_one_request_per_track_and_words_split_back_per_file():
    requests = []
    words = [
        {"word": "Hi.", "start": 0.5, "end": 0.9, "speaker": "<spk:1>"},
        {"word": "Hello.", "start": 1.2, "end": 1.6, "speaker": "<spk:0>"},
        {"word": "Back.", "start": 2.5, "end": 2.9, "speaker": "<spk:1>"},
    ]
    engine = Engine(fake_vllm(words, requests))

    first, second = engine.transcribe([silence(2), silence(1)], diarize=True)

    assert len(requests) == 1
    assert "speaker tags" in requests[0]["messages"][0]["content"][0]["text"]
    assert round(first.duration, 3) == 2 and round(second.duration, 3) == 1
    assert [(s.text, s.speaker) for s in first.segments] == [("Hi.", 0), ("Hello.", 1)]
    # The same voice keeps its number after the interruption, and its time
    # is relative to the second file.
    assert [(s.text, s.speaker, round(s.start, 3)) for s in second.segments] == [("Back.", 0, 0.5)]


def test_mic_track_asks_for_no_speakers():
    requests = []
    engine = Engine(fake_vllm([{"word": "Hi.", "start": 0.1, "end": 0.3}], requests))
    (result,) = engine.transcribe([silence(1)], diarize=False)
    assert "speaker tags" not in requests[0]["messages"][0]["content"][0]["text"]
    assert [s.speaker for s in result.segments] == [None]


def test_speaker_tag_forms():
    assert [speaker_index(t) for t in [None, 2, "<spk:3>", "spk:1", "speaker_0"]] == [None, 2, 3, 1, 0]
