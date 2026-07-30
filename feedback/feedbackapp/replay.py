"""Replay tool (Decision 11) - build FIRST.

Reads a fixture JSONL and appends its lines to a live transcript file so the
feedback app cannot tell replay from the real Swift producer. It writes bytes
the same way the Swift TurnWriter does: one JSON object per line, newline
terminated, flushed promptly.

Timing modes:
  - "turn"  : sleep the real inter-turn gap between successive `start` values
              (clamped), so arrival timing mimics a live meeting.
  - "fast"  : fixed small delay between lines.
  - "burst" : append a contiguous run with ~0 delay so several lines land in a
              single tailer poll tick (this is what makes the burst FIXTURE
              actually exercise batch logic - see the burst fixture + test).

The replay tool does NOT rewrite seq or reshape lines; a fixture is emitted
verbatim. Fixtures are authored in LIVE format (conf 1.0, speaker me/other,
never "unknown"). We validate that here so an accidental batch-mode artifact
fails loudly rather than silently corrupting a test.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Iterator

from .models import Turn


def read_fixture(path: Path) -> list[dict]:
    """Load a fixture JSONL into a list of raw dicts, validating LIVE-format rules."""
    lines: list[dict] = []
    for i, raw in enumerate(path.read_text().splitlines(), start=1):
        raw = raw.strip()
        if not raw:
            continue
        obj = json.loads(raw)
        turn = Turn.model_validate(obj)  # schema check
        if turn.speaker not in ("me", "other"):
            raise ValueError(
                f"{path}:{i}: speaker={turn.speaker!r}. Fixtures are LIVE format: "
                "only me/other, never 'unknown' (that is a batch-mode artifact)."
            )
        if turn.conf != 1.0:
            raise ValueError(
                f"{path}:{i}: conf={turn.conf}. Live mode hardcodes conf=1.0; a "
                "varied conf is a batch-mode artifact and an invalid fixture."
            )
        lines.append(obj)
    return lines


def _delays(objs: list[dict], mode: str, fast_delay: float, burst_gap: float) -> Iterator[float]:
    """Yield the pre-append sleep for each line (first line always 0)."""
    prev_start = None
    for obj in objs:
        if prev_start is None:
            yield 0.0
        elif mode == "burst":
            yield burst_gap
        elif mode == "fast":
            yield fast_delay
        else:  # "turn"
            gap = max(0.0, float(obj["start"]) - prev_start)
            yield min(gap, 10.0)  # clamp long silences so tests don't hang
        prev_start = float(obj["start"])


def replay(
    fixture: Path,
    target: Path,
    mode: str = "fast",
    fast_delay: float = 0.3,
    burst_gap: float = 0.0,
    sleep=time.sleep,
) -> int:
    """Append fixture lines to `target`. Returns the number of lines written."""
    objs = read_fixture(fixture)
    target.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    # Open in append+binary and flush per line so a polling tailer sees each promptly.
    with open(target, "ab", buffering=0) as fh:
        for delay, obj in zip(_delays(objs, mode, fast_delay, burst_gap), objs):
            if delay:
                sleep(delay)
            fh.write((json.dumps(obj) + "\n").encode("utf-8"))
            written += 1
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Replay a fixture JSONL into a live transcript file.")
    ap.add_argument("fixture", type=Path)
    ap.add_argument("target", type=Path)
    ap.add_argument("--mode", choices=["turn", "fast", "burst"], default="fast")
    ap.add_argument("--fast-delay", type=float, default=0.3)
    ap.add_argument("--burst-gap", type=float, default=0.0)
    ap.add_argument("--truncate", action="store_true", help="Clear target before replay.")
    args = ap.parse_args(argv)
    if args.truncate and args.target.exists():
        args.target.write_text("")
    n = replay(args.fixture, args.target, args.mode, args.fast_delay, args.burst_gap)
    print(f"replayed {n} lines -> {args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
