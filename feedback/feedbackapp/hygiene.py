"""Hygiene layer - the biggest gap in architecture-v0, added here.

Structural attribution (mic=me, system-audio=other) moved uncertainty OUT of
`conf` (now a useless hardcoded 1.0) and INTO observable artifacts the consumer
must filter. This layer turns those artifacts into a SYNTHETIC
`attribution_suspect` flag that DOES carry information, and passes that to the
gate in place of `conf`.

Three jobs:
1. Sub-threshold "me" turns: VAD fires on keyboard clatter and ASR hallucinates
   "Hmm."/"Oops." -> flag very short "me" turns.
2. Speaker bleed: near-identical me/other text within a small delta-t = the same
   speech captured on both channels -> flag the later one as a duplicate.
3. Stream health: no "other" turn in N minutes MAY mean system-audio capture
   died silently - but from the JSONL alone that is indistinguishable from the
   far side simply being quiet. So we SURFACE A WARNING, never guess it into the
   stream.

Policy: FLAG, never drop (Decision 3 - the LLM wants `me` turns to catch the
user's own errors, and the offline stream must stay fully inspectable). Flagged
turns still flow to the window and the gate; the flag is the whole mechanism.
"""

from __future__ import annotations

from dataclasses import dataclass

from .models import AnnotatedTurn, HygieneFlag, StreamHealthWarning, Turn


@dataclass
class HygieneConfig:
    short_me_max_seconds: float = 0.5      # sub-0.5s "me" turns are suspect
    bleed_delta_t_seconds: float = 0.75    # me/other within this window = candidate bleed
    bleed_similarity: float = 0.9          # normalized-text similarity threshold
    no_other_warn_seconds: float = 120.0   # warn if no "other" turn in this long


def _normalize(text: str) -> str:
    """Lowercase, strip trailing punctuation/space for bleed comparison.

    We do NOT use punctuation for meaning (terminal punctuation is unreliable);
    this only normalizes so an added/missing period doesn't defeat the match.
    """
    return "".join(c for c in text.lower() if c.isalnum() or c.isspace()).strip()


def _similarity(a: str, b: str) -> float:
    """Cheap token-Jaccard similarity. Good enough to catch near-identical bleed."""
    ta, tb = set(_normalize(a).split()), set(_normalize(b).split())
    if not ta or not tb:
        # Two EMPTY turns used to score 1.0 and get flagged as bleed - which is
        # plausible in practice (VAD fires on noise on both channels within
        # 0.75s), and the resulting attribution_suspect flag then tells the gate
        # to discount corrections. No text is no evidence of duplication.
        return 0.0
    return len(ta & tb) / len(ta | tb)


class Hygiene:
    """Stateful across a stream: remembers the last turn (for bleed) and the last
    time an "other" turn was seen (for stream health)."""

    def __init__(self, config: HygieneConfig | None = None):
        self.config = config or HygieneConfig()
        self._last_turn: Turn | None = None
        self._last_other_end: float | None = None
        self._latest_end: float | None = None  # max end seen, ANY speaker = stream clock
        self._warned = False                    # emit the health warning once per crossing

    def annotate(self, turn: Turn) -> AnnotatedTurn:
        flags: list[HygieneFlag] = []

        # 1. Short "me" turn (clatter / ASR hallucination).
        if turn.speaker == "me" and turn.duration < self.config.short_me_max_seconds:
            flags.append(HygieneFlag.SHORT_ME)

        # 2. Speaker bleed: near-identical text on the OTHER channel within delta-t.
        if self._last_turn is not None and self._last_turn.speaker != turn.speaker:
            dt = abs(turn.start - self._last_turn.start)
            if dt <= self.config.bleed_delta_t_seconds:
                if _similarity(turn.text, self._last_turn.text) >= self.config.bleed_similarity:
                    flags.append(HygieneFlag.BLEED_DUPLICATE)

        if turn.speaker == "other":
            self._last_other_end = turn.end
            self._warned = False  # a fresh "other" turn clears the warning latch
        self._latest_end = turn.end if self._latest_end is None else max(self._latest_end, turn.end)
        self._last_turn = turn

        # ATTRIBUTION_SUSPECT is DERIVED: both artifacts above imply it, and it is
        # the only one the gate acts on. Deriving it once here replaces appending
        # it in each branch and then de-duplicating the result.
        if flags:
            flags.append(HygieneFlag.ATTRIBUTION_SUSPECT)
        return AnnotatedTurn(turn=turn, flags=flags)

    def stream_health(self) -> StreamHealthWarning | None:
        """Return a warning (at most once per crossing) if no "other" turn has
        been seen recently. Never a hard claim - indistinguishable from the far
        side being quiet, so it's a warning only.

        The reference clock is the LATEST turn timestamp seen in the stream, not
        wall-clock `time.time()`: the transcript carries its own epoch, and for
        replayed historical fixtures wall-clock would diverge by years. In live
        mode the newest turn's time is ~now, so this matches intent there too.
        Consequence: this fires when the far side dies while the user keeps
        talking (me turns advance the clock), but never on a fully-silent stream
        - that would need wall-time and is a separate, unbuilt feature."""
        if self._last_other_end is None or self._latest_end is None:
            return None  # nothing to compare yet; don't warn on an empty stream
        gap = self._latest_end - self._last_other_end
        if gap >= self.config.no_other_warn_seconds and not self._warned:
            self._warned = True
            return StreamHealthWarning(
                message=(
                    f"No 'other' turn in {gap:.0f}s. System-audio capture may have "
                    "died - or the far side is just quiet. Cannot tell from the "
                    "transcript alone."
                ),
                since_seconds=gap,
            )
        return None
