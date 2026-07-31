# Real-time meeting feedback app (v0)

A private co-pilot that runs during a meeting. A Swift transcriber (or the replay
tool) appends finalized turns to an append-only JSONL file; this Python app tails
it, cleans up structural-attribution artifacts, renders a live read-only stream,
and runs a two-stage gate/responder LLM pipeline that surfaces glanceable notes
only when something is actionable.

This is v0. See `../thoughts/grill-me-2026-07-22-meeting-feedback-screen.md` for
the 18 decisions that are the spec, and `../thoughts/architecture-v0.md` for the
build order. This app lives entirely under `feedback/` and does not touch the
top-level Swift project.

## The pipeline

```
replay/Swift --> transcript.jsonl --> tailer --> hygiene --> renderer
                  (the contract)         |            |         (read-only stream)
                                         +--> window --> GATE (model 1) --> RESPONDER (model 2)
                                              (10-turn      cheap, no tools,     tooled, precise,
                                               context)     forced JSON,         may stay silent
                                                            optimizes recall     optimizes precision
```

- **Contract = the file.** Replay and the Swift transcriber are interchangeable
  producers; the tailer can't tell them apart. Schema (one object per finalized
  turn): `{seq, start, end, speaker, text, final, conf}`.
- **Per-tick, not per-line.** `TurnMerger` flushes a whole watermark-eligible
  prefix at once, so lines arrive in bursts. Each poll returns an ordered batch;
  the window is updated with the whole batch and the gate is evaluated **once**
  per tick, with the newest batch as the explicit focus.

## Quick start

```sh
make setup                                   # venv + the 4 deps
make init                                    # creates ~/.config/bionic (config, resources.yaml)
make test                                    # offline suite, no API key needed

# Offline demo (two terminals, or background the first):
make run TRANSCRIPT=/tmp/live.jsonl          # terminal 1: tail + render
make replay FIXTURE=fixtures/wrong_fact.jsonl TRANSCRIPT=/tmp/live.jsonl MODE=turn
```

The offline path (replay -> tailer -> hygiene -> renderer) runs with **no API
key**. The LLM path is `make run-live` (needs `ANTHROPIC_API_KEY`).

`make init` is safe to re-run - it never overwrites a file that's already
there, so editing `resources.yaml` and re-running it later is a no-op.

## The hygiene layer (new in v0 - absent from architecture-v0)

Live mode does **structural** speaker attribution: mic device = "me",
system-audio device = "other". That moved all the uncertainty out of `conf`
(hardcoded `1.0` in the live producer - see `TurnWriter.swift`) and into
observable artifacts the consumer must filter. `conf` therefore carries **zero
information** in live mode and is never shown to the gate. The hygiene layer
replaces it with a synthetic signal that does carry information:

- **Sub-0.5s "me" turns** - VAD fires on keyboard clatter, ASR hallucinates
  "Hmm."/"Oops." -> flagged `short_me` + `attribution_suspect`.
- **Speaker bleed** - near-identical me/other text within a small delta-t = the
  same speech captured on both channels -> flagged `bleed_duplicate` +
  `attribution_suspect`.
- **Stream health** - no "other" turn in N minutes may mean system-audio capture
  died. From the JSONL alone this is indistinguishable from the far side being
  quiet, so it's surfaced as a **warning**, never guessed into a turn.

Policy: **flag, don't drop** (the LLM wants the user's own turns, to catch his
errors and rabbit-holing). Dropping is a config toggle, default off. The
synthetic `attribution_suspect` flag is what reaches the gate.

## Config (`~/.config/bionic/`)

Created by `make init` (or `python -m feedbackapp init`) from the templates in
`feedback/config/` - that directory is the bundled starting point, not the
live config; edits to it are never read at runtime.

- `instructions.md` (+ optional `instructions.local.md` per-meeting overlay) -
  plain markdown; the gate reads intent, so no DSL.
- `resources.yaml` - starter repo/doc examples (commented out) plus one active
  entry, `past-meetings`, pointing at `transcripts/`. The gate sees
  names+descriptions only (cheap, no tools); the responder gets paths to
  read/grep.
- `config.yaml` - model IDs, cooldown/window/caps, hygiene thresholds, and the
  per-type glanceability ceilings.
- `transcripts/` - where diarized meeting transcripts live, one JSONL file per
  meeting, named `YYYY-MM-DD-HH-MM-SS-<short-description>.jsonl`. Registered as
  a resource so the responder can look up what was discussed in a past meeting.

## Response types & glanceability

Five types (Decision 18): `answer`, `correction`, `enrichment`,
`abstraction-guard`, `concept-explainer`. The gate emits a `type`; the responder
formats per type. Glanceability is a hard constraint - per-type word/line
**ceilings are enforced in code** (`glanceability.py`) on the responder's output,
not just requested in the prompt. Over-ceiling -> suppressed. "Every single word
needs to be earned."

## What was verified BY RUNNING vs. wired

**Verified by running** (`make test`, 29 tests, and the CLI end-to-end):
- Tailer torn-line handling (partial write -> poll emits nothing -> completion ->
  emits intact), burst-as-one-batch, seq-gap detection, bad-line skip,
  rotation/truncation dedupe on seq, sidecar resume.
- Hygiene: short-me flag, bleed detection, stream-health warning + no-drop
  default.
- Replay fixtures validate as LIVE format (conf 1.0, me/other only, gapless seq).
- The full offline pipeline (replay -> tailer -> hygiene -> renderer) via the
  real `python -m feedbackapp run` CLI.
- Gate never sees `conf`; gate parses structured output via a stub; empty batch
  never calls the model.
- Responder plumbing conveys silence (stub returns `message=None`) and conveys a
  spoken message with its `addressed_claim` - i.e. the silent/speak paths are
  wired correctly. Whether the model *achieves* precision is a live-path question,
  not proven here.
- The glanceability ceiling suppresses an over-long message, asserted across all
  five response types.
- Orchestrator evaluates the gate **once per burst tick**; cooldown suppresses a
  second response.

**Wired, NOT verified** (no `ANTHROPIC_API_KEY` in this build):
- The live gate call (`AnthropicGateClient`, raw Anthropic API,
  `output_config.format`).
- The live responder (`responder_live.py`, `claude-agent-sdk`). The
  structured-output-alongside-tools ergonomics of `claude-agent-sdk` are outside
  the vendored `claude-api` reference and were not exercised. The interface uses
  a **terminal `emit_feedback` tool call** so it does not depend on forced-JSON-
  with-tools working - but the SDK wiring in `responder_live.py` is the one spot
  to verify against the installed SDK version before trusting the live path.

## Dependencies (exactly four, Decision 16)

`anthropic`, `claude-agent-sdk`, `pydantic`, `pyyaml`. No LangChain/LangGraph, no
vector DB, no web framework. The offline path only needs `pydantic` + `pyyaml`
(+ `pytest` for tests).
