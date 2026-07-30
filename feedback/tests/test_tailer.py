"""Tailer: torn-line, burst-as-one-batch, seq-gap, rotation/dedupe, resume."""

from functools import partial

from conftest import jsonl_line

from feedbackapp.tailer import Tailer, TailEvent

_line = partial(jsonl_line, text="hi")


def test_torn_line_held_until_newline(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_bytes(b"")
    tailer = Tailer(p)

    # Write a partial line (no newline) - must emit nothing.
    partial = _line(1).encode()[:20]
    with open(p, "ab") as fh:
        fh.write(partial)
    assert tailer.poll().turns == []

    # Complete the SAME line + newline - now it emits intact.
    with open(p, "ab") as fh:
        fh.write(_line(1).encode()[20:] + b"\n")
    turns = tailer.poll().turns
    assert len(turns) == 1 and turns[0].seq == 1 and turns[0].text == "hi"


def test_burst_arrives_as_one_ordered_batch(tmp_path):
    p = tmp_path / "t.jsonl"
    # All four lines land before a single poll -> one batch, in order.
    p.write_text("\n".join(_line(i) for i in range(1, 5)) + "\n")
    tailer = Tailer(p)
    turns = tailer.poll().turns
    assert [t.seq for t in turns] == [1, 2, 3, 4]


def test_seq_gap_detected(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(_line(1) + "\n" + _line(3) + "\n")
    tailer = Tailer(p)
    result = tailer.poll()
    assert [t.seq for t in result.turns] == [1, 3]
    assert any(e[0] == TailEvent.SEQ_GAP for e in result.events)


def test_bad_line_skipped_not_crash(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(_line(1) + "\n" + "{not json\n" + _line(2) + "\n")
    tailer = Tailer(p)
    result = tailer.poll()
    assert [t.seq for t in result.turns] == [1, 2]
    assert any(e[0] == TailEvent.BAD_LINE for e in result.events)


def test_rotation_dedupes_on_seq(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(_line(1) + "\n" + _line(2) + "\n")
    tailer = Tailer(p)
    assert [t.seq for t in tailer.poll().turns] == [1, 2]

    # Truncate + rewrite from scratch (rotation) with an overlapping seq.
    p.write_text(_line(1) + "\n" + _line(2) + "\n" + _line(3) + "\n")
    result = tailer.poll()
    # Already-seen 1,2 deduped; only 3 emerges.
    assert [t.seq for t in result.turns] == [3]


def test_sidecar_resume(tmp_path):
    p = tmp_path / "t.jsonl"
    side = tmp_path / "t.sidecar"
    p.write_text(_line(1) + "\n" + _line(2) + "\n")
    t1 = Tailer(p, sidecar=side)
    assert [t.seq for t in t1.poll().turns] == [1, 2]
    t1.close()

    # Append, then a fresh tailer resumes from the sidecar (no re-emit of 1,2).
    with open(p, "a") as fh:
        fh.write(_line(3) + "\n")
    t2 = Tailer(p, sidecar=side)
    assert [t.seq for t in t2.poll().turns] == [3]
