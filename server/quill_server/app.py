"""HTTP API. The Mac posts one audio file per request and gets timed,
speaker-tagged segments back.

    POST /v1/transcribe?diarize=true   body: raw audio bytes
    GET  /health
"""

import logging
from contextlib import asynccontextmanager
from dataclasses import asdict

from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool

from .engine import Engine, decode

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("quill_server")

engine: Engine | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global engine
    engine = await run_in_threadpool(Engine)
    log.info("models loaded: %s", engine.model)
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True, "model": engine.model}


@app.post("/v1/transcribe")
async def transcribe(request: Request, diarize: bool = True):
    data = await request.body()
    if not data:
        raise HTTPException(400, "empty body")
    try:
        pcm = await run_in_threadpool(decode, data)
    except Exception as e:
        raise HTTPException(422, f"unreadable audio: {e}") from e
    duration, segments = await run_in_threadpool(engine.transcribe, pcm, diarize)
    return {
        "engine": "nemo",
        "model": engine.model,
        "duration": duration,
        "segments": [asdict(s) for s in segments],
    }
