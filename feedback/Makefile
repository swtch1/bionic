# Meeting feedback app (v0) - setup / run / test / replay.
# Scoped to feedback/; does not touch the top-level Swift project.

VENV := .venv
PY := $(VENV)/bin/python
PIP := $(VENV)/bin/pip
TRANSCRIPT ?= /tmp/feedback-live.jsonl
FIXTURE ?= fixtures/in_scope_repo_question.jsonl
MODE ?= turn
ARGS ?=

# Same tilde trap as the top-level Makefile: expand ~ ourselves so a quoted or
# make-internal use of the path can never see a literal tilde. `override` is
# needed because command-line variables outrank plain assignments.
override TRANSCRIPT := $(patsubst ~/%,$(HOME)/%,$(TRANSCRIPT))

.PHONY: setup test replay run run-live clean demo

setup:
	python3 -m venv $(VENV)
	$(PIP) install -q --upgrade pip
	$(PIP) install -q anthropic claude-agent-sdk pydantic pyyaml pytest

# Offline test suite - no API key required.
test:
	$(PY) -m pytest tests/ -q

# Append a fixture into the live transcript, mimicking the Swift producer.
#   make replay FIXTURE=fixtures/wrong_fact.jsonl MODE=burst
replay:
	$(PY) -m feedbackapp.replay "$(FIXTURE)" "$(TRANSCRIPT)" --mode $(MODE)

# Offline: tail + hygiene + read-only renderer. No API calls.
run:
	$(PY) -m feedbackapp run --transcript "$(TRANSCRIPT)" $(ARGS)

# LLM path (needs ANTHROPIC_API_KEY). Quiet by default: prints only feedback,
# warnings and errors. Add the transcript stream + per-tick trace with:
#   make run-live TRANSCRIPT=... ARGS=-v
run-live:
	$(PY) -m feedbackapp run --transcript "$(TRANSCRIPT)" --live $(ARGS)

# One-shot demo: fresh transcript, replay a fixture fast-forwarded, render it.
# Writes to its OWN scratch file, never $(TRANSCRIPT): that variable is
# documented as user-overridable and a user who had been running
# `make run-live TRANSCRIPT=~/meetings/standup.jsonl` would have had a real
# meeting transcript deleted, unprompted, by `make demo`.
DEMO_TRANSCRIPT := /tmp/feedback-demo.jsonl

demo:
	@rm -f $(DEMO_TRANSCRIPT)
	@$(PY) -m feedbackapp.replay $(FIXTURE) $(DEMO_TRANSCRIPT) --mode fast --truncate
	@$(PY) -m feedbackapp run --transcript $(DEMO_TRANSCRIPT) & \
	  sleep 2; kill %1 2>/dev/null || true

# Deliberately does NOT remove $(TRANSCRIPT) - see the note on demo.
clean:
	rm -rf $(VENV) .pytest_cache **/__pycache__ $(DEMO_TRANSCRIPT)
