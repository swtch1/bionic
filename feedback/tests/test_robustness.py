"""Failure modes a real user hits that used to be silent, fatal, or misleading.

Each test here corresponds to a verified defect, named in its docstring.
"""

from __future__ import annotations

import json
from functools import partial

import pytest
from conftest import build_orchestrator, jsonl_line, make_turn

from feedbackapp.config import DEFAULTS_DIR, ConfigError, load_config
from feedbackapp.hygiene import Hygiene, HygieneConfig, _similarity
from feedbackapp.renderer import _clock
from feedbackapp.tailer import Tailer

# This file's turns all share one start timestamp unless overridden.
_line = partial(jsonl_line, start=1000.0)


# --- a poisonous turn must not take the whole batch down with it -------------
# `Turn.start` is an unvalidated float from a third-party producer. A
# milliseconds-epoch value raised ValueError inside the renderer, which escaped
# to run()'s per-TICK guard - and by then the tailer had already advanced its
# offset, so every valid turn in the same batch was lost unrecoverably.

@pytest.mark.parametrize("bad", [1.7e12, 1e20, -1e20, float("nan")])
def test_clock_never_raises(bad):
    assert isinstance(_clock(bad), str)


def test_one_bad_timestamp_does_not_lose_the_rest_of_the_batch(tmp_path):
    target = tmp_path / "live.jsonl"
    target.write_text(
        _line(1) + "\n" + _line(2, start=1.7e12) + "\n" + _line(3) + "\n"
    )
    h = build_orchestrator(target=target)
    orch = h.orch
    orch.tick()
    text = h.stream.getvalue()
    assert "#1 other" in text and "#3 other" in text, "valid turns were lost with the bad one"
    assert len(orch.window.turns) == 3


# --- empty turns are not "identical" ----------------------------------------
# VAD firing on noise on both channels within delta-t produced two empty-text
# turns; token-Jaccard scored them 1.0, flagged bleed, and the resulting
# attribution_suspect flag tells the gate to discount corrections.

def test_two_empty_turns_are_not_bleed_duplicates():
    assert _similarity("", "") == 0.0
    h = Hygiene(HygieneConfig())
    h.annotate(make_turn(1, "me", "", start=10.0, dur=0.2))
    at = h.annotate(make_turn(2, "other", "", start=10.3, dur=0.2))
    assert at.flags == [], f"empty turns flagged as bleed: {at.flags}"


# --- config errors name the file ---------------------------------------------

def test_missing_config_dir_raises_a_named_error(tmp_path):
    with pytest.raises(ConfigError) as e:
        load_config(tmp_path / "nope")
    assert "not found" in str(e.value)


def test_malformed_resource_entry_names_the_file(tmp_path):
    src = DEFAULTS_DIR
    for f in ("config.yaml", "instructions.md"):
        (tmp_path / f).write_text((src / f).read_text())
    (tmp_path / "resources.yaml").write_text("resources:\n  - name: r\n    kind: repo\n")
    with pytest.raises(ConfigError) as e:
        load_config(tmp_path)
    assert "resources.yaml" in str(e.value)


# --- the sidecar is not rewritten 10x/second on an idle stream ---------------

def test_idle_polls_do_not_rewrite_the_sidecar(tmp_path):
    target = tmp_path / "live.jsonl"
    target.write_text(_line(1) + "\n")
    sidecar = tmp_path / "state.json"
    t = Tailer(target, sidecar=sidecar)
    t.poll()
    assert sidecar.exists()
    stamp = sidecar.stat().st_mtime_ns
    for _ in range(5):
        t.poll()  # nothing new on disk
    assert sidecar.stat().st_mtime_ns == stamp, "sidecar rewritten on an idle poll"


def test_sidecar_still_tracks_new_turns(tmp_path):
    target = tmp_path / "live.jsonl"
    target.write_text(_line(1) + "\n")
    sidecar = tmp_path / "state.json"
    t = Tailer(target, sidecar=sidecar)
    t.poll()
    with open(target, "a") as fh:
        fh.write(_line(2) + "\n")
    t.poll()
    assert json.loads(sidecar.read_text())["last_seq"] == 2
