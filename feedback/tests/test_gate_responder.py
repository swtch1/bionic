"""Gate and responder run offline via stubbed clients.

Proves the wiring and the two non-obvious contracts:
  - the gate NEVER sees `conf` (checked against the assembled prompt),
  - the responder may STAY SILENT (precision) on a correct fact,
  - the glanceability ceiling is enforced in code, not just requested.
"""

import pytest

from conftest import StubGateClient, StubResponderClient, make_turn

from feedbackapp.config import Resource, load_config
from feedbackapp.gate import Gate, build_gate_prompt
from feedbackapp.hygiene import Hygiene
from feedbackapp.models import GateDecision
from feedbackapp.responder import Responder


def _annot(seq, speaker, text, dur=3.0, conf=1.0):
    # Real hygiene flags, on turns spaced 1s apart from t=100 and 3s long by
    # default (long enough that no turn here trips the short-me threshold).
    return Hygiene().annotate(
        make_turn(seq, speaker, text, start=100.0 + seq, dur=dur, conf=conf))


def test_gate_prompt_never_contains_conf():
    window = [_annot(1, "other", "is the auth service in Go", conf=0.55)]
    prompt = build_gate_prompt(
        instructions="x", resource_registry="auth-service (repo): auth",
        window=window, newest_batch=window, recently_addressed=[],
    )
    assert "conf" not in prompt.lower()
    assert "0.55" not in prompt


def test_gate_fires_and_parses():
    stub = StubGateClient(decision={
        "fire": True, "instruction": "answer repo Q", "claim": "who owns refresh",
        "why": "direct question about auth-service", "brief": "auth owns refresh",
        "context_hints": None, "type": "answer",
    })
    gate = Gate(stub, "claude-haiku-4-5-20251001")
    window = [_annot(1, "other", "does auth own token refresh")]
    d = gate.evaluate(instructions="i", resource_registry="r",
                      window=window, newest_batch=window, recently_addressed=[])
    assert d.fire and d.type == "answer"


def test_gate_empty_batch_never_calls_model():
    stub = StubGateClient(decision={"fire": True})
    gate = Gate(stub, "m")
    d = gate.evaluate(instructions="i", resource_registry="r",
                      window=[], newest_batch=[], recently_addressed=[])
    assert d.fire is False
    assert stub.last_user is None  # never hit the model


# The real ceilings, so a config/config.yaml edit cannot leave this asserting
# stale numbers.
CEILINGS = load_config().glanceability


def _responder(emitted):
    resources = [Resource(name="billing-service", kind="repo", path="./x", desc="python billing")]
    return Responder(StubResponderClient(emitted), "claude-sonnet-5", resources, CEILINGS)


def test_responder_stays_silent_on_correct_fact():
    # Decision 11 case 3: gate flagged, but the claim holds -> responder silent.
    r = _responder({"message": None, "description": None, "addressed_claim": None, "type": "correction"})
    d = GateDecision(fire=True, claim="billing is python", type="correction")
    out = r.respond(d, raw_window="#1 other: billing is python")
    assert out.message is None


def test_responder_speaks_on_wrong_fact():
    r = _responder({"message": "Billing is Python, not Go. See billing-service/README.",
                    "description": "corrected: billing language",
                    "addressed_claim": "billing is Go", "type": "correction"})
    d = GateDecision(fire=True, claim="billing is Go", type="correction")
    out = r.respond(d, raw_window="#1 other: billing is Go")
    assert out.message and out.addressed_claim == "billing is Go"


@pytest.mark.parametrize("rtype", list(CEILINGS.keys()))
def test_glanceability_ceiling_suppresses_overlong_message(rtype):
    long_msg = " ".join(["word"] * 200)  # over every per-type ceiling
    r = _responder({"message": long_msg, "type": rtype, "addressed_claim": "c"})
    d = GateDecision(fire=True, claim="c", type=rtype)
    out = r.respond(d, raw_window="")
    assert out.message is None  # code-level guard suppressed it, per type


@pytest.mark.parametrize("rtype", list(CEILINGS.keys()))
def test_glanceability_ceiling_passes_terse_message(rtype):
    r = _responder({"message": "Billing is Python.", "type": rtype, "addressed_claim": "c"})
    d = GateDecision(fire=True, claim="c", type=rtype)
    out = r.respond(d, raw_window="")
    assert out.message == "Billing is Python."  # within every ceiling


def test_responder_prompt_includes_gate_why():
    # Item 8: the gate's one-line `why` (Decisions 5/13) must reach the responder
    # prompt, not be collected and dropped.
    from feedbackapp.responder import build_responder_prompt
    d = GateDecision(fire=True, claim="c", type="answer", brief="b",
                     why="user asked who owns token refresh")
    prompt = build_responder_prompt(decision=d, raw_window="#1 other: x", resources=[])
    assert "user asked who owns token refresh" in prompt
