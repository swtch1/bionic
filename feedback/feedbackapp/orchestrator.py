"""Orchestrator - the async traffic cop (Decision 16: roll-your-own, no LangGraph).

Per-TICK loop (this supersedes architecture-v0's "one line = one trigger", which
is wrong given TurnMerger's burst flushing):

    every poll_interval:
      tick = tailer.poll()                      # ORDERED BATCH of new turns
      for turn in tick.turns:                   # apply the whole batch...
          at = hygiene.annotate(turn)
          renderer.turn(at)                      # renderer runs before the gate
          annotated.append(at)
      window.extend(annotated)                   # ...then update the window once
      surface stream-health warnings + tail events
      evaluate the GATE ONCE, batch = newest-turn focus
      if fire and off cooldown and none in flight and under cap:
          run RESPONDER (guarded by in_flight)
          render + record addressed_claim

The gate/responder are optional: with no API key, pass gate=None/responder=None
and the offline path (replay -> tailer -> hygiene -> renderer) still runs fully.
"""

from __future__ import annotations

import asyncio
import time
from typing import Optional

from .config import AppConfig
from .errors import Backoff, ErrorThrottle, is_auth_failure
from .gate import Gate
from .hygiene import Hygiene
from .models import AnnotatedTurn, render_turn_line
from .renderer import Renderer
from .responder import Responder, ResponderSilent
from .tailer import Tailer
from .window import OrchestratorState, Window


class Orchestrator:
    def __init__(
        self,
        *,
        config: AppConfig,
        tailer: Tailer,
        hygiene: Hygiene,
        renderer: Renderer,
        gate: Optional[Gate] = None,
        responder: Optional[Responder] = None,
        clock=time.monotonic,
    ):
        self.config = config
        self.tailer = tailer
        self.hygiene = hygiene
        self.renderer = renderer
        self.gate = gate
        self.responder = responder
        self.window = Window(size=config.window.window_size)
        self.state = OrchestratorState(config=config.window)
        self._clock = clock
        self._stop = False
        self._gate_backoff = Backoff()
        self._throttle = ErrorThrottle()

    def stop(self) -> None:
        self._stop = True

    def tick(self) -> None:
        """One synchronous poll->process cycle: fast path, then (if the gate
        fired) the responder inline. Kept synchronous so tests drive the whole
        cycle deterministically. The async run() loop instead runs the fast path
        on the interval and dispatches the responder in the BACKGROUND - see
        run() - so a slow responder never stalls polling/rendering."""
        job = self._fast_path()
        if job is not None:
            self._run_responder(job)

    def _fast_path(self) -> Optional[tuple]:
        """The cheap, must-never-lag half: poll, annotate, render, update the
        window, surface health, and evaluate the gate. Returns a
        (decision, raw_window) job when a responder should be launched, else
        None. Sets state.in_flight True when it returns a job, so the guard is
        live BEFORE the (possibly slow, possibly background) responder runs."""
        result = self.tailer.poll()

        annotated: list[AnnotatedTurn] = []
        for turn in result.turns:
            # Per-TURN boundary, not just per-tick. The tick guard in run() is
            # too coarse: the tailer has already advanced its offset by the time
            # we get here, so one poisonous turn taking out the batch drops the
            # VALID turns beside it permanently - they can never be re-read.
            # Skip the one bad turn instead.
            try:
                at = self.hygiene.annotate(turn)
                self.renderer.turn(at)
            except Exception as e:
                self.renderer.notice(
                    f"error: skipping turn #{turn.seq}: {e.__class__.__name__}: {e}"
                )
                continue
            annotated.append(at)

        for kind, detail in result.events:
            self.renderer.debug(f"tail:{kind}: {detail}")

        if not annotated:
            # Still surface stream-health even on an empty tick.
            self._surface_stream_health()
            return None

        self.window.extend(annotated)
        self._surface_stream_health()

        if self.gate is None:
            return None  # offline path: renderer only

        # Skip the gate ENTIRELY while a responder is in flight, rather than
        # running it and dropping the candidate on the guard below. Deliberate
        # choice (Decision 12 anti-spam): a responder answers about a window
        # that is already moving, so a candidate raised mid-flight would be
        # stale by the time the current responder returns anyway - and running
        # the gate just to discard it burns a Haiku call every 100ms tick for
        # nothing. Cost: a genuinely hot turn arriving mid-response waits until
        # the current one finishes. Acceptable at one-response-at-a-time.
        if self.state.in_flight:
            return None

        decision = self._evaluate_gate()
        if decision is None or not decision.fire:
            return None

        ok, reason = self.state.can_fire(self._clock())
        if not ok:
            self.renderer.debug(f"gate fired but suppressed: {reason}")
            return None
        if self.responder is None:
            self.renderer.debug(f"gate candidate (no responder wired): {decision.claim}")
            return None

        # Claim the in-flight guard NOW, synchronously, before returning the job.
        # In run() the responder executes in a background task; the guard has to
        # be set before this fast-path invocation returns or the very next tick
        # could launch a second responder against the same window.
        self.state.in_flight = True
        # Same renderer the gate uses (models.render_turn_line) so the responder
        # sees the attribution_suspect flags its system prompt tells it to act on.
        raw_window = "\n".join(render_turn_line(at) for at in self.window.turns)
        return (decision, raw_window)

    def _evaluate_gate(self):
        """The gate call plus its failure policy (see errors.py). Returns a
        decision, or None when the gate is disabled, backing off, or just failed.

        Deliberately NOT left to the per-tick boundary in run(): that catch is
        too coarse to tell a rejected credential from a 429, and pausing the
        whole tick would pause polling and rendering with it - the half that
        must never lag behind the meeting."""
        if not self._gate_backoff.ready(self._clock()):
            return None
        try:
            decision = self.gate.evaluate(
                instructions=self.config.instructions,
                resource_registry=self.config.resource_registry_text,
                window=self.window.turns,
                newest_batch=self.window.newest_batch,
                recently_addressed=list(self.state.recently_addressed),
            )
        except Exception as e:
            if is_auth_failure(e):
                self._disable_live(e)
            else:
                delay = self._gate_backoff.fail(self._clock())
                line = self._throttle.report(e)
                if line is not None:
                    self.renderer.notice(f"error: gate failed: {line} - retrying in {delay:.0f}s")
            return None
        self._gate_backoff.succeed()
        return decision

    def _disable_live(self, exc: Exception) -> None:
        """Turn the live path off for the rest of the session, once, loudly.

        Capture keeps running: the transcript and the diarization that follows it
        are the part of the meeting the user cannot get back, and they need no
        credential at all."""
        self.gate = None
        self.responder = None
        self.renderer.notice(
            f"live mode OFF: credential rejected ({exc.__class__.__name__}). "
            "Capture and diarization continue.\n"
            "     `claude setup-token` mints an OAuth token, not an API key - it must be "
            "exported as CLAUDE_CODE_OAUTH_TOKEN, not ANTHROPIC_API_KEY."
        )

    def _run_responder(self, job: tuple) -> None:
        """The slow half: run the responder, render its output, record the
        addressed claim, and release the in-flight guard. In run() this executes
        in a background thread task so it never blocks the poll loop. in_flight
        stays True until recording is done, so no second responder starts until
        recently-addressed has been updated."""
        decision, raw_window = job
        try:
            out = self.responder.respond(decision, raw_window)
            self.renderer.response(out)
            if out.message is not None:
                self.state.record_response(out.addressed_claim, self._clock())
            else:
                # Responder verified the candidate and chose silence. Record it
                # as considered-and-suppressed (item 5) so the gate doesn't
                # re-escalate the same claim to the expensive tooled path over
                # and over. This does NOT touch cooldown/cap - no user-visible
                # response happened - only the recently-addressed memory.
                self.state.record_suppressed(out.addressed_claim or decision.claim)
        except Exception as e:
            # Ctrl-C signals the whole process GROUP, so the responder's CLI
            # subprocess dies mid-run and the agent never reaches emit_feedback.
            # That is shutdown, not breakage - reporting it as an error on the
            # last line the user sees before exiting is pure alarm. Outside
            # shutdown, ResponderSilent still surfaces loudly: it is exactly the
            # signal that the emit tool is unwired again. ResponderSilent is
            # defined in responder.py (not responder_live) precisely so this can
            # be a type check without importing the SDK-dependent module.
            if self._stop and isinstance(e, ResponderSilent):
                self.renderer.debug("responder interrupted by shutdown before emitting")
            elif is_auth_failure(e):
                # Same permanent failure as on the gate side, reached when the
                # gate is authorised and the responder's CLI subprocess is not.
                self._disable_live(e)
            else:
                # A responder/API failure must not vanish as an unretrieved-task
                # dump on stderr (item 3): surface it through the same channel as
                # everything else, and let the loop continue.
                self.renderer.notice(f"error: responder failed: {e.__class__.__name__}: {e}")
        finally:
            self.state.in_flight = False

    def _surface_stream_health(self) -> None:
        # Reference clock is the latest turn seen in the stream (not wall time),
        # so replayed historical fixtures don't warn spuriously. Consequence: the
        # warning fires when the far side dies while the user keeps talking (me
        # turns advance the clock), but NOT on a fully-silent stream where no
        # turns arrive at all - detecting that would need wall-time and is a
        # separate feature, deliberately not built in v0.
        warning = self.hygiene.stream_health()
        if warning is not None:
            self.renderer.stream_health(warning)

    async def run(self) -> None:
        """Async loop: run the FAST PATH on the configured interval, and launch
        the responder as a BACKGROUND task so it never stalls polling/rendering.

        Two things force the worker-thread hop:
          - the live responder client uses asyncio.run() internally
            (claude-agent-sdk's query() is async); calling it from this running
            loop raises "asyncio.run() cannot be called from a running event
            loop", so it runs in a thread that has no loop of its own;
          - even a purely-blocking responder must not be awaited in-line, or the
            next poll waits for it. A tooled responder (web search) is easily
            10-30s; awaiting it would freeze the renderer - the one component
            whose whole point is cheap live visibility - exactly while feedback
            is being produced.

        Only ONE responder runs at a time: _fast_path claims state.in_flight
        before returning a job and skips the gate while it is set, so the
        background task is never doubled up. This is now demonstrated by
        test_orchestrator_concurrency.py (renderer keeps emitting during a slow
        responder); do not revert to awaiting the responder inline.
        """
        interval = self.config.poll_interval_seconds
        pending: set[asyncio.Task] = set()
        while not self._stop:
            # Per-tick exception boundary (item 1): a malformed gate response,
            # or a transient API error (429/529/timeout), must NOT propagate out
            # of the loop - that would skip the drain + tailer.close() below and
            # leave the renderer dark permanently, mid-meeting. Log it through
            # the renderer channel and keep polling.
            try:
                job = await asyncio.to_thread(self._fast_path)
            except Exception as e:
                self.renderer.notice(f"error: tick failed: {e.__class__.__name__}: {e}")
                job = None
            if job is not None:
                task = asyncio.create_task(asyncio.to_thread(self._run_responder, job))
                pending.add(task)
                task.add_done_callback(pending.discard)
            await asyncio.sleep(interval)
        if pending:
            # Let an in-flight responder finish so its output/record aren't lost.
            await asyncio.gather(*pending, return_exceptions=True)
        self.tailer.close()
