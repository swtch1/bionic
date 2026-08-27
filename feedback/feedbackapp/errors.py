"""Failure policy for the API-backed halves of a tick.

Motivation, from a real 22-minute meeting: a rejected credential produced ~600
identical `error: tick failed: AuthenticationError` lines - one per 100ms tick -
scrolling the meeting screen and burying the stream-health warning that fired in
the middle of it. Two distinct problems, so two policies:

  * an auth failure is PERMANENT. Retrying it 600 times cannot succeed. Say once
    what to fix and turn the live path off for the session; capture, hygiene and
    the renderer keep running, because the recording is the thing the user
    cannot redo.
  * a transient failure (timeout, 429, 5xx) is worth retrying, but not at 10Hz
    and not one printed line per attempt. Back off, and collapse repeats of the
    same failure into one line with a count.
"""

from __future__ import annotations

AUTH_STATUS = (401, 403)
AUTH_CLASS_NAMES = ("AuthenticationError", "PermissionDeniedError")


def is_auth_failure(exc: BaseException) -> bool:
    """True for a credential rejection - the class of failure that retrying
    cannot fix. Checks the HTTP status first and the class name second, so it
    holds for the raw anthropic SDK, for the agent SDK's own wrappers, and for a
    stub in the tests that has neither."""
    if getattr(exc, "status_code", None) in AUTH_STATUS:
        return True
    if exc.__class__.__name__ in AUTH_CLASS_NAMES:
        return True
    return False


def signature(exc: BaseException) -> str:
    return f"{exc.__class__.__name__}: {exc}"


class ErrorThrottle:
    """Collapses a repeated identical failure into one line, then progressively
    rarer ones (1st, 2nd, 4th, 8th, ...) carrying the repeat count.

    Returns the line to print, or None to stay quiet. A change of failure always
    prints: the new failure is news even mid-storm.
    """

    def __init__(self) -> None:
        self._sig: str | None = None
        self._count = 0
        self._next = 1

    def report(self, exc: BaseException) -> str | None:
        sig = signature(exc)
        if sig != self._sig:
            self._sig, self._count, self._next = sig, 1, 2
            return sig
        self._count += 1
        if self._count < self._next:
            return None
        self._next *= 2
        return f"{sig} (x{self._count})"


class Backoff:
    """Monotonic-clock gate: `ready()` is False until the delay has elapsed.

    Doubles per consecutive failure from `base` to `cap`; any success resets it.
    Used to pause the GATE only - never the poll/render half of a tick, which
    must keep up with the meeting whatever the API is doing.
    """

    def __init__(self, base: float = 1.0, cap: float = 60.0) -> None:
        self._base, self._cap = base, cap
        self._delay = 0.0
        self._until = 0.0

    def ready(self, now: float) -> bool:
        return now >= self._until

    def fail(self, now: float) -> float:
        self._delay = min(self._cap, self._base if self._delay == 0 else self._delay * 2)
        self._until = now + self._delay
        return self._delay

    def succeed(self) -> None:
        self._delay = 0.0
        self._until = 0.0
