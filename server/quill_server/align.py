"""Join ASR word timings with diarizer speaker turns into transcript segments.

Pure functions over plain data, so the grouping rules are testable without a
GPU or a model.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Word:
    text: str
    start: float
    end: float


@dataclass(frozen=True)
class Turn:
    start: float
    end: float
    speaker: int


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    text: str
    speaker: int | None


# Same break rules as the Mac's local engine (ParakeetEngine.segments), so a
# transcript reads the same whichever engine made it.
MAX_GAP_SECONDS = 1.0
MAX_WORDS = 60
MIN_RUN_WORDS = 3


def parse_turns(lines: list[str]) -> list[Turn]:
    """Sortformer output lines, "<start> <end> speaker_<n>"."""
    turns = []
    for line in lines:
        start, end, label = line.split()
        turns.append(Turn(float(start), float(end), int(label.removeprefix("speaker_"))))
    return sorted(turns, key=lambda t: t.start)


def speaker_for(word: Word, turns: list[Turn]) -> int | None:
    """The speaker whose turns overlap the word most. A word in no turn (the
    diarizer trims edges tighter than the ASR) takes the nearest turn."""
    if not turns:
        return None
    overlap: dict[int, float] = {}
    for t in turns:
        o = min(word.end, t.end) - max(word.start, t.start)
        if o > 0:
            overlap[t.speaker] = overlap.get(t.speaker, 0.0) + o
    if overlap:
        return max(overlap, key=lambda s: overlap[s])
    mid = (word.start + word.end) / 2
    nearest = min(turns, key=lambda t: min(abs(mid - t.start), abs(mid - t.end)))
    return nearest.speaker


def smooth(words: list[Word], speakers: list[int | None]) -> list[int | None]:
    """The diarizer's turn edges jitter by a word or two, which would cut
    "I | don't know that." across two speakers. Within one sentence, a run of
    fewer than MIN_RUN_WORDS words takes the sentence's majority speaker."""
    out = list(speakers)
    start = 0
    for i, word in enumerate(words):
        if i == len(words) - 1 or word.text.endswith((".", "?", "!")):
            sentence = range(start, i + 1)
            counts: dict[int | None, int] = {}
            for j in sentence:
                counts[speakers[j]] = counts.get(speakers[j], 0) + 1
            majority = max(counts, key=lambda s: counts[s])
            run_start = start
            for j in sentence:
                if j == i or speakers[j + 1] != speakers[j]:
                    if j + 1 - run_start < MIN_RUN_WORDS:
                        for k in range(run_start, j + 1):
                            out[k] = majority
                    run_start = j + 1
            start = i + 1
    return out


def segments(words: list[Word], turns: list[Turn]) -> list[Segment]:
    """Group words into segments, breaking on a speaker change, sentence-ending
    punctuation, a silence gap, or a length cap. With fewer than two speakers
    found, segments carry no speaker: the track's own label is the whole truth.
    """
    speakers = smooth(words, [speaker_for(w, turns) for w in words])
    if len({s for s in speakers if s is not None}) < 2:
        speakers = [None] * len(words)
    # Number speakers 0, 1, ... in order of first appearance.
    order: dict[int, int] = {}
    for s in speakers:
        if s is not None and s not in order:
            order[s] = len(order)

    out: list[Segment] = []
    current: list[Word] = []
    current_speaker: int | None = None

    def flush():
        nonlocal current
        if current:
            out.append(
                Segment(
                    current[0].start,
                    current[-1].end,
                    " ".join(w.text for w in current),
                    None if current_speaker is None else order[current_speaker],
                )
            )
        current = []

    for word, speaker in zip(words, speakers):
        if current and (speaker != current_speaker or word.start - current[-1].end > MAX_GAP_SECONDS):
            flush()
        current_speaker = speaker
        current.append(word)
        if word.text.endswith((".", "?", "!")) or len(current) >= MAX_WORDS:
            flush()
    flush()
    return out
