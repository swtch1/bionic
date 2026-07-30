"""Orchestrator per-tick semantics: the gate is evaluated ONCE per tick on a
burst (not once per line), and anti-spam (cooldown/in-flight/cap) gates the
responder."""

from conftest import StubGateClient, StubResponderClient, build_orchestrator, jsonl_line

_line = jsonl_line


def test_gate_evaluated_once_per_burst_tick(tmp_path):
    gate_client = StubGateClient()
    resp_client = StubResponderClient()
    t = [1000.0]
    h = build_orchestrator(tmp_path, gate_client=gate_client,
                           resp_client=resp_client, clock=lambda: t[0])
    # Four lines land before the single poll -> one gate call, one responder call.
    h.target.write_text("\n".join(_line(i) for i in range(1, 5)) + "\n")
    h.orch.tick()
    assert gate_client.calls == 1
    assert resp_client.calls == 1


def test_raw_window_carries_attribution_suspect(tmp_path):
    """The responder is told to stay silent when the candidate rests on an
    attribution_suspect turn, so the raw window it is shown MUST carry the flag.
    The orchestrator once rendered its own turn lines without it; gate and
    responder now share models.render_turn_line. Regression guard."""
    prompts = []

    class RecordingResponderClient(StubResponderClient):
        def run(self, *, model, system, prompt):
            prompts.append(prompt)
            return super().run(model=model, system=system, prompt=prompt)

    gate_client = StubGateClient()
    h = build_orchestrator(tmp_path, gate_client=gate_client,
                           resp_client=RecordingResponderClient(),
                           clock=lambda: 1000.0)
    # A sub-0.5s "me" turn is clatter -> hygiene flags attribution_suspect.
    h.target.write_text(
        _line(1, "yes", speaker="me", start=1000.0, dur=0.2) + "\n"
        + _line(2, "and the billing service is python", start=1001.0) + "\n"
    )
    h.orch.tick()

    assert prompts, "responder was never called"
    raw = prompts[0]
    assert "#1 me: yes [attribution_suspect]" in raw
    # The clean turn is not flagged, i.e. the flag is per-turn, not blanket.
    assert "#2 other: and the billing service is python\n" in raw + "\n"
    # And the gate sees the identical line - the two renderings must not drift.
    assert "#1 me: yes [attribution_suspect]" in gate_client.last_user


def test_cooldown_suppresses_second_response(tmp_path):
    gate_client = StubGateClient()
    resp_client = StubResponderClient()
    t = [1000.0]
    h = build_orchestrator(tmp_path, gate_client=gate_client,
                           resp_client=resp_client, clock=lambda: t[0])

    h.target.write_text(_line(1) + "\n")
    h.orch.tick()
    assert resp_client.calls == 1

    # Second tick within cooldown (default 25s): gate fires, responder suppressed.
    t[0] += 5.0
    with open(h.target, "a") as fh:
        fh.write(_line(2) + "\n")
    h.orch.tick()
    assert gate_client.calls == 2
    assert resp_client.calls == 1  # still 1 - cooldown blocked the launch

    # After cooldown elapses, it fires again.
    t[0] += 30.0
    with open(h.target, "a") as fh:
        fh.write(_line(3) + "\n")
    h.orch.tick()
    assert resp_client.calls == 2
