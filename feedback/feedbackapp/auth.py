"""Which credential we have, and how each transport wants it.

Two credential shapes reach this app and they are NOT interchangeable:

    sk-ant-api03-...   console API key                -> `x-api-key`
    sk-ant-oat01-...   OAuth token, `claude setup-token` -> `Authorization: Bearer`

An OAuth token placed in ANTHROPIC_API_KEY is sent as `x-api-key` and the API
answers `401 API key is invalid` on EVERY gate tick - several hundred identical
lines over one meeting, pointing at the token rather than at the header it was
put in. Users on a corporate plan cannot mint a console key at all, so the OAuth
token is their only credential and this path has to work.

Pure and env-injectable so the tests cover it offline; the transports below just
splat the dicts. Anything that isn't recognisably an OAuth token is treated as
an API key - that is today's behaviour, kept as the fail-safe default.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

OAUTH_PREFIX = "sk-ant-oat"
API_KEY_ENV = "ANTHROPIC_API_KEY"
OAUTH_ENV = "CLAUDE_CODE_OAUTH_TOKEN"


@dataclass(frozen=True)
class Credential:
    token: str
    is_oauth: bool
    source: str  # env var it came from, for error messages

    @property
    def kind(self) -> str:
        return "OAuth token" if self.is_oauth else "API key"

    def client_kwargs(self) -> dict:
        """Kwargs for `anthropic.Anthropic(...)` (the gate).

        `api_key=None` is explicit on the OAuth branch: without it the SDK reads
        ANTHROPIC_API_KEY back out of the environment and sends both headers.
        """
        if self.is_oauth:
            return {"api_key": None, "auth_token": self.token}
        return {"api_key": self.token}

    def subprocess_env(self) -> dict[str, str]:
        """Env overrides for the `claude` CLI the responder spawns.

        The SDK merges these over os.environ, so an OAuth token in
        ANTHROPIC_API_KEY is still visible to the CLI and still wrong there;
        blanking it is the only way to retract an inherited variable.
        """
        if self.is_oauth:
            return {OAUTH_ENV: self.token, API_KEY_ENV: ""}
        return {API_KEY_ENV: self.token}


def classify(token: str, *, source: str) -> Credential:
    return Credential(
        token=token, is_oauth=token.startswith(OAUTH_PREFIX), source=source
    )


def from_env(env=None) -> Credential | None:
    """The credential to run live with, or None if there is no usable one.

    CLAUDE_CODE_OAUTH_TOKEN wins: it states its own shape, where
    ANTHROPIC_API_KEY has to be sniffed.
    """
    env = os.environ if env is None else env
    for name in (OAUTH_ENV, API_KEY_ENV):
        token = (env.get(name) or "").strip()
        if token:
            cred = classify(token, source=name)
            if name == OAUTH_ENV:
                # Whatever shape it is, this variable means Bearer.
                cred = Credential(token=token, is_oauth=True, source=name)
            return cred
    return None
