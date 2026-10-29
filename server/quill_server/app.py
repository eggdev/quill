"""HTTP API. The Mac posts one track per request, its segment files in order,
and gets timed, speaker-tagged segments back for each file.

    POST /v1/transcribe?diarize=true   multipart: one or more `audio` parts
    GET  /health
"""

import logging
from dataclasses import asdict

from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool

from .engine import AudioError, Engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

app = FastAPI()
engine = Engine()


@app.get("/health")
def health():
    if not engine.health():
        raise HTTPException(503, "model server not ready")
    return {"ok": True, "model": engine.model}


@app.post("/v1/transcribe")
async def transcribe(request: Request, diarize: bool = True):
    form = await request.form(max_part_size=1 << 30)
    files = [await part.read() for part in form.getlist("audio")]
    if not files or not all(files):
        raise HTTPException(400, "expected one or more non-empty `audio` parts")
    try:
        results = await run_in_threadpool(engine.transcribe, files, diarize)
    except AudioError as e:
        raise HTTPException(422, f"unreadable audio: {e}") from e
    return {
        "engine": "nemotron",
        "model": engine.model,
        "files": [{"duration": r.duration, "segments": [asdict(s) for s in r.segments]} for r in results],
    }
