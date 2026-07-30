"""Glanceability guard - Decision 18. "Every single word needs to be earned."

Per-type word/line CEILINGS enforced as a CODE-LEVEL post-check on responder
output, not merely requested in the prompt. This is the deterministic guard the
eval suite pins - asserting ceilings on a stubbed responder's canned text would
test the fixture, not the system, so the enforcement lives here where a real or
stubbed responder both pass through it.

A message over ceiling is a hard failure of the glanceability constraint. The
caller decides what to do (suppress, truncate, or flag); this module only
measures and reports.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Ceiling:
    max_words: int
    max_lines: int


def over_ceiling(text: str, ceiling: Ceiling) -> str | None:
    """Return why `text` breaches `ceiling`, or None if it fits.

    The reason string is diagnostic only: Responder.respond uses the return
    value as a boolean, and the renderer never sees it. It is kept because it is
    what makes a ceiling failure debuggable in a test or a log line, and it costs
    nothing on the common (fits) path. (This used to return a five-field
    GlanceResult carrying words/lines/ceiling that no caller ever read.)
    """
    lines = [ln for ln in text.splitlines() if ln.strip()]
    words = sum(len(ln.split()) for ln in lines)
    reasons = []
    if words > ceiling.max_words:
        reasons.append(f"{words} words > {ceiling.max_words}")
    if len(lines) > ceiling.max_lines:
        reasons.append(f"{len(lines)} lines > {ceiling.max_lines}")
    return ", ".join(reasons) or None
