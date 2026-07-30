"""Real-time meeting feedback app (v0).

Two-process design: a Swift transcriber (or the replay tool) appends finalized
turns to an append-only JSONL file; this package tails that file, applies a
hygiene layer, renders a live stream, and runs a two-stage gate/responder LLM
pipeline over the rolling window.

The offline path (replay -> tailer -> hygiene -> renderer) runs with no API key.
"""

__all__ = ["__version__"]
__version__ = "0.0.0"
