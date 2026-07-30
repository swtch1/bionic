"""Rolling window + orchestrator state (anti-spam bookkeeping).

The window is the last N annotated turns (default 10, Decision 4). It is the
gate's CONTEXT; the newest batch of turns is the FOCUS (Decision 12 - focus is
an instruction to the gate, NOT a reduction of the input to only the latest
line).

State also holds the anti-spam machinery (Decision 12):
- recently-addressed memory: claims the responder actually spoke on, so the gate
  skips them.
- global cooldown + in-flight guard + responses/min cap.
All of these are configurable.
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field

from .models import AnnotatedTurn


@dataclass
class AntiSpamConfig:
    window_size: int = 10
    cooldown_seconds: float = 25.0
    responses_per_min: int = 4
    recently_addressed_size: int = 8


class Window:
    """Rolling window of the last N annotated turns, plus the newest-batch focus."""

    def __init__(self, size: int = 10):
        # The bound lives in the deque's maxlen; a second copy on self could drift.
        self._turns: deque[AnnotatedTurn] = deque(maxlen=size)
        self._newest_batch: list[AnnotatedTurn] = []

    def extend(self, batch: list[AnnotatedTurn]) -> None:
        """Apply a whole tick's ordered batch at once. The batch becomes the focus."""
        self._newest_batch = list(batch)
        for t in batch:
            self._turns.append(t)

    @property
    def turns(self) -> list[AnnotatedTurn]:
        return list(self._turns)

    @property
    def newest_batch(self) -> list[AnnotatedTurn]:
        """The turns added on the most recent tick - the gate's explicit FOCUS.

        No copy here: extend() already stores a fresh list, so this is the one
        defensive copy rather than two (unlike `turns`, which genuinely has to
        materialize a deque).
        """
        return self._newest_batch

    def __len__(self) -> int:
        return len(self._turns)


@dataclass
class OrchestratorState:
    """Anti-spam + in-flight bookkeeping shared across the loop."""

    config: AntiSpamConfig = field(default_factory=AntiSpamConfig)
    # Bounded in __post_init__ from config.recently_addressed_size - the bound
    # depends on another field, so it cannot be expressed as a default here.
    recently_addressed: deque[str] = field(init=False)
    _last_response_at: float = 0.0
    _response_times: deque[float] = field(default_factory=deque)
    in_flight: bool = False

    def __post_init__(self):
        self.recently_addressed = deque(maxlen=self.config.recently_addressed_size)

    def can_fire(self, now: float | None = None) -> tuple[bool, str]:
        """Gate the RESPONDER launch (not the gate call). Returns (ok, reason)."""
        now = time.monotonic() if now is None else now
        if self.in_flight:
            return False, "responder in flight"
        if now - self._last_response_at < self.config.cooldown_seconds:
            return False, "within cooldown"
        # responses/min cap
        cutoff = now - 60.0
        while self._response_times and self._response_times[0] < cutoff:
            self._response_times.popleft()
        if len(self._response_times) >= self.config.responses_per_min:
            return False, "responses/min cap reached"
        return True, "ok"

    def record_response(self, addressed_claim: str | None, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        self._last_response_at = now
        self._response_times.append(now)
        if addressed_claim:
            self.recently_addressed.append(addressed_claim)

    def record_suppressed(self, claim: str | None) -> None:
        """A claim the responder verified and chose NOT to speak on. Enter it in
        recently-addressed so the gate stops re-escalating it (item 5), WITHOUT
        touching cooldown/cap - no user-visible response occurred."""
        if claim:
            self.recently_addressed.append(claim)
