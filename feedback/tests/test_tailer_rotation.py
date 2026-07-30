"""Rotation / resume correctness (review items 2 and 4).

Two verified data-loss bugs:
- Resume after the file was REPLACED during downtime: the stale sidecar offset
  was seek'd into the new file, skipping its leading turns (item 2).
- Live rotation to a NEW meeting whose seq counter restarts low: every turn was
  dropped by the seq-dedupe threshold because last_seq was never reset (item 4).

Design decision pinned here (items 2+4 merged - they conflict on last_seq, and an
inode-change reset satisfies BOTH verified failures): an INODE CHANGE means a new
stream -> reset offset, buffer, AND last_seq. Truncate-in-place (same inode) keeps
last_seq so an in-place rewrite of the same stream isn't re-emitted. Exactly one
ROTATED event per rotation, no spurious BAD_LINE / SEQ_GAP.
"""

from functools import partial

from conftest import jsonl_line

from feedbackapp.tailer import Tailer, TailEvent

# This file's turns are half-second long; the rest of the suite uses 1.0s.
_line = partial(jsonl_line, text="hi", dur=0.5)


def _write_fresh_inode(path, lines):
    """Write via a temp file + os.replace so the path gets a NEW inode, exactly
    as a producer that rotates the log would."""
    tmp = path.with_suffix(".incoming")
    tmp.write_text("\n".join(lines) + "\n")
    import os
    os.replace(tmp, path)


def _counts(events):
    c = {TailEvent.ROTATED: 0, TailEvent.BAD_LINE: 0, TailEvent.SEQ_GAP: 0}
    for kind, _ in events:
        c[kind] = c.get(kind, 0) + 1
    return c


def test_resume_after_file_replaced_during_downtime(tmp_path):
    """Item 2: sidecar has an offset into the OLD file; the file was replaced
    while we were down. Resume must re-read the NEW file from the top, losing
    nothing."""
    path = tmp_path / "live.jsonl"
    sidecar = tmp_path / "live.sidecar"

    # First run: several turns, persist the sidecar (offset well into the file).
    path.write_text("\n".join(_line(i, text=f"old turn {i}") for i in range(0, 6)) + "\n")
    t1 = Tailer(path, sidecar=sidecar)
    first = t1.poll()
    assert [x.seq for x in first.turns] == [0, 1, 2, 3, 4, 5]
    t1.close()

    # Downtime: file replaced (new inode) with a new set of turns 10..19.
    _write_fresh_inode(path, [_line(i, text=f"new turn {i}") for i in range(10, 20)])

    # Second run resumes from the sidecar.
    t2 = Tailer(path, sidecar=sidecar)
    r = t2.poll()
    seqs = [x.seq for x in r.turns]
    assert seqs == list(range(10, 20)), f"lost leading turns on resume: {seqs}"
    c = _counts(r.events)
    assert c[TailEvent.ROTATED] == 1, c
    assert c[TailEvent.BAD_LINE] == 0, c
    assert c[TailEvent.SEQ_GAP] == 0, c


def test_live_rotation_to_new_meeting_low_seq(tmp_path):
    """Item 4: a new meeting restarts seq low. Inode change = new stream, so
    those turns must NOT be dropped by dedupe."""
    path = tmp_path / "live.jsonl"
    path.write_text("\n".join(_line(i) for i in (40, 41)) + "\n")
    t = Tailer(path)
    assert [x.seq for x in t.poll().turns] == [40, 41]

    # New meeting, new file (new inode), seq restarts at 1.
    _write_fresh_inode(path, [_line(i, text="new meeting") for i in (1, 2)])
    r = t.poll()
    assert [x.seq for x in r.turns] == [1, 2], "new-meeting turns dropped by stale last_seq"
    c = _counts(r.events)
    assert c[TailEvent.ROTATED] == 1, f"expected exactly one ROTATED, got {c}"


def test_truncate_in_place_keeps_dedupe(tmp_path):
    """Same inode, file shrank below offset (in-place rewrite of the SAME
    stream): last_seq is kept, so already-seen seqs are not re-emitted."""
    path = tmp_path / "live.jsonl"
    path.write_text("\n".join(_line(i) for i in (0, 1, 2)) + "\n")
    t = Tailer(path)
    assert [x.seq for x in t.poll().turns] == [0, 1, 2]

    # Truncate in place (same inode) and rewrite the same seqs 0..2 plus a new 3.
    with open(path, "w") as fh:
        fh.write("\n".join(_line(i) for i in (0, 1, 2, 3)) + "\n")
    r = t.poll()
    # 0..2 already seen -> deduped; only 3 is new.
    assert [x.seq for x in r.turns] == [3], f"truncate-in-place re-emitted: {[x.seq for x in r.turns]}"
