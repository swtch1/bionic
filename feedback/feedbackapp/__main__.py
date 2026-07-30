"""CLI entry point. Wires the pipeline and runs the async loop.

Offline path (no API key needed):
    python -m feedbackapp run --transcript /tmp/live.jsonl

Add the LLM path with --live (requires ANTHROPIC_API_KEY). Live mode is QUIET:
it prints only responder feedback, stream-health warnings and errors. Pass
--verbose to also stream the transcript and the per-tick trace.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import signal
import sys
from pathlib import Path

from .config import ConfigError, load_config
from .gate import AnthropicGateClient, Gate
from .hygiene import Hygiene
from .orchestrator import Orchestrator
from .renderer import Renderer
from .responder import Responder
from .tailer import Tailer


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="feedbackapp")
    ap.add_argument("command", choices=["run"], help="run the feedback app")
    ap.add_argument("--transcript", type=Path, required=True, help="live JSONL to tail")
    ap.add_argument("--sidecar", type=Path, default=None, help="tailer resume sidecar")
    ap.add_argument("--live", action="store_true", help="enable gate+responder (needs ANTHROPIC_API_KEY)")
    ap.add_argument("--no-flags", action="store_true", help="hide hygiene flags in the stream")
    ap.add_argument(
        "-v", "--verbose", action="store_true",
        help="print the live transcript and per-tick trace (live mode is quiet by default)",
    )
    args = ap.parse_args(argv)

    try:
        config = load_config()
    except ConfigError as e:
        # A user editing resources.yaml to point at their real repos used to get
        # a bare pydantic/KeyError traceback with no hint which file was wrong.
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    tailer = Tailer(args.transcript, sidecar=args.sidecar)
    hygiene = Hygiene(config.hygiene)
    # Quiet during a real call: the user knows what was just said, so echoing
    # the transcript back only buries the one line that matters. Offline replay
    # keeps the stream - watching it IS the point of that mode.
    verbose = args.verbose or not args.live
    renderer = Renderer(show_flags=not args.no_flags, verbose=verbose)

    gate = responder = None
    if args.live:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("ERROR: --live needs ANTHROPIC_API_KEY. Running offline instead is: drop --live.", file=sys.stderr)
            return 2
        # The responder shells out to the `claude` CLI via claude-agent-sdk, and
        # `make setup` installs only the pip packages. Without this check the app
        # started, printed the banner, and then produced a one-line
        # CLINotFoundError per candidate - in quiet mode, the only clue at all.
        if shutil.which("claude") is None:
            print(
                "ERROR: --live needs the `claude` CLI on PATH (the responder runs "
                "through it).\n       Install it with: npm install -g @anthropic-ai/claude-code",
                file=sys.stderr,
            )
            return 2
        gate = Gate(AnthropicGateClient(), config.gate_model)
        from .responder_live import ClaudeAgentResponderClient

        responder = Responder(
            # File tools are confined to these roots - see responder_live's
            # can_use_tool. Meeting speech is attacker-controlled input.
            ClaudeAgentResponderClient(allowed_roots=[r.path for r in config.resources]),
            config.responder_model, config.resources, config.glanceability,
        )
        missing = [r.path for r in config.resources if not Path(r.path).expanduser().exists()]
        if missing:
            # Silence here is why the responder used to fabricate sourcing
            # ("per repo metadata") - it had nothing to read and said so anyway.
            renderer.notice(
                f"warning: {len(missing)} configured resource path(s) do not exist "
                f"({', '.join(missing[:3])}) - the responder cannot verify against them. "
                "Edit config/resources.yaml."
            )
        renderer.notice(
            "live mode: gate=on, responder=on"
            + ("" if verbose else " - quiet (only feedback is printed; -v for the transcript)")
        )
    else:
        renderer.notice("offline mode: replay -> tailer -> hygiene -> renderer (no API calls)")

    # A missing transcript is legitimate (the producer may start later), but it
    # is also exactly what a typo'd --transcript looks like: in quiet live mode
    # both render as a banner followed by permanent silence. Say which one we
    # are in, once, up front.
    if not args.transcript.exists():
        renderer.notice(
            f"waiting for {args.transcript} to appear (nothing will print until the "
            "transcriber writes to it - check the path if this never changes)"
        )

    orch = Orchestrator(
        config=config, tailer=tailer, hygiene=hygiene, renderer=renderer, gate=gate, responder=responder
    )
    # Ctrl-C must set the stop flag IMMEDIATELY, in the signal handler - not in
    # an `except KeyboardInterrupt` around asyncio.run(). Verified: asyncio.run's
    # teardown blocks in shutdown_default_executor() waiting for the responder's
    # worker thread, so the except-clause version ran ~0.4s TOO LATE. The worker
    # therefore saw _stop=False, and the last line on screen was an alarming
    # "error: responder failed: ResponderSilent" caused by our own Ctrl-C. It
    # also meant `while not self._stop` never exited, so run()'s in-flight drain
    # and tailer.close() were unreachable in the real CLI.
    def _on_sigint(signum, frame):
        orch.stop()

    signal.signal(signal.SIGINT, _on_sigint)
    try:
        asyncio.run(orch.run())
    except KeyboardInterrupt:  # a second Ctrl-C, or one racing handler install
        orch.stop()
    finally:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        tailer.close()  # idempotent; run() closes on the graceful path
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
