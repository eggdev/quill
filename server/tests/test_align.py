from quill_server.align import Segment, Word, collapse_loops, number_speakers, segments


def words(*spec):
    return [Word(*w) for w in spec]


def test_speakers_renumber_by_first_appearance():
    w = number_speakers(words(("a", 0, 1, 3), ("b", 1, 2, 1), ("c", 2, 3, 3)))
    assert [x.speaker for x in w] == [0, 1, 0]


def test_one_speaker_means_no_labels():
    w = number_speakers(words(("a", 0, 1, 2), ("b", 1, 2, 2)))
    assert [x.speaker for x in w] == [None, None]


def test_breaks_on_speaker_change():
    w = words(("Hi", 0.0, 0.3, 0), ("there", 0.3, 0.6, 0), ("Hello", 0.7, 1.0, 1))
    assert segments(w) == [
        Segment(0.0, 0.6, "Hi there", 0),
        Segment(0.7, 1.0, "Hello", 1),
    ]


def test_breaks_on_sentence_and_long_gap():
    w = words(("One.", 0.0, 0.3), ("two", 0.4, 0.6), ("three", 3.0, 3.2))
    assert [s.text for s in segments(w)] == ["One.", "two", "three"]


def test_short_pause_inside_a_turn_does_not_split_it():
    w = words(("Like,", 9.1, 9.4, 1), ("you", 9.4, 9.9, 1), ("are", 11.0, 11.9, 1), ("you", 12.9, 13.4, 1))
    assert [s.text for s in segments(w)] == ["Like, you are you"]


def test_long_run_wraps():
    w = [Word("w", i * 0.1, i * 0.1 + 0.05) for i in range(130)]
    assert [len(s.text.split()) for s in segments(w)] == [60, 60, 10]


def test_generation_loop_collapses_to_one_copy():
    loop = [Word(t, 0, 0) for t in ["I", "mean,"] * 25]
    w = [Word("So", 0, 0)] + loop + [Word("yes.", 0, 0)]
    assert [x.text for x in collapse_loops(w)] == ["So", "I", "mean,", "yes."]


def test_ordinary_repetition_survives():
    w = [Word(t, 0, 0) for t in ["no", "no", "no", "okay."]]
    assert collapse_loops(w) == w
