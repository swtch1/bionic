#!/bin/bash
# One meeting, end to end: live capture with retained audio, the feedback app
# rendering in this terminal, diarization on Ctrl-C.
#
# Capture's stdout goes to the session log, not the screen: the feedback
# renderer needs sole ownership of the TTY or the two interleave.
set -uo pipefail

# Job control puts each child in its own process group with default signal
# dispositions. Without it, Ctrl-C reaches the children directly - racing this
# script's cleanup against capture's WAV flush - and a backgrounded child of a
# non-interactive shell inherits SIGINT as ignored, so a shell-based child never
# stops at all. With it, the stop path is this script's alone. Switched back off
# once the children are up, so bash's job notices stay off the meeting screen.
set -m

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIONIC="${BIONIC:-$repo/.build/release/bionic}"
venv_py="$repo/feedback/.venv/bin/python"

usage() {
    cat <<'USAGE'
usage: scripts/meeting.sh [--title <desc>] [--session <dir>] [--no-live] [--no-diarize]

  --title       names the session and its directory (default: "meeting")
  --session     session directory (default: <meetings-root>/<date>-<slug>)
  --no-live     record only; skip the feedback app
  --no-diarize  skip per-speaker attribution on exit
USAGE
}

title="meeting"
session=""
claim=""
live=1
diarize=1

while [ $# -gt 0 ]; do
    case "$1" in
        --title)      title="${2:-}"; shift 2 ;;
        --session)    session="${2:-}"; shift 2 ;;
        --no-live)    live=0; shift ;;
        --no-diarize) diarize=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$title" ] || title="meeting"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$slug" ] || slug="meeting"

# Where meetings live is per-machine, so it stays out of the repo: env first, then
# a top-level `meetings_dir:` in the same config.yaml the feedback app reads (its
# loader pulls named keys, so an extra one is inert there).
config_meetings_dir() {
    conf="${BIONIC_CONFIG_DIR:-$HOME/.config/bionic}/config.yaml"
    [ -f "$conf" ] || return 0
    sed -n 's/^meetings_dir:[[:space:]]*\(.*\)$/\1/p' "$conf" | head -1 | sed \
        -e 's/[[:space:]]*#.*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
        -e 's/[[:space:]]*$//'
}

if [ -z "$session" ]; then
    root="${BIONIC_MEETINGS_DIR:-$(config_meetings_dir)}"
    [ -n "$root" ] || root="$HOME/meetings"
    case "$root" in "~/"*) root="$HOME/${root#\~/}" ;; esac
    # A date-only name is the point (it sorts and reads), so same-day repeats get a
    # counter rather than a timestamp.
    #
    # Two tests, because they reject different things. A transcript means a finished
    # meeting owns the name. A claim dir means a LIVE run owns it - `mkdir` is atomic,
    # so exactly one of several simultaneous starts wins it. Without the claim, runs
    # started before either had written a transcript all read "empty dir, reusable"
    # and interleaved their WAVs into one directory.
    mkdir -p "$root" || exit 1
    base="$root/$(date +%Y-%m-%d)-$slug"
    session="$base"
    n=2
    while :; do
        mkdir -p "$session" 2>/dev/null || { echo "error: cannot create $session" >&2; exit 1; }
        if mkdir "$session/.bionic-claim" 2>/dev/null; then
            # An existing dir holding only notes is meant to be recorded into.
            [ -e "$session/transcript.jsonl" ] || { claim="$session/.bionic-claim"; break; }
            rmdir "$session/.bionic-claim"
        fi
        session="$base-$n"
        n=$((n + 1))
    done
fi
# Neither make nor a quoted shell word expands a leading tilde; the binary would
# get it literally and create ./~/meetings.
case "$session" in "~/"*) session="$HOME/${session#\~/}" ;; esac

transcript="$session/transcript.jsonl"
listen_log="$session/listen.log"

if [ ! -x "$BIONIC" ]; then
    echo "error: $BIONIC not found - run 'make release' first" >&2
    exit 1
fi
if [ -e "$transcript" ]; then
    echo "error: $transcript already exists; capture refuses to overwrite it" >&2
    echo "       pass --session <fresh dir> to start a new session" >&2
    exit 2
fi

mkdir -p "$session" || exit 1   # a caller-supplied --session may not exist yet
chmod 700 "$session"

# Release the name whether we stop cleanly, get signalled, or bail on an error.
release_claim() { [ -n "$claim" ] && rmdir "$claim" 2>/dev/null; }
trap release_claim EXIT

"$BIONIC" listen --record "$session" --out "$transcript" --title "$title" >"$listen_log" 2>&1 &
listen_pid=$!

fb_pid=""
stop_capture() { kill -INT "$listen_pid" 2>/dev/null; }
trap stop_capture INT TERM

# The permission preflight fails in well under a second. Catching that here is
# what stops the feedback app tailing a file nothing will ever write to.
for _ in 1 2 3 4 5 6; do
    kill -0 "$listen_pid" 2>/dev/null || break
    sleep 0.5
done
if ! kill -0 "$listen_pid" 2>/dev/null; then
    wait "$listen_pid"; rc=$?
    cat "$listen_log" >&2
    echo "error: capture exited immediately (status $rc) - not starting the feedback app" >&2
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
fi

if [ "$live" = 1 ]; then
    if [ ! -x "$venv_py" ]; then
        echo "note: feedback app not set up - run 'make -C feedback setup'. Recording only."
    else
        fb_args=(run --transcript "$transcript")
        if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
            fb_args+=(--live)
        else
            echo "note: no credential (CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY) - feedback renders the stream but the gate/responder stay off."
        fi
        ( cd "$repo/feedback" && exec "$venv_py" -m feedbackapp "${fb_args[@]}" ) &
        fb_pid=$!
    fi
fi

echo "session:    $session"
echo "transcript: $transcript"
echo "Ctrl-C to stop$([ "$diarize" = 1 ] && echo " (diarization runs on exit)")"
echo

set +m

# `wait` returns as soon as the trap fires, which is well before capture has
# flushed its WAVs and written the manifest. Poll for actual exit - diarization
# reads both.
wait "$listen_pid" 2>/dev/null
while kill -0 "$listen_pid" 2>/dev/null; do sleep 0.2; done

if [ -n "$fb_pid" ] && kill -0 "$fb_pid" 2>/dev/null; then
    kill -INT "$fb_pid" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$fb_pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$fb_pid" 2>/dev/null; then
        kill -TERM "$fb_pid" 2>/dev/null
        for _ in $(seq 1 8); do
            kill -0 "$fb_pid" 2>/dev/null || break
            sleep 0.25
        done
        # It renders; it holds no data worth a longer wait. Orphaning it onto the
        # next meeting's terminal is the worse outcome.
        kill -0 "$fb_pid" 2>/dev/null && kill -KILL "$fb_pid" 2>/dev/null
    fi
fi

echo
echo "capture stopped: $session"

if [ "$diarize" != 1 ]; then
    exit 0
fi

# Diarization reconciles the retained WAVs against the transcript, so a torn
# session produces garbage clusters rather than an error. Gate on the manifest.
if ! python3 - "$session/manifest.json" <<'PY'
import json, sys
try:
    manifest = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if manifest.get("incomplete") is False else 1)
PY
then
    echo "warning: $session/manifest.json is missing or marks the session incomplete." >&2
    echo "         Skipping diarization - the transcript and audio are still there." >&2
    exit 1
fi

echo "diarizing..."
"$BIONIC" diarize "$session" || exit $?
echo
echo "next: $BIONIC review \"$session\"   # put real names on the clusters"
