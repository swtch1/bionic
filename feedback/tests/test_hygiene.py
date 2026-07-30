"""Hygiene: short-me flag, speaker-bleed detection, stream-health warning, no-drop default."""

from conftest import make_turn as _turn

from feedbackapp.hygiene import Hygiene, HygieneConfig
from feedbackapp.models import HygieneFlag


def test_short_me_turn_flagged_not_dropped():
    h = Hygiene()
    at = h.annotate(_turn(1, "me", "Hmm.", start=100.0, dur=0.3))
    assert HygieneFlag.SHORT_ME in at.flags
    assert at.attribution_suspect  # flagged, never dropped (Decision 3)


def test_normal_me_turn_clean():
    h = Hygiene()
    at = h.annotate(_turn(1, "me", "so the auth service owns refresh", start=100.0, dur=3.0))
    assert at.flags == []


def test_speaker_bleed_detected():
    h = Hygiene()
    h.annotate(_turn(1, "other", "ship the migration on Thursday", start=400.0, dur=3.5))
    at = h.annotate(_turn(2, "me", "ship the migration on Thursday", start=400.05, dur=3.5))
    assert HygieneFlag.BLEED_DUPLICATE in at.flags
    assert at.attribution_suspect


def test_no_bleed_when_text_differs():
    h = Hygiene()
    h.annotate(_turn(1, "other", "ship the migration Thursday", start=400.0, dur=3.0))
    at = h.annotate(_turn(2, "me", "actually let's wait a week", start=400.1, dur=3.0))
    assert HygieneFlag.BLEED_DUPLICATE not in at.flags


def test_stream_health_warns_after_silence():
    # Reference clock is the latest turn's own timestamp (no wall-time override),
    # so silence is driven by a later "me" turn advancing the clock while no
    # "other" turn arrives.
    h = Hygiene(HygieneConfig(no_other_warn_seconds=120.0))
    h.annotate(_turn(1, "other", "hello", start=100.0, dur=2.0))   # last other ends at 102
    h.annotate(_turn(2, "me", "still talking", start=148.0, dur=2.0))  # latest_end 150; gap 48 < 120
    assert h.stream_health() is None
    h.annotate(_turn(3, "me", "still going", start=298.0, dur=2.0))    # latest_end 300; gap 198 >= 120
    w = h.stream_health()
    assert w is not None and "System-audio" in w.message
