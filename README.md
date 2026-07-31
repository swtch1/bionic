# bionic

Transcribes meetings on macOS into an append-only JSONL stream of speaker-attributed
turns. Runs fully on-device - audio never leaves the machine.

Modes:

| Mode | Command | Speaker attribution | When |
|---|---|---|---|
| **Live** | `bionic listen` | Structural - mic is `me`, system audio is `other` | During a call |
| **Batch** | `bionic <audio.wav>` | Voiceprint - cosine distance to an enrolled embedding | On a recording |
| **Diarize** | `bionic diarize <session-dir>` | Offline - splits `other` into `other:1..N` speaker clusters | After a `listen --record` session |
| **Review** | `bionic review <session-dir>` | Human - put real names on the clusters | After `diarize` |

Live mode collapses every remote participant to `other`. To recover per-person identity you
opt into audio retention during the call (`listen --record <dir>`), then run `diarize` (offline
clustering) and `review` (naming) afterward. See [Retained audio](#retained-audio).

## Requirements

- macOS 15 or later (Apple Silicon recommended - ASR runs on the Neural Engine)
- Xcode or the Command Line Tools (`xcode-select --install`)

Models (VAD, Parakeet ASR, diarizer) download automatically on first run and are
cached afterward. The first run is therefore slow and needs network; later runs don't.

## Quick start

```sh
make release          # build
make listen           # start capturing a call; Ctrl-C to stop
```

`make help` lists every target.

The first `make listen` will trigger two macOS permission prompts. **Grant both** - see
[Permissions](#permissions) if you don't get prompted.

## Permissions

Live capture needs two TCC grants, and they attach to **the app that launches the binary**
(Terminal, iTerm, VS Code...), not to the binary itself. That means the grants survive
rebuilds, but switching terminal apps means granting again.

| Permission | System Settings path | Used for |
|---|---|---|
| Microphone | Privacy & Security -> Microphone | the `me` stream |
| Screen Recording | Privacy & Security -> Screen & System Audio Recording | the `other` stream |

Screen Recording is required because we capture system audio via ScreenCaptureKit. No video
is ever recorded: the stream is pinned to a 2x2 surface at 1 fps and no video output handler
is registered.

This permission is an artifact of that implementation choice, not a macOS requirement.
CoreAudio's process-tap API (`CATapDescription`, macOS 14.2+) captures per-application audio
under Audio Capture consent alone, with no Screen Recording grant. Moving to it would drop
this permission entirely and let us tap a specific meeting app instead of the whole output
mix. Not yet done - tracked as a known improvement.

If Screen Recording is missing, `listen` now fails immediately with instructions rather than
hanging at "Starting system-audio capture" (`CGPreflightScreenCaptureAccess` is checked before
ScreenCaptureKit is touched, since `SCShareableContent.current` blocks instead of erroring when
the grant is absent). Grant it, then fully quit and reopen the terminal app - the grant is read
at launch.

## Usage

### Live capture

```sh
bionic listen [--out transcript.jsonl] [--append]
```

Press Ctrl-C once to stop and flush cleanly. A second Ctrl-C force-exits (useful if
startup itself is wedged on a missing permission).

### Retained audio

Live mode retains **no** audio by default - nothing is written to disk except the JSONL transcript.
Per-person speaker naming needs the raw audio afterward, so it is **opt-in** via `--record`:

```sh
bionic listen --out session/transcript.jsonl --record session/
# or: make record SESSION=session
```

This writes, into the session directory:

| File | Contents |
|---|---|
| `me.wav` | your microphone, 16kHz mono Int16 WAV |
| `other.wav` | remote participants (system audio), same format |
| `manifest.json` | per-stream epoch anchor, sample counts, and desync/truncation flags |

**This is private meeting audio.** The tool makes that explicit and hard to do by accident:

- **Opt-in only.** No audio is ever retained unless you pass `--record`. A boxed warning naming the
  absolute directory prints at startup, and the path plus byte sizes print at exit.
- **Restricted permissions.** The session directory is created `0700` and every file `0600` (owner
  only). If you point `--record` at an existing directory it is tightened to `0700`.
- **Size.** ~1.9 MB per minute per stream (16000 samples/s x 2 bytes x 60), so roughly **230 MB/hour**
  for both streams together. Plan disk accordingly for long meetings.
- **Deletion.** Delete the whole session directory when you no longer need it (`rm -rf session/`).
  Nothing else references it; the live transcript is independent.

A write failure mid-meeting never stops capture: the affected stream is marked `truncated` in the
manifest, a one-line notice goes to stderr, and transcription continues.

**Crash-safe recording.** The WAV header (which tells readers how many samples the file holds) is
rewritten on disk every ~1s as audio is flushed, and `fsync`'d - so an abnormal exit (SIGKILL, a
segfault, power loss, or a second Ctrl-C force-quit) costs at most the last ~1s, never the whole
recording. `SIGTERM` (`kill <pid>`) and Ctrl-C both flush cleanly and write the full manifest. As
soon as the first audio arrives a partial `manifest.json` is written carrying the epoch anchor, so
even a session that never shuts down cleanly stays reconcilable by `diarize` (which warns that the
manifest is incomplete). If you have a recording whose header under-reports its length - one made by
an older build, or killed in the sub-second window between a flush and its header patch - repair it:

```sh
bionic repair-wav <file.wav>   # rewrites the RIFF/data size fields from the actual byte length
```

`diarize` detects this case itself: if `other.wav` holds more audio than its header admits, it stops
and points you at `repair-wav` rather than silently diarizing the truncated view.

### Offline speaker attribution

Once you have a recorded session:

```sh
bionic diarize <session-dir> [--voiceprints <dir>] [--speakers N | --max-speakers N] \
                                    [--purity 0.6] [--coverage 0.5] [--force]
bionic review  <session-dir> [--play] [--enroll <dir>] [--force]
```

If you know the headcount, tell it: `--speakers N` pins the exact number of speakers and
`--max-speakers N` caps it (the two are mutually exclusive). Known headcount is the single
highest-leverage accuracy lever - "there are 3 people on this call" constrains the clustering
directly, so use it whenever you have it.

`diarize` runs an offline diarizer over `other.wav`, splits the remote side into `other:1..N`
speaker clusters (numbered by total speaking time), and writes a **new** file
`transcript.diarized.jsonl` with the same `seq` values 1:1. The live JSONL is never modified. A turn
that spans two speakers is emitted whole with the majority cluster's label, an honest lowered
`conf`, and a `speakers` array disclosing the split - it is never cut in half. `diarize` refuses to
run on a stream that recorded VAD desyncs (timeline drift) without `--force`, and refuses to
overwrite an existing diarized file without `--force`. Unparseable transcript lines are never
silently dropped: `diarize` warns with the count and the first offending line number, and if more
than 5% of the transcript fails to parse it refuses outright (something upstream is broken) unless
`--force` is given, in which case it proceeds with only the lines that parsed.

**Auto-labeling with `--voiceprints <dir>`.** Point it at a directory of enrolled Speaker JSONs
(what `enroll` and `review --enroll` write) and `diarize` names clusters for you - the payoff of the
whole feature: name someone once and they resolve automatically in every later meeting, no
interactive review needed. For each cluster it takes the cosine distance from the cluster centroid
to every voiceprint and:

- binds the cluster to the **nearest named voiceprint** if that distance is below the `me`-confidence
  threshold (`0.45`) *and* beats the runner-up voiceprint by a clear fixed margin (`0.10`); an
  ambiguous near-tie stays `other:N` rather than guess a name. Auto-bound turns carry
  `"boundBy":"voiceprint"`. Voiceprints named with a reserved word (`me`, `other`, `unknown`) are not
  used as bind targets - they collide with diarize's own labels - and a warning names any that were
  supplied; `me` is the exception, used only for bleed detection below.
- flags **bleed** separately: a cluster within the `me`-confidence threshold of the enrolled `me`
  voiceprint is your own voice leaking into system audio; it is labeled `me?` with `"bleed":true` and
  is **never** rewritten to a hard `me` (the structural mic-stream claim owns `me`). Bleed wins over
  any name bind. `me` is matched by voiceprint name (case-insensitive), i.e. one enrolled with
  `enroll --name me`.

A voiceprint whose embedding dimension doesn't match the diarizer's (a different model version)
would silently match nothing; `diarize` prints a loud warning naming the offenders instead.

`review` walks each still-unnamed cluster - showing its speaking time, turn count, and longest turns
(`--play` slices the longest one out of `other.wav` and plays it through `afplay`) - and prompts for a
name (Enter keeps the anonymous label). It rewrites `transcript.diarized.jsonl` in place, saves the
name map to `speakers.json`, and is safely re-runnable (already-named clusters are skipped). With
`--enroll <dir>` it persists each newly-named cluster's voiceprint so the same person auto-binds
(via `diarize --voiceprints <dir>`) in future meetings.

Because `review` rewrites the file in place, it is strict about integrity: if the diarized file has
**any** unparseable line it refuses (naming the line number, leaving your file untouched) rather than
silently rewriting a truncated transcript - this is `diarize`'s own output, so a bad line means
something is wrong. `--force` overrides, keeping only the parsed lines. The rewrite itself is atomic
(temp file + rename), so a crash or full disk mid-write can never leave a half-written transcript.

### Batch transcription

```sh
bionic <audio.wav> [--voiceprint me.json] [--out transcript.jsonl] [--append]
```

Without `--voiceprint`, the tool falls back to **circular self-enrollment**: it assumes
the longest-speaking voice in the recording is you. That exercises the pipeline but
tells you nothing about real accuracy, and it prints a loud warning saying so. Enroll a
real voiceprint for anything you care about.

### Enrollment

```sh
bionic enroll <clean_solo_sample.wav> --name me --out me.json
```

Use 30+ seconds of only your voice, recorded on the hardware you actually use. The
voiceprint must come from the same embedding model version as the diarizer that will
consume it; a dimension mismatch labels *every* turn `unknown`, and the tool warns
loudly if it detects one.

## Output format

One JSON object per line, appended as each turn finalizes - safe to `tail -f` while a
meeting is running. Consumers should parse by key name; key order is not stable.

```json
{"seq":0,"start":1785195419.3,"end":1785195421.29,"speaker":"me","text":"Yeah, I'm joining.","final":true,"conf":1}
```

| Field | Type | Meaning |
|---|---|---|
| `seq` | int | Monotonic per output file, gapless, starts at 0 |
| `start` / `end` | float | Unix epoch seconds, 2dp; `start < end` always |
| `speaker` | string | `me` \| `other` \| `unknown` in a live/batch transcript. After `diarize`/`review` a turn may also carry `other:1`..`other:N` (an anonymous speaker cluster), a real name (`Alice`), or `me?` (a cluster that matched your enrolled voiceprint - likely your own voice bleeding into system audio; not rewritten to a hard `me`). |
| `text` | string | Transcribed text, trimmed, never empty |
| `final` | bool | Always `true` - no partial hypotheses are emitted |
| `conf` | float | Confidence **in the speaker label**, not in the text |

After `diarize`/`review`, a turn may also carry these optional fields (a diarized line is a strict
superset of the live schema; consumers that ignore unknown keys are unaffected):

| Field | Type | Meaning |
|---|---|---|
| `speakers` | array | Runner-up cluster shares for a contested turn (`[{"speaker":..,"share":..}]`), disclosed when a runner-up holds >= 15% |
| `bleed` | bool | `true` when the assigned cluster matched the enrolled `me` voiceprint (labeled `me?`, not `me`) |
| `reason` | string | Why a turn stayed `other`: `no_diar_overlap` \| `low_purity` \| `low_coverage` |
| `boundBy` | string | How the speaker name was chosen: `voiceprint` (auto-bound by `diarize --voiceprints`) \| `manual` (named by a human in `review`). Absent on anonymous `other:N` clusters and on `me`/`other`/`unknown` passthroughs - so a wrong auto-bind is diagnosable rather than indistinguishable from a human decision |

In live mode two independent capture streams race, so a reorder buffer holds each turn
briefly (1.5s) and writes the buffered turns in `start` order. This is best-effort, not a
guarantee: a turn that finalizes more than the buffer window after later-starting turns
have already been written lands out of order. In practice that needs ASR latency skew
beyond 1.5s between the two streams. `seq` is always gapless and ascending regardless.

`conf` is always `1.0` in live mode. That is not a placeholder - the label is structural
(which capture device the audio arrived on), so there is no inference to be uncertain
about. Batch mode derives `conf` from the cosine distance to the voiceprint, and returns
`unknown` with a low `conf` inside the ambiguous band between the two thresholds.

Existing output files are never overwritten: without `--append`, a non-empty `--out`
path is a hard error; with it, `seq` resumes after the file's last parseable line.

## Known limitations

**Speaker bleed on speakers.** Without headphones, your microphone picks up the remote
party coming out of your own speakers, and that audio gets labeled `me`. Echo
cancellation (`setVoiceProcessingEnabled`) is enabled as a mitigation, but it does not
fully suppress bleed on every device and routing combination. **Use headphones** when
attribution accuracy matters. The failure is visible in the output as two near-identical
turns a fraction of a second apart, one `me` and one `other`.

**Bluetooth degrades echo cancellation.** AirPods and similar have a round-trip latency
the built-in canceller isn't tuned for, so bleed is measurably worse on them than on
wired headphones or the built-in mic.

**Switching input devices mid-meeting** is detected and the capture tap is rebuilt
against the new device, with a warning printed to stderr. Attribution around that moment
is still less trustworthy - prefer settling on a device before the call starts.

**Ambient noise produces short spurious `me` turns.** Voice activity detection on the mic
fires on keyboard clatter, breath, and background speech, and ASR then hallucinates a short
word for it - observed in testing as one-word turns like `"Hmm."` or `"Oops."`. Consumers
should expect occasional very short `me` turns that nobody said. Filtering on duration
(say, under 0.5s) removes most of them.

**If system-audio capture dies mid-session** (`System-audio capture stopped unexpectedly`
on stderr), `listen` keeps running with only the mic stream rather than exiting. Watch for
that message; the transcript will silently contain no `other` turns after it.

**Every remote participant collapses to `other`.** Live mode does not distinguish
between multiple people on the far end; per-name identity is deliberately deferred to
offline reconciliation. Batch mode with a voiceprint only distinguishes `me` from
everyone else.

## Development

```sh
make build     # debug build
make test      # automated self-tests
make clean
```

### Speaker identity across meetings

`review --enroll` stores a voiceprint per named cluster; `diarize` matches later meetings
against them, so someone named once resolves automatically afterwards.

```sh
bionic review ~/meetings/standup --enroll   # no dir needed - uses the shared default
bionic diarize ~/meetings/next               # picks up enrolled voices automatically
```

Both sides default to `~/.config/bionic/voiceprints`, so enrollment and matching cannot end up
pointed at different directories. Passing an explicit path to either still works.

Re-enrolling the same person **refines** their voiceprint rather than replacing it: the stored
centroid is a running mean weighted by how many meetings it already represents, so one bad
sample cannot undo months of evidence, and a cluster with less than 3s of speech is kept only
as a recent-sample anchor without moving the centroid. Matching takes the nearest of the
centroid and the last few per-meeting embeddings, which recovers the case where someone sounds
unlike their long-term average today (new headset, a cold).

### Accuracy regression gate

`make test` verifies plumbing - ordering, crash recovery, path shapes. It does not notice
if diarization gets *worse*. That is what the quality gate is for:

```sh
make fixture        # synthesize testdata/quality/ + its ground truth (one-off, ~10s)
make quality        # score DER against the committed baseline
make quality-bless  # record current accuracy AS the baseline
```

The fixture is built by `say`, so the reference transcript and speaker boundaries are exact
by construction rather than hand-labelled. The baseline is a **ratchet, not a target**: the
committed number is simply what the current stack scores, and the gate fails when a change
makes it worse by more than the tolerance (0.02 DER, above cross-machine inference jitter).
Improvements pass and print a prompt to re-bless.

Read the number for what it is. Synthesized speech has no overlap, no crosstalk and no room
noise, so it scores far better than a real meeting - this detects regressions, it does not
estimate real-world accuracy. A recorded fixture is still needed for that. The current
baseline (DER 0.30, with the diarizer merging two of three speakers on clean synthetic
audio) is a floor to improve on, not a standard to be proud of.

- `docs/manual-live-capture-test.md` - the manual end-to-end test procedure. Run this
  before trusting a change to the capture path; it's the only test that exercises real
  hardware.
- `thoughts/transcriber-handoff.md` - the JSONL contract as agreed with consumers.
  Treat it as the source of truth for the output format.

### Layout

| File | Role |
|---|---|
| `Sources/bionic/main.swift` | CLI dispatch, batch pipeline, enrollment, shared helpers |
| `Sources/bionic/Listen.swift` | Live `listen` subcommand: wiring, shutdown, signals |
| `Sources/bionic/Capture.swift` | Mic (AVAudioEngine) and system audio (ScreenCaptureKit) adapters |
| `Sources/bionic/TurnPipeline.swift` | Streaming VAD -> turn boundaries -> per-turn ASR |
| `Sources/bionic/TurnMerger.swift` | Reorders the two live streams into ascending `start` |
| `Sources/bionic/AudioRecorder.swift` | Opt-in audio retention: WAV writer, capture tee, session manifest |
| `Sources/bionic/Reconcile.swift` | Pure overlap logic mapping diarizer clusters onto turns |
| `Sources/bionic/Diarize.swift` | `diarize` subcommand: offline clustering + reconciliation |
| `Sources/bionic/Review.swift` | `review` subcommand: name clusters, persist voiceprints |
| `Sources/bionic/SelfTest*.swift` | Automated tests (merger ordering, pipeline, reconcile, recorder) |

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) for VAD, Parakeet
ASR, and diarization.
