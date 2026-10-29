"""Turn the model's speaker-tagged, timed words into transcript segments.

Pure functions over plain data, so the grouping rules are testable without a
GPU or a model.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Word:
    text: str
    start: float
    end: float
    speaker: int | None = None


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    text: str
    speaker: int | None


# The model marks speaker turns itself, so a segment follows a turn and only
# a long pause splits it. Conversational pauses mid-turn often pass 1 s.
MAX_GAP_SECONDS = 2.0
MAX_WORDS = 60

# The model can, rarely, fail to stop and repeat itself. Same thresholds as
# the guardrail on its model card, counted in words: a block of up to
# LOOP_MAX_BLOCK words repeated LOOP_MIN_REPEATS or more times collapses to one.
LOOP_MIN_REPEATS = 20
LOOP_MAX_BLOCK = 64


def collapse_loops(words: list[Word]) -> list[Word]:
    texts = [w.text for w in words]
    out: list[Word] = []
    i = 0
    while i < len(words):
        loop = None
        for size in range(1, LOOP_MAX_BLOCK + 1):
            if i + size * LOOP_MIN_REPEATS > len(words):
                break
            block = texts[i : i + size]
            repeats = 1
            while texts[i + repeats * size : i + (repeats + 1) * size] == block:
                repeats += 1
            if repeats >= LOOP_MIN_REPEATS:
                loop = (size, repeats)
                break
        if loop:
            size, repeats = loop
            out += words[i : i + size]
            i += size * repeats
        else:
            out.append(words[i])
            i += 1
    return out


def number_speakers(words: list[Word]) -> list[Word]:
    """Renumber speakers 0, 1, ... in order of first appearance. With fewer
    than two speakers, drop them: the track's own label is the whole truth."""
    order: dict[int, int] = {}
    for w in words:
        if w.speaker is not None and w.speaker not in order:
            order[w.speaker] = len(order)
    if len(order) < 2:
        return [Word(w.text, w.start, w.end) for w in words]
    return [Word(w.text, w.start, w.end, None if w.speaker is None else order[w.speaker]) for w in words]


def segments(words: list[Word]) -> list[Segment]:
    """Group words into segments, breaking on a speaker change, sentence-ending
    punctuation, a silence gap, or a length cap."""
    out: list[Segment] = []
    current: list[Word] = []

    def flush():
        nonlocal current
        if current:
            text = " ".join(w.text for w in current)
            out.append(Segment(current[0].start, current[-1].end, text, current[0].speaker))
        current = []

    for word in words:
        if current and (word.speaker != current[-1].speaker or word.start - current[-1].end > MAX_GAP_SECONDS):
            flush()
        current.append(word)
        if word.text.endswith((".", "?", "!")) or len(current) >= MAX_WORDS:
            flush()
    flush()
    return out
