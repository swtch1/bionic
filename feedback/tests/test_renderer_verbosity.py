"""Quiet-by-default live rendering (2026-07-28).

During a real call the user knows what they just said; echoing the transcript
back buries the one line that matters. These tests pin the split: quiet mode
prints feedback, health warnings and errors - and NOTHING else.
"""

from __future__ import annotations

import io
from functools import partial

from conftest import make_annotated

from feedbackapp.models import ResponderOutput, StreamHealthWarning
from feedbackapp.renderer import Renderer

# Renderer tests speak as "me" and pin start=0.0 (the rendered clock).
_turn = partial(make_annotated, speaker="me", start=0.0, dur=1.0)


def test_quiet_mode_hides_transcript_and_trace():
    out = io.StringIO()
    r = Renderer(stream=out, verbose=False)
    r.turn(_turn())
    r.debug("tail:rotated: something")
    r.response(ResponderOutput(message=None, addressed_claim="billing is Go"))
    assert out.getvalue() == ""


def test_quiet_mode_still_shows_feedback_health_and_errors():
    out = io.StringIO()
    r = Renderer(stream=out, verbose=False)
    r.response(
        ResponderOutput(
            message="Billing is Python, not Go.",
            description="checked repo",
            addressed_claim="billing is Go",
            type="correction",
        )
    )
    r.stream_health(
        StreamHealthWarning(kind="no_other_audio", message="no other turns", since_seconds=90.0)
    )
    r.notice("error: responder failed: X")
    text = out.getvalue()
    # The message, anchored to what it is about (no transcript on screen).
    assert '> "billing is Go"' in text
    assert ">> [correction] Billing is Python," in text
    assert "not Go. (checked repo)" in text
    assert "stream-health" in text
    assert "error: responder failed" in text


def test_verbose_mode_restores_the_full_stream():
    out = io.StringIO()
    r = Renderer(stream=out, verbose=True)
    r.turn(_turn(seq=7, text="hello there"))
    r.debug("tail:rotated: something")
    r.response(ResponderOutput(message=None, addressed_claim="billing is Go"))
    text = out.getvalue()
    assert "#7 me: hello there" in text
    assert "tail:rotated" in text
    assert "stayed silent: billing is Go" in text


def test_default_is_verbose_so_offline_replay_is_unchanged():
    out = io.StringIO()
    Renderer(stream=out).turn(_turn(seq=3))
    assert "#3 me:" in out.getvalue()


def test_bubbles_wrap_long_text_without_truncating():
    out = io.StringIO()
    r = Renderer(stream=out, verbose=False)
    long_message = " ".join(f"word{i}" for i in range(30))
    long_claim = " ".join(f"claim{i}" for i in range(20))
    r.response(ResponderOutput(message=long_message, addressed_claim=long_claim))
    text = out.getvalue().replace("\n", " ")
    for i in range(30):
        assert f"word{i}" in text
    for i in range(20):
        assert f"claim{i}" in text
    # continuation lines of the right bubble stay right-indented, not flush left.
    lines = [ln for ln in out.getvalue().splitlines() if ln.strip()]
    assert any(ln.startswith(" " * 28) and ">>" not in ln for ln in lines)
