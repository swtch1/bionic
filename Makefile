# bionic - see README.md
#
# Overridable variables:
#   AUDIO       audio file for `make transcribe`      (default: testdata/test_meeting.wav)
#   OUT         output JSONL path for transcribe, or an override for `listen`
#               (default: transcript.jsonl for transcribe; `listen` auto-names
#               into ~/.config/bionic/transcripts/ unless OUT is set)
#   TITLE       short description for `make listen`'s auto-named file (default: meeting)
#   VOICEPRINT  voiceprint JSON for batch attribution (default: none -> self-enrollment)
#   NAME        speaker name for `make enroll`        (default: me)
#   SAMPLE      solo audio sample for `make enroll`   (default: testdata/test_meeting.wav)
#   SESSION     session directory for record/diarize/review (default: ./session)
#   ARGS        extra flags passed through to the binary
#   PREFIX      install location for `make install`   (default: ~/.local)
#
# Example:
#   make listen TITLE="q3 planning"
#   make listen OUT=~/meetings/standup.jsonl
#   make record  SESSION=~/meetings/standup          # live capture + retain audio
#   make diarize SESSION=~/meetings/standup          # offline per-speaker attribution
#   make review  SESSION=~/meetings/standup          # name the speaker clusters
#   make transcribe AUDIO=~/recordings/call.wav VOICEPRINT=me.json

AUDIO      ?= testdata/test_meeting.wav
OUT        ?= transcript.jsonl
SAMPLE     ?= testdata/test_meeting.wav
NAME       ?= me
SESSION    ?= session
VOICEPRINT ?=
ARGS       ?=
# Default to a user-writable prefix: /usr/local/bin needs sudo on a stock
# macOS install, and `make install` has no business asking for it. Override
# with PREFIX=/usr/local (under sudo) for a system-wide install.
PREFIX     ?= $(HOME)/.local
TITLE      ?= meeting

# `listen` auto-names its output into ~/.config/bionic/transcripts (see
# Listen.swift's defaultTranscriptPath) when OUT isn't given - only pass --out
# through when the caller actually set it on the command line, so plain
# `make listen` gets the dated, discoverable filename instead of OUT's
# transcribe-oriented default of "transcript.jsonl".
ifeq ($(origin OUT),command line)
LISTEN_OUT_FLAG := --out "$(OUT)"
else
LISTEN_OUT_FLAG :=
endif

# `make record SESSION=~/meetings/standup` used to fail with "Could not open
# ~/meetings/standup/transcript.jsonl for writing": make does no tilde
# expansion, and the recipes quote these paths, so the shell can't expand a
# quoted "~" either - the binary got a literal tilde. Expand it here.
# `override` is required: a variable set on the command line beats a plain
# assignment in the makefile, so without it this rewrite would be discarded
# in exactly the case that needs it.
override SESSION := $(patsubst ~/%,$(HOME)/%,$(SESSION))
override OUT     := $(patsubst ~/%,$(HOME)/%,$(OUT))
override AUDIO   := $(patsubst ~/%,$(HOME)/%,$(AUDIO))
override SAMPLE  := $(patsubst ~/%,$(HOME)/%,$(SAMPLE))
override VOICEPRINT := $(patsubst ~/%,$(HOME)/%,$(VOICEPRINT))
override PREFIX  := $(patsubst ~/%,$(HOME)/%,$(PREFIX))

BIN     := bionic
RELEASE := .build/release/$(BIN)

ifeq ($(strip $(VOICEPRINT)),)
VOICEPRINT_FLAG :=
else
VOICEPRINT_FLAG := --voiceprint "$(VOICEPRINT)"
endif

.DEFAULT_GOAL := help

.PHONY: help check-deps build release run listen record meeting diarize review transcribe enroll test clean uninstall install init fixture quality quality-bless

help: ## Show this help
	@echo "bionic - live + offline meeting transcription to JSONL"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "See README.md for permissions setup (Microphone + Screen Recording)."

check-deps: ## Verify toolchain and OS version
	@command -v swift >/dev/null 2>&1 || { \
	  echo "error: swift toolchain not found. Install Xcode or the Command Line Tools:"; \
	  echo "       xcode-select --install"; exit 1; }
	@sw_vers -productVersion | awk -F. '{exit ($$1 < 15)}' || { \
	  echo "error: macOS 15+ required (found $$(sw_vers -productVersion))"; exit 1; }
	@echo "ok: swift $$(swift --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//'), macOS $$(sw_vers -productVersion)"

build: check-deps ## Debug build
	swift build

release: check-deps ## Optimized build (use this for real meetings)
	swift build -c release

listen: release ## Live-capture a meeting (Ctrl-C to stop). TITLE=... names it; OUT=... overrides the auto path
	$(RELEASE) listen $(LISTEN_OUT_FLAG) --title "$(TITLE)" $(ARGS)

record: release ## Live-capture AND retain raw audio to SESSION for later diarization (Ctrl-C to stop)
	@mkdir -p "$(SESSION)" || { echo "error: cannot create SESSION dir: $(SESSION)"; exit 1; }
	$(RELEASE) listen --out "$(SESSION)/transcript.jsonl" --record "$(SESSION)" $(ARGS)

# SESSION is passed through only when the caller set it, so the script's own
# dated default (<meetings_dir>/<date>-<slug>) survives a plain `make meeting`
# instead of being flattened onto SESSION's generic "session".
ifeq ($(origin SESSION),command line)
MEETING_SESSION_FLAG := --session "$(SESSION)"
else
MEETING_SESSION_FLAG :=
endif

meeting: release ## Everything at once: record + retain audio + live feedback, then diarize on Ctrl-C
	scripts/meeting.sh --title "$(TITLE)" $(MEETING_SESSION_FLAG) $(ARGS)

diarize: release ## Offline per-speaker attribution over a recorded SESSION (writes transcript.diarized.jsonl)
	$(RELEASE) diarize "$(SESSION)" $(ARGS)

review: release ## Name the speaker clusters in a diarized SESSION (interactive; --play to hear samples)
	$(RELEASE) review "$(SESSION)" $(ARGS)

transcribe: release ## Batch-transcribe an existing recording (AUDIO=...)
	@test -f "$(AUDIO)" || { echo "error: audio file not found: $(AUDIO) (set AUDIO=path/to/file)"; exit 1; }
	$(RELEASE) "$(AUDIO)" --out "$(OUT)" $(VOICEPRINT_FLAG) $(ARGS)

enroll: release ## Build a "me" voiceprint from a clean solo sample (SAMPLE=... NAME=...)
	@test -f "$(SAMPLE)" || { echo "error: sample not found: $(SAMPLE) (set SAMPLE=path/to/file)"; exit 1; }
	$(RELEASE) enroll "$(SAMPLE)" --name "$(NAME)" --out "$(NAME).json" $(ARGS)

test: build ## Run the automated self-tests
	swift run $(BIN) --selftest-merge
	swift run $(BIN) --selftest-pipeline
	swift run $(BIN) --selftest-reconcile
	swift run $(BIN) --selftest-binding
	swift run $(BIN) --selftest-loadturns
	swift run $(BIN) --selftest-review
	swift run $(BIN) --selftest-record
	swift run $(BIN) --selftest-record-crash
	swift run $(BIN) --selftest-session
	swift run $(BIN) --selftest-vadthrow
	swift run $(BIN) --selftest-transcriptname
	swift run $(BIN) --selftest-tapexception
	swift run $(BIN) --selftest-qualitymetrics
	swift run $(BIN) --selftest-permissions
	swift run $(BIN) --selftest-voiceprintstore
	swift run $(BIN) --selftest-stophang

fixture: build ## (Re)generate the synthesized accuracy fixture + its ground truth
	swift run $(BIN) make-fixture

quality: build ## Score diarization accuracy (DER) against the committed baseline
	@test -f testdata/quality/quality-baseline.json || { \
	  echo "error: no baseline yet. Run 'make fixture' then 'make quality-bless'"; exit 1; }
	swift run $(BIN) quality

quality-bless: build ## Record current accuracy AS the baseline (review the diff before committing)
	swift run $(BIN) quality --bless

install: release ## Install the binary (PREFIX=~/.local by default; PREFIX=/usr/local for system-wide)
	@install -d "$(PREFIX)/bin" 2>/dev/null || { \
	  echo "error: cannot create $(PREFIX)/bin (permission denied)."; \
	  echo "       Install somewhere you own:  make install PREFIX=$(HOME)/.local"; \
	  echo "       Or system-wide:             sudo make install PREFIX=/usr/local"; exit 1; }
	@install -m 0755 "$(RELEASE)" "$(PREFIX)/bin/$(BIN)" 2>/dev/null || { \
	  echo "error: cannot write $(PREFIX)/bin/$(BIN) (permission denied)."; \
	  echo "       Install somewhere you own:  make install PREFIX=$(HOME)/.local"; \
	  echo "       Or system-wide:             sudo make install PREFIX=/usr/local"; exit 1; }
	@echo "installed $(PREFIX)/bin/$(BIN)"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) \
	  echo "note: $(PREFIX)/bin is not on your PATH. Add to ~/.zshrc:"; \
	  echo "      export PATH=\"$(PREFIX)/bin:$$PATH\"" ;; esac
	@echo "run 'make init' to set up ~/.config/bionic before your first meeting"

init: ## One-time setup: create ~/.config/bionic (config + transcripts dir)
	@cd feedback && $(MAKE) init

uninstall: ## Remove the installed binary
	rm -f "$(PREFIX)/bin/$(BIN)"

clean: ## Remove build artifacts
	rm -rf .build
