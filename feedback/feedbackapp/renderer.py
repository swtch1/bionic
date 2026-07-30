"""Renderer - v0 is a read-only live stream (Decision 7).

Built EARLY, before the gate: the cheapest possible test of whether mid-call
feedback is tolerable, at zero API cost. It prints:
- each turn as it lands (left/right framing mimics the eventual bubble chat:
  "other" on the left, "me" on the right), with hygiene flags shown inline so
  the attribution-suspect signal is visible while inspecting the stream;
- stream-health warnings;
- responder messages (when the LLM path is wired), with the "what I'm
  answering" description.

Deliberately plain text - no TUI dependency in v0.
"""

from __future__ import annotations

import sys
from datetime import datetime

from .models import AnnotatedTurn, ResponderOutput, StreamHealthWarning


def _clock(start: float) -> str:
    """Format an epoch-seconds timestamp, never raising.

    `Turn.start` is an unvalidated float from a third-party producer. A
    milliseconds-epoch value (1.7e12) raises ValueError here and 1e20 raises
    OverflowError - and an exception out of the renderer killed the ENTIRE tick's
    batch, including the valid turns around the bad one, unrecoverably (the
    tailer had already advanced its offset). Degrade to "--:--:--" instead.
    """
    try:
        return datetime.fromtimestamp(start).strftime("%H:%M:%S")
    except (ValueError, OverflowError, OSError):
        return "--:--:--"


class Renderer:
    """verbose=False is the LIVE default (Decision 7 addendum, 2026-07-28).

    Mid-call, the user already knows what was said - echoing every turn back at
    them is a wall of text they have to sift through to find the one line that
    matters. Quiet mode prints ONLY what they could not have known: responder
    messages, stream-health warnings, and errors. The per-turn stream and the
    considered-and-stayed-silent trace are diagnostics; they belong behind
    --verbose. Default stays True so the offline replay demo - whose entire
    point is watching the stream - is unchanged.
    """

    def __init__(self, stream=None, show_flags: bool = True, verbose: bool = True):
        self._out = stream if stream is not None else sys.stdout
        self.show_flags = show_flags
        self.verbose = verbose

    def _w(self, line: str) -> None:
        self._out.write(line + "\n")
        self._out.flush()

    def turn(self, at: AnnotatedTurn) -> None:
        if not self.verbose:
            return
        t = at.turn
        clock = _clock(t.start)
        flag_str = ""
        if self.show_flags and at.flags:
            flag_str = "  [" + ", ".join(f.value for f in at.flags) + "]"
        # Right-align "me" turns to echo the chat layout without needing a TUI.
        indent = " " * 40 if t.speaker == "me" else ""
        self._w(f"{indent}{clock} #{t.seq} {t.speaker}: {t.text}{flag_str}")

    def stream_health(self, w: StreamHealthWarning) -> None:
        self._w(f"  !! stream-health: {w.message}")

    def response(self, out: ResponderOutput) -> None:
        if not out.message:
            # Responder verified the candidate and chose NOT to speak (precision).
            # Diagnostic, not news: at --verbose only. Shown at all (rather than
            # a bare return) because silence and a BROKEN responder used to
            # render identically - a blank screen - which hid a responder that
            # could never speak at all.
            claim = out.addressed_claim or "candidate"
            self.debug(f"responder considered and stayed silent: {claim}")
            return
        desc = f" ({out.description})" if out.description else ""
        typ = f"[{out.type}] " if out.type else ""
        # In quiet mode there is no transcript on screen, so anchor the message
        # to what it is about - otherwise a line arrives with no referent.
        if not self.verbose and out.addressed_claim:
            self._w(f"  re: {out.addressed_claim}")
        # LLM messages render as left-side bubbles in the eventual UI.
        self._w(f">> {typ}assistant{desc}: {out.message}")

    def notice(self, text: str) -> None:
        """Always shown: mode banners, errors, suppressed-for-a-reason events."""
        self._w(f"  .. {text}")

    def debug(self, text: str) -> None:
        """--verbose only: per-tick trace that is noise during a real call."""
        if self.verbose:
            self.notice(text)
