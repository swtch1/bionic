"""Pydantic models for the transcript contract and the LLM pipeline I/O.

The `Turn` model mirrors the JSONL contract from the transcriber handoff
(Decision 8). Field order in the file is irrelevant - the producer uses Swift's
JSONEncoder (unordered keys) and we parse, not positionally decode.

IMPORTANT invariants encoded here:
- `conf` exists in the contract but carries ZERO information in the LIVE path
  (hardcoded 1.0 in TurnWriter.swift - the live speaker label is structural,
  mic vs system-audio, not a voiceprint distance). The gate must never see it.
  We keep the field so batch-mode files still parse, but nothing downstream
  keys off it.
- `speaker` in live mode is only "me" | "other". "unknown" is reachable only in
  batch mode; fixtures must never use it.
"""

from __future__ import annotations

from enum import Enum
from typing import Literal, Optional, get_args

from pydantic import BaseModel, Field


# --- The transcript contract (Decision 8) ------------------------------------

class Turn(BaseModel):
    """One finalized turn = one line in the JSONL transcript = one trigger unit."""

    seq: int = Field(..., description="Monotonic, gapless, +1 per finalized turn.")
    start: float = Field(..., description="Epoch seconds, utterance start.")
    end: float = Field(..., description="Epoch seconds, utterance end.")
    speaker: str = Field(..., description='"me" | "other" | "unknown".')
    text: str
    final: bool = True
    conf: float = Field(
        1.0,
        description="Speaker-attribution confidence. ZERO info in live mode "
        "(hardcoded 1.0). Never feed to the gate.",
    )

    @property
    def duration(self) -> float:
        return self.end - self.start


# --- Hygiene layer output ----------------------------------------------------

class HygieneFlag(str, Enum):
    """Synthetic flags the hygiene layer attaches to a turn.

    These REPLACE `conf` as the gate's uncertainty signal: structural
    attribution moved the real uncertainty out of `conf` and into observable
    artifacts (short clatter turns, speaker bleed). Unlike `conf`, these carry
    information in live mode.
    """

    ATTRIBUTION_SUSPECT = "attribution_suspect"  # bleed duplicate or sub-0.5s me turn
    SHORT_ME = "short_me"                         # sub-threshold "me" turn (clatter/hallucination)
    BLEED_DUPLICATE = "bleed_duplicate"           # near-identical me/other within delta-t


class AnnotatedTurn(BaseModel):
    """A turn plus hygiene annotations. This is what the window and gate consume."""

    turn: Turn
    flags: list[HygieneFlag] = Field(default_factory=list)

    @property
    def attribution_suspect(self) -> bool:
        return HygieneFlag.ATTRIBUTION_SUSPECT in self.flags


def render_turn_line(at: AnnotatedTurn) -> str:
    """The ONE way a turn is rendered into a prompt.

    Both models see the identical line. This is not cosmetic: the responder's
    system prompt tells it to stay silent when the candidate rests on an
    attribution_suspect turn, which is only possible if the flag survives into
    the raw window it is shown. Keep gate and responder on this helper so the
    two renderings cannot drift apart again.
    """
    t = at.turn
    flag = " [attribution_suspect]" if at.attribution_suspect else ""
    return f"#{t.seq} {t.speaker}: {t.text}{flag}"


# --- Stream health (surfaced as a warning, never guessed into a turn) --------

class StreamHealthWarning(BaseModel):
    kind: Literal["no_other_audio"] = "no_other_audio"
    message: str
    since_seconds: float


# --- Gate (model 1) I/O ------------------------------------------------------

# The five response types (Decision 18). CANONICAL and SINGLE-SOURCE: gate.py
# and responder.py build their JSON-schema enums from RESPONSE_TYPE_ENUM below
# rather than re-typing the list, so adding a sixth type here is enough.
ResponseType = Literal[
    "answer",
    "correction",
    "enrichment",
    "abstraction-guard",
    "concept-explainer",
]

# The same values as a JSON-Schema `enum`, null included (both schemas allow the
# type to be omitted). Note there is deliberately NO "type" key alongside this
# in either schema - see the note in gate.GATE_SCHEMA.
RESPONSE_TYPE_ENUM: list = [*get_args(ResponseType), None]


class GateDecision(BaseModel):
    """Gate output. `None`-equivalent is `fire=False` (a candidate was NOT raised)."""

    fire: bool
    instruction: Optional[str] = None      # which instruction matched
    claim: Optional[str] = None            # the specific claim/question
    why: Optional[str] = None              # one-line rationale
    brief: Optional[str] = None            # dense pointer for the responder (NOT a replacement)
    context_hints: Optional[str] = None    # e.g. "references an earlier decision; read back"
    type: Optional[ResponseType] = None


class ResponderOutput(BaseModel):
    """Responder (model 2) output. Responder MAY stay silent (message=None)."""

    message: Optional[str] = None          # None => suppressed (precision)
    description: Optional[str] = None       # "what I'm answering" (right-side bubble)
    addressed_claim: Optional[str] = None   # fed back into recently-addressed memory
    type: Optional[ResponseType] = None
