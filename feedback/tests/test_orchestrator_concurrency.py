"""Proves the fast path (poll -> hygiene -> render -> window) keeps running
while a SLOW responder is in flight.

The bug this pins: if the async loop awaits the responder inline, nothing polls
or renders during a tooled responder call (10-30s with web search), so the
renderer - whose entire justification is cheap live visibility - goes dark
exactly when feedback is being produced.

Property asserted: turns appended DURING a 1s responder call are rendered
BEFORE that responder returns. Under the serialized (await-inline) version this
fails, because the poll that would pick them up cannot run until the responder
finishes. Verified to fail against that version, then restored.
"""

import asyncio
import io
import time

from conftest import StubGateClient, StubResponderClient, build_orchestrator, jsonl_line

from feedbackapp.renderer import Renderer

_line = jsonl_line


class _TimingRenderer(Renderer):
    """Records the monotonic time each turn was rendered, keyed by seq."""

    def __init__(self):
        super().__init__(stream=io.StringIO())
        self.turn_times = {}

    def turn(self, at):
        self.turn_times[at.turn.seq] = time.monotonic()
        super().turn(at)


def test_renderer_keeps_emitting_during_slow_responder(tmp_path):
    # The gate fires on the FIRST evaluation only; later evaluations return
    # no-fire so the assertion is about the fast path, not repeated responders.
    gate_client = StubGateClient(fire="once")
    resp_client = StubResponderClient(delay=1.0)
    renderer = _TimingRenderer()
    h = build_orchestrator(tmp_path, gate_client=gate_client,
                           resp_client=resp_client, renderer=renderer,
                           poll_interval=0.02)
    orch, target = h.orch, h.target

    async def scenario():
        run_task = asyncio.create_task(orch.run())

        # Trigger line -> gate fires -> responder launched (sleeps 1s).
        with open(target, "a") as fh:
            fh.write(_line(1) + "\n")

        # Wait until the responder has actually started, then append more lines
        # DURING its sleep. If polling were blocked, these would not render until
        # after returned_at.
        await asyncio.sleep(0.25)
        assert orch.state.in_flight, "responder should be in flight by now"
        with open(target, "a") as fh:
            fh.write(_line(2) + "\n")
            fh.write(_line(3) + "\n")

        # Give the fast path a few poll intervals to pick them up - still well
        # inside the 1s responder sleep.
        await asyncio.sleep(0.25)

        rendered_2 = renderer.turn_times.get(2)
        rendered_3 = renderer.turn_times.get(3)

        # Now let the responder finish.
        await asyncio.sleep(0.8)
        orch.stop()
        await run_task
        return rendered_2, rendered_3, resp_client.returned_at

    rendered_2, rendered_3, returned_at = asyncio.run(scenario())

    assert returned_at is not None, "responder never returned"
    assert rendered_2 is not None and rendered_3 is not None, (
        "turns appended during the responder call were never rendered - the "
        "poll loop was blocked by the responder")
    assert rendered_2 < returned_at, "turn 2 rendered only after the responder returned (serialized)"
    assert rendered_3 < returned_at, "turn 3 rendered only after the responder returned (serialized)"
    # Exactly one responder ran despite three turns: the in-flight guard held.
    # (This line used to re-assert `returned_at is not None` - byte-identical to
    # the check above - so the claim in the comment was never actually tested.)
    assert resp_client.calls == 1, f"in-flight guard leaked: {resp_client.calls} responders ran"
