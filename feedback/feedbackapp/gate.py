"""Gate (model 1) - Decisions 5, 12, 13.

Cheap, NO tools, forced structured JSON via the raw Anthropic API. Optimizes
RECALL: it should over-fire; the responder (precision) decides whether to speak.

Inputs (Decision 13):
  - instructions.md (global + per-meeting overlay)
  - resource registry names + descriptions (NOT paths; no tools here)
  - the 10-turn window with an EXPLICIT newest-turn FOCUS (the window is context,
    NOT reduced to the latest line - Decision 12)
  - recently-addressed memory (claims the responder already spoke on)

Output (Decision 13): none | {instruction, claim, why, brief, context_hints, type}

CRITICAL constraints baked in here:
  - `conf` is NEVER shown to the gate (hardcoded 1.0 in live mode = zero info).
    The gate's only uncertainty signal is hygiene's synthetic attribution_suspect
    flag, which we DO surface per turn.
  - No question detection by trailing "?" - the gate reads intent as an LLM.

The Anthropic client is injected so tests run offline against a stub.
"""

from __future__ import annotations

import json
import logging
from typing import Protocol

from pydantic import ValidationError

from .models import RESPONSE_TYPE_ENUM, AnnotatedTurn, GateDecision, render_turn_line

log = logging.getLogger("feedback.gate")


GATE_SYSTEM = """You are the GATE in a two-stage private meeting co-pilot. You run on every \
speaker turn and decide whether a candidate is worth escalating to a smarter, \
tooled responder. Optimize RECALL: when unsure, fire. The responder will verify \
and may stay silent.

You receive: the user's instructions, a registry of resources (names + \
descriptions only), a rolling window of recent turns, an explicit FOCUS on the \
newest turn(s), and a list of claims already addressed (skip those).

Rules:
- The window is CONTEXT for interpreting the focus turn. Judge the FOCUS, using \
the window to resolve references.
- The speaker tag is "me" (the user) or "other". Act on the user's own turns too \
(catch his errors, flag rabbit-holing).
- Some turns are flagged attribution_suspect: their speaker label may be wrong \
(keyboard clatter or cross-channel bleed). Do not build a correction of the \
user's "own" error on a suspect turn.
- Do NOT re-raise anything in the already-addressed list.
- Choose exactly one type: answer, correction, enrichment, abstraction-guard, \
concept-explainer.
- Emit a dense `brief` (a pointer for the responder, not a replacement) and \
`context_hints` (e.g. note if the claim depends on turns older than the window).

Return fire=false when nothing actionable is in the focus."""


GATE_SCHEMA = {
    "type": "object",
    "properties": {
        "fire": {"type": "boolean"},
        "instruction": {"type": ["string", "null"]},
        "claim": {"type": ["string", "null"]},
        "why": {"type": ["string", "null"]},
        "brief": {"type": ["string", "null"]},
        "context_hints": {"type": ["string", "null"]},
        # NO "type" key here, deliberately. The API's schema validator checks each
        # enum value against a declared type, and a union type makes that check
        # fail outright:
        #   400 output_config.format.schema: Invalid schema: Enum value 'answer'
        #       does not match declared type '['string', 'null']'
        # A bare `enum` is valid JSON Schema and already constrains the value to
        # exactly this list, null included - the type declaration bought nothing.
        # Verified against the live API; a stub client will NOT catch a regression.
        "type": {"enum": RESPONSE_TYPE_ENUM},
    },
    "required": ["fire"],
    "additionalProperties": False,
}


class GateClient(Protocol):
    """Minimal surface the gate needs. The real impl wraps anthropic.Anthropic;
    tests pass a stub. Returns the raw JSON text of the structured output."""

    def complete_json(self, *, model: str, system: str, user: str, schema: dict) -> str:
        ...


class AnthropicGateClient:
    """Real gate client - raw Anthropic API, forced JSON, no tools.

    Uses output_config.format (json_schema). No claude-agent-sdk here: the gate
    is tool-less, so the SDK buys nothing (Decision 6).
    """

    # The gate runs INSIDE the tick, so a hung call freezes polling, rendering
    # and stream-health for its whole duration. The SDK defaults (600s read,
    # 2 retries) mean one bad connection could go dark for ~30 minutes mid-
    # meeting with no indication anything was wrong. The gate is a cheap Haiku
    # call on a 100ms loop: if it hasn't answered in 15s the window has moved on
    # and the answer is worthless anyway, so fail fast and catch the next turn.
    TIMEOUT_SECONDS = 15.0
    MAX_RETRIES = 1

    def __init__(self, client=None):
        # Imported lazily so the offline path never requires the dependency.
        if client is None:
            import anthropic

            client = anthropic.Anthropic(
                timeout=self.TIMEOUT_SECONDS, max_retries=self.MAX_RETRIES
            )
        self._client = client

    def complete_json(self, *, model: str, system: str, user: str, schema: dict) -> str:
        resp = self._client.messages.create(
            model=model,
            max_tokens=1024,
            system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"format": {"type": "json_schema", "schema": schema}},
        )
        for block in resp.content:
            if block.type == "text":
                return block.text
        raise ValueError("gate: no text block in response")


def build_gate_prompt(
    *,
    instructions: str,
    resource_registry: str,
    window: list[AnnotatedTurn],
    newest_batch: list[AnnotatedTurn],
    recently_addressed: list[str],
) -> str:
    """Assemble the gate's user message. Never includes `conf`."""
    window_text = "\n".join(render_turn_line(at) for at in window) or "(empty)"
    focus_seqs = [at.turn.seq for at in newest_batch]
    focus_text = "\n".join(render_turn_line(at) for at in newest_batch) or "(none)"
    addressed = "\n".join(f"- {c}" for c in recently_addressed) or "(none)"
    return (
        f"# Instructions\n{instructions}\n\n"
        f"# Resources (names + descriptions)\n{resource_registry}\n\n"
        f"# Window (context - last {len(window)} turns)\n{window_text}\n\n"
        f"# FOCUS (evaluate these newest turns, seq {focus_seqs})\n{focus_text}\n\n"
        f"# Already addressed (do not re-raise)\n{addressed}\n"
    )


class Gate:
    def __init__(self, client: GateClient, model: str):
        self._client = client
        self._model = model

    def evaluate(
        self,
        *,
        instructions: str,
        resource_registry: str,
        window: list[AnnotatedTurn],
        newest_batch: list[AnnotatedTurn],
        recently_addressed: list[str],
    ) -> GateDecision:
        if not newest_batch:
            return GateDecision(fire=False)
        user = build_gate_prompt(
            instructions=instructions,
            resource_registry=resource_registry,
            window=window,
            newest_batch=newest_batch,
            recently_addressed=recently_addressed,
        )
        raw = self._client.complete_json(
            model=self._model, system=GATE_SYSTEM, user=user, schema=GATE_SCHEMA
        )
        # Malformed structured output is a NORMAL LLM failure mode, not an
        # exception: treat unparseable gate output as "don't fire" and move on.
        # (A transient API/client error is NOT swallowed here - it propagates to
        # the orchestrator's per-tick guard, which logs and keeps the loop alive.)
        try:
            return GateDecision.model_validate(json.loads(raw))
        except (json.JSONDecodeError, ValidationError, TypeError) as e:
            log.warning("gate returned unparseable output (%s); treating as no-fire", e.__class__.__name__)
            return GateDecision(fire=False)
