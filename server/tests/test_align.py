from quill_server.align import Segment, Turn, Word, parse_turns, segments, speaker_for


def words(*spec):
    return [Word(text, start, end) for text, start, end in spec]


def test_parse_turns_sorts_by_start():
    assert parse_turns(["3.0 4.0 speaker_1", "0.0 2.5 speaker_0"]) == [
        Turn(0.0, 2.5, 0),
        Turn(3.0, 4.0, 1),
    ]


def test_speaker_takes_most_overlap():
    turns = [Turn(0.0, 1.1, 0), Turn(1.1, 3.0, 1)]
    assert speaker_for(Word("x", 1.0, 1.5), turns) == 1


def test_word_outside_turns_takes_nearest():
    turns = [Turn(0.0, 1.0, 0), Turn(5.0, 6.0, 1)]
    assert speaker_for(Word("x", 4.5, 4.8), turns) == 1


def test_breaks_on_speaker_change_and_renumbers_by_first_appearance():
    w = words(
        ("Hi", 0.0, 0.2), ("there", 0.2, 0.4), ("you", 0.4, 0.6),
        ("hello", 0.7, 0.8), ("to", 0.8, 0.9), ("you", 0.9, 1.0),
    )
    turns = [Turn(0.0, 0.65, 3), Turn(0.65, 1.0, 1)]
    assert segments(w, turns) == [
        Segment(0.0, 0.6, "Hi there you", 0),
        Segment(0.7, 1.0, "hello to you", 1),
    ]


def test_short_run_inside_sentence_takes_majority():
    w = words(("mad.", 0.0, 0.3), ("I", 0.4, 0.5), ("don't", 0.5, 0.7), ("know", 0.7, 0.9), ("that.", 0.9, 1.1))
    turns = [Turn(0.0, 0.55, 1), Turn(0.55, 1.2, 0)]
    assert [(s.text, s.speaker) for s in segments(w, turns)] == [
        ("mad.", 0),
        ("I don't know that.", 1),
    ]


def test_long_run_inside_sentence_keeps_its_speaker():
    w = words(("so", 0.0, 0.1), ("we", 0.1, 0.2), ("go", 0.2, 0.3), ("yes", 0.4, 0.5), ("we", 0.5, 0.6), ("do.", 0.6, 0.7))
    turns = [Turn(0.0, 0.35, 0), Turn(0.35, 0.8, 1)]
    assert [(s.text, s.speaker) for s in segments(w, turns)] == [("so we go", 0), ("yes we do.", 1)]


def test_one_speaker_found_means_no_labels():
    w = words(("Hi.", 0.0, 0.3), ("Bye.", 0.4, 0.6))
    assert [s.speaker for s in segments(w, [Turn(0.0, 1.0, 0)])] == [None, None]


def test_no_diarization_breaks_on_sentence_and_gap():
    w = words(("One.", 0.0, 0.3), ("two", 0.4, 0.6), ("three", 2.0, 2.2))
    assert [s.text for s in segments(w, [])] == ["One.", "two", "three"]


def test_long_run_wraps():
    w = [Word("w", i * 0.1, i * 0.1 + 0.05) for i in range(130)]
    assert [len(s.text.split()) for s in segments(w, [])] == [60, 60, 10]
