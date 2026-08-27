"""OAuth-vs-API-key credential routing, and the failure policy around it.

The meeting these pin (2026-08-26): the user's only credential was an OAuth
token from `claude setup-token`, exported as ANTHROPIC_API_KEY. It went out as
`x-api-key`, the API returned 401 on every 100ms tick, and ~600 identical error
lines scrolled the meeting screen - burying the one stream-health warning that
mattered and telling the user their token was bad when the header was.
"""

import asyncio

from conftest import StubGateClient, build_orchestrator, jsonl_line

from feedbackapp.auth import API_KEY_ENV, OAUTH_ENV, classify, from_env
from feedbackapp.errors import Backoff, ErrorThrottle, is_auth_failure

_line = jsonl_line

OAT = "sk-ant-oat01-abc"
KEY = "sk-ant-api03-abc"


# --- credential detection -----------------------------------------------------

def test_oauth_token_goes_in_the_bearer_slot_not_x_api_key():
    kwargs = classify(OAT, source=API_KEY_ENV).client_kwargs()
    assert kwargs["auth_token"] == OAT
    # Explicit None, or the SDK reads ANTHROPIC_API_KEY back out of the env and
    # sends both headers.
    assert kwargs["api_key"] is None


def test_api_key_keeps_the_x_api_key_path():
    assert classify(KEY, source=API_KEY_ENV).client_kwargs() == {"api_key": KEY}


def test_unrecognised_shape_defaults_to_api_key():
    # Fail-safe: an unknown prefix behaves exactly as it did before this change.
    assert classify("whatever", source=API_KEY_ENV).client_kwargs() == {"api_key": "whatever"}


def test_oauth_env_var_wins_over_a_sniffed_api_key_var():
    cred = from_env({OAUTH_ENV: OAT, API_KEY_ENV: KEY})
    assert (cred.token, cred.is_oauth, cred.source) == (OAT, True, OAUTH_ENV)


def test_oauth_token_in_the_api_key_var_is_detected_by_prefix():
    cred = from_env({API_KEY_ENV: OAT})
    assert cred.is_oauth is True and cred.source == API_KEY_ENV


def test_no_credential_and_blank_credential_are_both_none():
    assert from_env({}) is None
    assert from_env({API_KEY_ENV: "   "}) is None


def test_subprocess_env_retracts_the_inherited_api_key_var():
    """The agent SDK merges env over os.environ and cannot delete a key, so an
    OAuth token left in ANTHROPIC_API_KEY would 401 inside the `claude` CLI
    exactly as it did in the gate. Blanking is the only retraction available."""
    env = classify(OAT, source=API_KEY_ENV).subprocess_env()
    assert env[OAUTH_ENV] == OAT
    assert env[API_KEY_ENV] == ""


def test_subprocess_env_for_an_api_key_passes_it_straight_through():
    assert classify(KEY, source=API_KEY_ENV).subprocess_env() == {API_KEY_ENV: KEY}


# --- failure classification ---------------------------------------------------

class _Auth401(Exception):
    status_code = 401


class _NamedLikeTheSdk(Exception):
    pass


_NamedLikeTheSdk.__name__ = "AuthenticationError"


def test_auth_failures_recognised_by_status_and_by_class_name():
    assert is_auth_failure(_Auth401())
    assert is_auth_failure(_NamedLikeTheSdk())


def test_transient_failures_are_not_auth_failures():
    class _RateLimit(Exception):
        status_code = 429

    assert not is_auth_failure(_RateLimit())
    assert not is_auth_failure(TimeoutError())


# --- throttling and backoff ---------------------------------------------------

def test_repeats_collapse_to_progressively_rarer_lines():
    t = ErrorThrottle()
    e = RuntimeError("boom")
    printed = [t.report(e) for _ in range(16)]
    assert printed[0] is not None
    emitted = [p for p in printed if p is not None]
    # 1st, 2nd, 4th, 8th, 16th - not 16 lines.
    assert len(emitted) == 5, emitted
    assert "(x16)" in emitted[-1]


def test_a_different_failure_always_prints_even_mid_storm():
    t = ErrorThrottle()
    for _ in range(5):
        t.report(RuntimeError("boom"))
    assert t.report(ValueError("something else")) is not None


def test_backoff_doubles_to_a_cap_and_resets_on_success():
    b = Backoff(base=1.0, cap=4.0)
    assert [b.fail(0.0) for _ in range(4)] == [1.0, 2.0, 4.0, 4.0]
    assert not b.ready(3.9) and b.ready(4.0)
    b.succeed()
    assert b.ready(0.0)


# --- the orchestrator policy --------------------------------------------------

class _AuthFailingGateClient:
    def __init__(self):
        self.calls = 0

    def complete_json(self, *, model, system, user, schema):
        self.calls += 1
        raise _Auth401("Error code: 401 - API key is invalid.")


def test_rejected_credential_disables_live_once_and_keeps_capturing(tmp_path):
    client = _AuthFailingGateClient()
    h = build_orchestrator(tmp_path, gate_client=client, poll_interval=0.02)

    async def scenario():
        run_task = asyncio.create_task(h.orch.run())
        for seq in range(1, 4):
            with open(h.target, "a") as fh:
                fh.write(_line(seq) + "\n")
            await asyncio.sleep(0.12)
        h.orch.stop()
        await run_task
        return h.stream.getvalue()

    out = asyncio.run(scenario())
    assert client.calls == 1, "kept retrying a permanently-rejected credential"
    assert out.count("live mode OFF") == 1, "the notice repeated, or never fired"
    assert "CLAUDE_CODE_OAUTH_TOKEN" in out, "notice does not say what to fix"
    # The recording is the part the user cannot redo: it must survive.
    assert "#3 other: turn 3" in out, "capture stopped when live mode was disabled"
    assert h.orch.gate is None and h.orch.responder is None


class _FlakyGateClient(StubGateClient):
    """Raises a transient failure on every call."""

    def complete_json(self, *, model, system, user, schema):
        self.calls += 1
        raise TimeoutError("connection timed out")


def test_transient_gate_failures_back_off_instead_of_flooding(tmp_path):
    client = _FlakyGateClient()
    h = build_orchestrator(tmp_path, gate_client=client, poll_interval=0.01)

    async def scenario():
        run_task = asyncio.create_task(h.orch.run())
        for seq in range(1, 16):
            with open(h.target, "a") as fh:
                fh.write(_line(seq) + "\n")
            await asyncio.sleep(0.02)
        h.orch.stop()
        await run_task
        return h.stream.getvalue()

    out = asyncio.run(scenario())
    # ~15 ticks with a live gate would be ~15 calls and 15 error lines. The
    # 1s first backoff means one call, one line, and the gate still enabled.
    assert client.calls == 1, f"gate was retried through its backoff ({client.calls} calls)"
    assert out.count("error: gate failed") == 1, out
    assert h.orch.gate is not None, "a transient failure must not disable live mode"
    assert "#15 other: turn 15" in out, "polling/rendering paused with the gate"
