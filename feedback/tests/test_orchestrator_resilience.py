"""Resilience: a single bad gate/responder response must not kill the loop
(review items 1 and 3), and malformed gate JSON is a NORMAL failure = no-fire,
not an exception (item 1).

The renderer's whole justification is cheap live visibility; an unguarded
exception out of the poll loop makes it go dark permanently, mid-meeting. These
prove the loop survives and the error is surfaced through the renderer channel.
"""

import asyncio

from conftest import (
    StubGateClient,
    StubResponderClient,
    build_orchestrator,
    jsonl_line,
    make_annotated,
)

from feedbackapp.gate import Gate

_line = jsonl_line


class _BadJsonGateClient:
    def complete_json(self, *, model, system, user, schema):
        return "this is not json{{"


class _RaisingGateClient:
    def complete_json(self, *, model, system, user, schema):
        raise RuntimeError("simulated 429 from the API")


class _RaisingResponderClient:
    def run(self, *, model, system, prompt):
        raise RuntimeError("simulated responder/API failure")


# --- item 1: malformed gate JSON is no-fire, not an exception -----------------

def test_gate_malformed_json_is_no_fire(tmp_path):
    gate = Gate(_BadJsonGateClient(), "m")
    at = make_annotated(1, "other", "hi", start=1.0, dur=1.0)
    decision = gate.evaluate(
        instructions="i", resource_registry="r",
        window=[at], newest_batch=[at], recently_addressed=[],
    )
    assert decision.fire is False


# --- item 1: a raising gate does not kill the run loop ------------------------

def test_run_loop_survives_raising_gate(tmp_path):
    h = build_orchestrator(tmp_path, gate_client=_RaisingGateClient(),
                           resp_client=_RaisingResponderClient(),
                           poll_interval=0.02)

    async def scenario():
        run_task = asyncio.create_task(h.orch.run())
        with open(h.target, "a") as fh:
            fh.write(_line(1) + "\n")   # triggers the raising gate
        await asyncio.sleep(0.15)
        with open(h.target, "a") as fh:
            fh.write(_line(2) + "\n")   # must still be polled+rendered if loop lived
        await asyncio.sleep(0.15)
        h.orch.stop()
        await run_task
        return h.stream.getvalue()

    out = asyncio.run(scenario())
    assert "#2 other: turn 2" in out, "loop died on the gate exception - turn 2 never rendered"
    assert "error" in out.lower(), "gate failure was not surfaced through the renderer"


# --- item 3: a raising responder does not kill the loop and is surfaced -------

def test_run_loop_survives_raising_responder(tmp_path):
    h = build_orchestrator(tmp_path, gate_client=StubGateClient(fire=True),
                           resp_client=_RaisingResponderClient(),
                           poll_interval=0.02)

    async def scenario():
        run_task = asyncio.create_task(h.orch.run())
        with open(h.target, "a") as fh:
            fh.write(_line(1) + "\n")   # gate fires -> responder raises
        await asyncio.sleep(0.2)
        with open(h.target, "a") as fh:
            fh.write(_line(2) + "\n")
        await asyncio.sleep(0.2)
        h.orch.stop()
        await run_task
        return h.stream.getvalue()

    out = asyncio.run(scenario())
    assert "#2 other: turn 2" in out, "loop died on the responder exception"
    assert "error" in out.lower(), "responder failure was not surfaced through the renderer"
    assert h.orch.state.in_flight is False, "in_flight leaked after a responder exception"


# --- item 5: a deliberately-silent responder still records the claim ----------

def test_silent_responder_records_suppressed_claim(tmp_path):
    h = build_orchestrator(
        tmp_path, gate_client=StubGateClient(fire=True),
        resp_client=StubResponderClient({"message": None, "description": None,
                                         "addressed_claim": "the-claim",
                                         "type": "answer"}),
        poll_interval=0.02)
    h.target.write_text(_line(1) + "\n")
    h.orch.tick()  # synchronous: gate fires, responder stays silent
    assert "the-claim" in list(h.orch.state.recently_addressed), (
        "a verified-then-silenced claim was not remembered - it can be "
        "re-escalated to the tooled path repeatedly")


# --- Ctrl-C kills the responder's CLI subprocess mid-run (2026-07-28) ---------
# SIGINT hits the whole process group, so the agent never reaches emit_feedback
# and ResponderSilent is raised. During shutdown that is expected, not a fault:
# it must NOT be the alarming last line the user sees. Outside shutdown the same
# exception must still shout - it is the signal that emit_feedback is unwired.

class _UnwiredResponderClient:
    def run(self, *, model, system, prompt):
        from feedbackapp.responder_live import ResponderSilent

        raise ResponderSilent("agent finished without calling emit_feedback")


def test_responder_silent_during_shutdown_is_not_an_error(tmp_path):
    h = build_orchestrator(tmp_path, gate_client=StubGateClient(fire=True),
                           resp_client=_UnwiredResponderClient(),
                           poll_interval=0.02)
    h.target.write_text(_line(1) + "\n")
    h.orch.stop()  # simulate Ctrl-C having already been handled
    h.orch.tick()
    text = h.stream.getvalue()
    assert "error:" not in text
    assert "interrupted by shutdown" in text


def test_responder_silent_outside_shutdown_is_surfaced_loudly(tmp_path):
    h = build_orchestrator(tmp_path, gate_client=StubGateClient(fire=True),
                           resp_client=_UnwiredResponderClient(),
                           poll_interval=0.02)
    h.target.write_text(_line(1) + "\n")
    h.orch.tick()
    assert "error: responder failed: ResponderSilent" in h.stream.getvalue()
