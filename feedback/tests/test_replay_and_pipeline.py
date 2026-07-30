"""Replay fixtures validate as LIVE format, and the offline pipeline runs
end-to-end (replay -> tailer -> hygiene -> renderer) with no API key."""

import io
from pathlib import Path

import pytest

from conftest import build_orchestrator

from feedbackapp.replay import read_fixture, replay

FIXDIR = Path(__file__).resolve().parent.parent / "fixtures"
FIXTURES = sorted(FIXDIR.glob("*.jsonl"))


@pytest.mark.parametrize("fx", FIXTURES, ids=lambda p: p.name)
def test_fixtures_are_live_format(fx):
    # read_fixture raises on unknown/varied-conf (batch-mode artifacts).
    objs = read_fixture(fx)
    assert objs, f"{fx} empty"
    seqs = [o["seq"] for o in objs]
    assert seqs == list(range(seqs[0], seqs[0] + len(seqs))), "seq must be gapless"


def test_replay_output_matches_swift_shape(tmp_path):
    target = tmp_path / "live.jsonl"
    n = replay(FIXDIR / "boring_chatter.jsonl", target, mode="burst", sleep=lambda s: None)
    assert n == 3
    # Every appended line is one JSON object, newline-terminated.
    raw = target.read_bytes()
    assert raw.endswith(b"\n")
    assert len(raw.strip().split(b"\n")) == 3


def test_bleed_fixture_flags_duplicate(tmp_path):
    target = tmp_path / "live.jsonl"
    replay(FIXDIR / "bleed_duplicate.jsonl", target, mode="burst", sleep=lambda s: None)
    out = io.StringIO()
    build_orchestrator(target=target, stream=out).orch.tick()
    text = out.getvalue()
    assert "bleed_duplicate" in text  # the near-identical me/other pair is flagged
    assert "attribution_suspect" in text


def test_offline_pipeline_end_to_end(tmp_path):
    target = tmp_path / "live.jsonl"
    replay(FIXDIR / "in_scope_repo_question.jsonl", target, mode="burst", sleep=lambda s: None)
    out = io.StringIO()
    build_orchestrator(target=target, stream=out).orch.tick()  # one poll picks up the whole burst
    text = out.getvalue()
    # All three turns rendered, in order, with the me-turn on the right (indented).
    assert "#1 other:" in text and "#2 other:" in text and "#3 me:" in text
    assert text.index("#1") < text.index("#2") < text.index("#3")
