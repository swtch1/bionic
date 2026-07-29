# meetingscribe - see README.md
#
# Overridable variables:
#   AUDIO       audio file for `make transcribe`      (default: testdata/test_meeting.wav)
#   OUT         output JSONL path                     (default: transcript.jsonl)
#   VOICEPRINT  voiceprint JSON for batch attribution (default: none -> self-enrollment)
#   NAME        speaker name for `make enroll`        (default: me)
#   SAMPLE      solo audio sample for `make enroll`   (default: testdata/test_meeting.wav)
#   SESSION     session directory for record/diarize/review (default: ./session)
#   ARGS        extra flags passed through to the binary
#
# Example:
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
PREFIX     ?= /usr/local

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

BIN     := meetingscribe
RELEASE := .build/release/$(BIN)

ifeq ($(strip $(VOICEPRINT)),)
VOICEPRINT_FLAG :=
else
VOICEPRINT_FLAG := --voiceprint "$(VOICEPRINT)"
endif

.DEFAULT_GOAL := help

.PHONY: help check-deps build release run listen record diarize review transcribe enroll test clean uninstall install

help: ## Show this help
	@echo "meetingscribe - live + offline meeting transcription to JSONL"
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

listen: release ## Live-capture a meeting in progress (Ctrl-C to stop)
	$(RELEASE) listen --out "$(OUT)" $(ARGS)

record: release ## Live-capture AND retain raw audio to SESSION for later diarization (Ctrl-C to stop)
	@mkdir -p "$(SESSION)" || { echo "error: cannot create SESSION dir: $(SESSION)"; exit 1; }
	$(RELEASE) listen --out "$(SESSION)/transcript.jsonl" --record "$(SESSION)" $(ARGS)

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

install: release ## Install the binary (PREFIX=/usr/local by default)
	install -d "$(PREFIX)/bin"
	install -m 0755 "$(RELEASE)" "$(PREFIX)/bin/$(BIN)"
	@echo "installed $(PREFIX)/bin/$(BIN)"

uninstall: ## Remove the installed binary
	rm -f "$(PREFIX)/bin/$(BIN)"

clean: ## Remove build artifacts
	rm -rf .build
