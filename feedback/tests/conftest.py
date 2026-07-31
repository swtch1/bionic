import io
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# Make the package importable when running pytest from feedback/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from feedbackapp.config import DEFAULTS_DIR, Resource, load_config  # noqa: E402
from feedbackapp.gate import Gate  # noqa: E402
from feedbackapp.hygiene import Hygiene  # noqa: E402
from feedbackapp.orchestrator import Orchestrator  # noqa: E402
from feedbackapp.renderer import Renderer  # noqa: E402
from feedbackapp.responder import Responder  # noqa: E402
from feedbackapp.models import AnnotatedTurn, Turn  # noqa: E402
from feedbackapp.tailer import Tailer  # noqa: E402

# The resource registry every orchestrator/responder test used verbatim.
TEST_RESOURCES = [Resource(name="r", kind="repo", path="./x", desc="d")]


def jsonl_line(seq, text=None, *, speaker="other", start=None, dur=1.0,
               final=True, conf=1.0):
    """One LIVE-format JSONL turn.

    Defaults match what the tailer/orchestrator tests built inline: start
    1000.0 + seq, end start + dur, text "turn {seq}". Callers that pinned a
    different shape (fixed start, half-second turns, literal text) pass it in.
    """
    if start is None:
        start = 1000.0 + seq
    if text is None:
        text = f"turn {seq}"
    return json.dumps({"seq": seq, "start": start, "end": start + dur,
                       "speaker": speaker, "text": text, "final": final,
                       "conf": conf})


def make_turn(seq=1, speaker="other", text="hello there", *,
              start=100.0, dur=1.0, conf=1.0, final=True) -> Turn:
    """One in-memory Turn. `dur` is a convenience for end = start + dur.

    The defaults are deliberately neutral; every test whose timing MATTERS
    (hygiene's short-me / bleed windows, the renderer's clock) passes `start`
    and `dur` explicitly rather than inheriting them.
    """
    return Turn(seq=seq, start=start, end=start + dur, speaker=speaker,
                text=text, conf=conf, final=final)


def make_annotated(seq=1, speaker="other", text="hello there", *, flags=None,
                   **kwargs) -> AnnotatedTurn:
    """A Turn wrapped in an AnnotatedTurn WITHOUT running hygiene.

    Tests that want the real hygiene flags call Hygiene().annotate(make_turn(...)).
    """
    return AnnotatedTurn(turn=make_turn(seq, speaker, text, **kwargs),
                         flags=[] if flags is None else flags)


class StubGateClient:
    """Gate client returning a canned decision.

    fire=True/False for a constant answer; fire="once" fires on the first
    evaluation only. `decision` overrides the whole payload. Records `calls`
    and `last_user`.
    """

    def __init__(self, fire=True, decision: Optional[dict] = None):
        self._fire = fire
        self._decision = decision
        self.calls = 0
        self.last_user = None

    def complete_json(self, *, model, system, user, schema):
        self.calls += 1
        self.last_user = user
        if self._decision is not None:
            return json.dumps(self._decision)
        fire = self.calls == 1 if self._fire == "once" else bool(self._fire)
        return json.dumps({"fire": fire, "claim": "c", "type": "answer", "brief": "b"})


class StubResponderClient:
    """Responder client returning a canned emission, optionally slowly.

    Records `calls` and `returned_at`.
    """

    DEFAULT = {"message": "answer.", "description": "d",
               "addressed_claim": "c", "type": "answer"}

    def __init__(self, emitted: Optional[dict] = None, delay: float = 0.0):
        self._emitted = self.DEFAULT if emitted is None else emitted
        self.delay = delay
        self.calls = 0
        self.returned_at = None

    def run(self, *, model, system, prompt):
        self.calls += 1
        if self.delay:
            time.sleep(self.delay)
        self.returned_at = time.monotonic()
        return dict(self._emitted)


@dataclass
class Harness:
    orch: Orchestrator
    target: Path
    stream: Any
    config: Any


def build_orchestrator(tmp_path=None, *, gate_client=None, resp_client=None,
                       clock=None, renderer=None, stream=None,
                       poll_interval=None, target=None) -> Harness:
    """The orchestrator wiring every orchestrator test repeated inline.

    gate/responder are built only when a client is supplied, so the offline
    path (gate=None, responder=None) is the default. Ceilings come from
    config/config.yaml so a yaml edit cannot leave a test asserting stale
    numbers.
    """
    config = load_config(DEFAULTS_DIR)
    if poll_interval is not None:
        config.poll_interval_seconds = poll_interval
    if target is None:
        target = tmp_path / "live.jsonl"
        target.write_text("")
    if renderer is None:
        stream = io.StringIO() if stream is None else stream
        renderer = Renderer(stream=stream)
    kwargs = {}
    if clock is not None:
        kwargs["clock"] = clock
    orch = Orchestrator(
        config=config,
        tailer=Tailer(target),
        hygiene=Hygiene(config.hygiene),
        renderer=renderer,
        gate=Gate(gate_client, "m") if gate_client is not None else None,
        responder=(Responder(resp_client, "m", TEST_RESOURCES,
                             config.glanceability)
                   if resp_client is not None else None),
        **kwargs,
    )
    return Harness(orch=orch, target=target, stream=stream, config=config)
