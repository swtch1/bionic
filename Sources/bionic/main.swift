import Foundation
import FluidAudio

// bionic v0 - offline batch transcriber.
//
// Pipeline (unchanged): resample -> diarize into speaker turns -> transcribe each turn.
// NEW output: an append-only JSONL transcript, one JSON object per finalized turn.
// Each diarization segment IS one "turn". Speakers are labeled me / other / unknown
// via FluidAudio speaker verification (cosine distance to a "me" voiceprint).

// MARK: - Speaker-labeling heuristics (v0 - tunable)
//
// cosineDistance(a, b): 0 = identical voice, 2 = opposite. LOWER = more similar.
let dMe: Float = 0.45     // below this: confidently "me"
let dOther: Float = 0.65  // above this: confidently "other"
// dMe <= d <= dOther is the ambiguous band -> "unknown".

// conf = confidence IN THE ASSIGNED LABEL, in [0, 1]. Derived from distance-to-boundary.
// (This is speaker-attribution confidence, NOT ASR confidence.)
//   me      (d < dMe):     conf = 0.5 + 0.5 * clamp((dMe - d) / dMe, 0, 1)          -> [0.5, 1.0], ->1 as d->0
//   other   (d > dOther):  conf = 0.5 + 0.5 * clamp((d - dOther) / (2 - dOther), 0, 1) -> [0.5, 1.0], ->1 as d->2
//   unknown (band):        conf = 0.3 * clamp(distToNearestBoundary / halfBand, 0, 1) -> [0, 0.3], most-unknown at band center
// Property: an "unknown" turn (<=0.3) never outranks a confident me/other turn (>=0.5).
func labelAndConf(forDistance d: Float) -> (speaker: String, conf: Double) {
    func clamp(_ x: Float) -> Float { min(1, max(0, x)) }
    if !d.isFinite {
        // cosineDistance returns .infinity on dim-mismatch / zero-magnitude embeddings.
        return ("unknown", 0.0)
    }
    if d < dMe {
        return ("me", Double(0.5 + 0.5 * clamp((dMe - d) / dMe)))
    } else if d > dOther {
        return ("other", Double(0.5 + 0.5 * clamp((d - dOther) / (2.0 - dOther))))
    } else {
        let halfBand = (dOther - dMe) / 2
        let mid = (dMe + dOther) / 2
        let distToNearestBoundary = halfBand - abs(d - mid) // 0 at boundary, halfBand at center
        let c = halfBand > 0 ? 0.3 * clamp(distToNearestBoundary / halfBand) : 0.3
        return ("unknown", Double(c))
    }
}

// MARK: - JSONL turn record. All 7 fields required. Emitted key order is nondeterministic
// (not declaration order) - consumers parse by name.
struct Turn: Codable {
    let seq: Int
    let start: Double   // epoch seconds
    let end: Double     // epoch seconds
    let speaker: String // "me" | "other" | "unknown"
    let text: String
    let final: Bool     // always true in v0
    let conf: Double    // speaker-attribution confidence [0,1]
}

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Consume the value token following `flag` at `args[i]`, advancing `i` past both. One shared
/// implementation behind every subcommand's arg parser; `noun` parameterizes the only per-site
/// difference (the error word - "value" vs "path"). Exits 2 if the value is missing.
func consumeFlagValue(_ flag: String, _ i: inout Int, _ args: [String], noun: String = "value") -> String {
    guard i + 1 < args.count else { err("\(flag) requires a \(noun)"); exit(2) }
    let v = args[i + 1]; i += 2; return v
}

func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

// Print a bordered warning box to stderr: blank line, rule, one line per message, rule,
// blank line. Shared formatting only - each call site supplies its own message body, so
// distinct warnings (e.g. circular self-enrollment vs. voiceprint dimension mismatch)
// stay visually identical in shape while remaining textually distinguishable.
func printBoxedWarning(_ lines: [String]) {
    err("")
    err("############################################################################")
    for line in lines { err(line) }
    err("############################################################################")
    err("")
}

// MARK: - Coalescing consecutive same-speaker diarizer segments into one turn.
//
// The contract defines a turn as "one speaker's continuous utterance", not one line
// per raw diarizer segment. We merge consecutive segments sharing a speakerId into a
// single MergedTurn spanning their combined time range, so ASR runs ONCE per turn on
// the full concatenated sample range (never per sub-segment + text-join).
struct MergedTurn {
    let speakerId: String
    let startTimeSeconds: Float
    let endTimeSeconds: Float
    let embedding: [Float] // duration-weighted mean of constituent segment embeddings, L2-normalized
}

// L2-normalize a vector. FluidAudio's own VDSPOperations.l2Normalize is internal to the
// package (not accessible from this executable target), so this is a local equivalent -
// matches the shape of the library's own mean-embedding helpers (e.g. SpeakerOperations.
// averageEmbeddings normalizes after averaging). Note: SpeakerUtilities.cosineDistance is
// scale-invariant (it divides by magnitude whenever inputs aren't already unit-norm), so
// this normalization doesn't change distance results - it's done for consistency/hygiene,
// not because correctness depends on it.
func l2Normalize(_ v: [Float]) -> [Float] {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    guard sumSq > 0 else { return v }
    let norm = sumSq.squareRoot()
    return v.map { $0 / norm }
}

// Duration-weighted mean of a set of (embedding, duration) pairs, L2-normalized. Extracted
// from coalesceSegments' original inline accumulation so enrollment (below) can collapse a
// solo sample's segments into one voiceprint embedding using the EXACT SAME math, rather than
// a second, differently-behaved averaging implementation. Semantics preserved from the
// original inline version: an item whose embedding dimension doesn't match the running sum's
// is skipped for the sum but its duration still counts toward totalDuration (matches the
// original per-segment loop's behavior, carried over unchanged rather than "fixed" here).
func durationWeightedMeanEmbedding(_ items: [(embedding: [Float], duration: Float)]) -> [Float] {
    guard let dim = items.first?.embedding.count else { return [] }
    var weightedSum = [Float](repeating: 0, count: dim)
    var totalDuration: Float = 0
    for item in items {
        if weightedSum.count == item.embedding.count {
            for k in 0..<weightedSum.count { weightedSum[k] += item.embedding[k] * item.duration }
        }
        totalDuration += item.duration
    }
    return totalDuration > 0 ? l2Normalize(weightedSum.map { $0 / totalDuration }) : weightedSum
}

// Merge consecutive same-speakerId segments (diarResult.segments is already time-ordered).
// Embedding = duration-weighted mean of constituents (weight = each segment's durationSeconds),
// which is a deliberate divergence from FluidAudio's own `buildSpeakerDatabase` (that helper does
// an unweighted per-segment-count mean, and does NOT re-normalize afterward) - duration-weighting
// better reflects "how much of this merged turn's audio actually came from this sub-segment,"
// per the task spec. Does NOT merge across different speakers even with no time gap.
func coalesceSegments(_ segments: [TimedSpeakerSegment]) -> [MergedTurn] {
    guard !segments.isEmpty else { return [] }
    var result: [MergedTurn] = []

    var curSpeaker = segments[0].speakerId
    var curStart: Float = 0
    var curEnd: Float = 0
    var groupSegments: [TimedSpeakerSegment] = []

    // (Re)start the in-progress group at `seg`. Used both to seed the first group and,
    // in the loop below, whenever the speaker changes.
    func startGroup(_ seg: TimedSpeakerSegment) {
        curSpeaker = seg.speakerId
        curStart = seg.startTimeSeconds
        curEnd = seg.endTimeSeconds
        groupSegments = [seg]
    }

    func flush() {
        let mean = durationWeightedMeanEmbedding(groupSegments.map { (embedding: $0.embedding, duration: $0.durationSeconds) })
        result.append(MergedTurn(speakerId: curSpeaker, startTimeSeconds: curStart, endTimeSeconds: curEnd, embedding: mean))
    }

    startGroup(segments[0])
    for seg in segments.dropFirst() {
        if seg.speakerId == curSpeaker {
            curEnd = seg.endTimeSeconds
            groupSegments.append(seg)
        } else {
            flush()
            startGroup(seg)
        }
    }
    flush()
    return result
}

// MARK: - Find the seq to resume numbering at when --append is used.
// Walks the existing file's lines backward (skipping blank/malformed trailing lines) until
// one parses as a Turn. Returns nil if no line in the file has a parseable seq (caller warns
// and treats the file as empty in that case).
func lastSeq(inExistingJSONL text: String) -> Int? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines.reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
        if let turn = try? JSONDecoder().decode(Turn.self, from: data) {
            return turn.seq
        }
    }
    return nil
}

// MARK: - Shared --out/--append/refuse-if-exists/resume-seq logic. Both run() (batch) and the
// `listen` subcommand (live capture, Listen.swift) go through this one implementation of "how do
// we decide the starting seq and open the output file," so the two paths cannot diverge on
// overwrite refusal, resume numbering, or exit codes.
func openTurnOutput(outPath: String, appendFlag: Bool) -> (handle: FileHandle, startSeq: Int) {
    let fm = FileManager.default
    var startSeq = 0
    if fm.fileExists(atPath: outPath) {
        let size = (try? fm.attributesOfItem(atPath: outPath))?[.size] as? UInt64 ?? 0
        if size > 0 {
            guard appendFlag else {
                err("Error: \(outPath) already exists and is non-empty.")
                err("Refusing to overwrite/corrupt seq numbering. Either:")
                err("  - pass --append to resume numbering after this file's last turn, or")
                err("  - choose a different --out path.")
                exit(2)
            }
            let existingText = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
            if let last = lastSeq(inExistingJSONL: existingText) {
                startSeq = last + 1
                err("--append: resuming seq numbering at \(startSeq) (after existing \(outPath)).")
            } else {
                err("WARNING: --append given but no line in \(outPath) had a parseable seq.")
                err("Treating the file as if it were empty; starting seq at 0 (unexpected - check the file).")
                startSeq = 0
            }
        }
    } else {
        fm.createFile(atPath: outPath, contents: nil)
    }

    // MARK: Open output JSONL for appending.
    guard let handle = FileHandle(forWritingAtPath: outPath) else {
        err("Could not open \(outPath) for writing."); exit(1)
    }
    handle.seekToEndOfFile()
    err("Appending JSONL turns to \(outPath)")
    return (handle, startSeq)
}

// MARK: - `enroll` subcommand: build a persistable "me" voiceprint from one clean solo sample.
//
// Chose full offline diarization (reusing OfflineDiarizerManager, same as the batch path)
// over FluidAudio's streaming `Diarizer.enrollSpeaker(withAudio:...)` for this. That method
// lives on the streaming `Diarizer` protocol (LSEENDDiarizer / SortformerDiarizer) - a
// different diarizer stack than OfflineDiarizerManager, which this project uses everywhere
// else and which has no equivalent single-call enrollment method of its own (verified against
// .build/checkouts/FluidAudio/Sources: OfflineDiarizerManager only exposes the `process(...)`
// family). Pulling in the streaming diarizer just for enrollment would mean two divorced
// diarization stacks (and two embedding spaces) in one small CLI, for a sample that's a few
// seconds of audio - the cost isn't justified. Running the existing offline pipeline on the
// solo sample and collapsing its segment embeddings is more code-consistent and, since it's
// the same embedding model/version the batch path's cosineDistance check will run against,
// more correct for THIS project.
func runEnroll() async throws {
    // MARK: CLI parsing - enroll <clean_solo_sample.wav> --name <name> [--out <voiceprint.json>]
    var samplePath: String?
    var speakerName: String?
    var outPath = "voiceprint.json"
    var i = 2 // args[0] = binary, args[1] = "enroll"
    let args = CommandLine.arguments
    func flagValue(_ flag: String) -> String { consumeFlagValue(flag, &i, args) }
    while i < args.count {
        switch args[i] {
        case "--name": speakerName = flagValue("--name")
        case "--out": outPath = flagValue("--out")
        default:
            if samplePath == nil { samplePath = args[i] } // first positional = sample audio file
            i += 1
        }
    }
    guard let sample = samplePath, let name = speakerName else {
        err("usage: bionic enroll <clean_solo_sample.wav> --name <name> [--out <voiceprint.json>]")
        exit(2)
    }

    let sampleRate: Float = 16000
    let t0 = Date()

    err("Loading + resampling enrollment sample...")
    let samples = try AudioConverter().resampleAudioFile(path: sample)
    let audioSeconds = Double(samples.count) / Double(sampleRate)
    guard audioSeconds > 0 else {
        err("Enrollment sample \(sample) is empty - nothing to enroll.")
        exit(1)
    }

    err("Preparing diarization models (first run downloads them)...")
    let diar = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    try await diar.prepareModels()

    err("Diarizing enrollment sample...")
    let diarResult = try await diar.process(audio: samples)
    guard !diarResult.segments.isEmpty else {
        err("No speech detected in \(sample) - nothing to enroll.")
        exit(1)
    }

    // A genuinely "clean solo sample" should diarize to one speakerId. If the diarizer still
    // splits it (background noise, brief cross-talk, a stray cough misclustered, etc.), don't
    // fail - warn loudly and fall back to "pick the speaker with the most total speech
    // duration," the same dominant-speaker heuristic run() uses for its self-enrollment fallback.
    var durationById: [String: Float] = [:]
    for seg in diarResult.segments { durationById[seg.speakerId, default: 0] += seg.durationSeconds }
    if durationById.count > 1 {
        printBoxedWarning([
            "# WARNING: enrollment sample diarized into \(durationById.count) distinct speakers. ",
            "# Expected a clean solo sample (one speaker). Using the speaker with the most        ",
            "# total speech duration; consider trimming a cleaner sample for a better voiceprint. ",
        ])
    }
    guard let dominant = durationById.max(by: { $0.value < $1.value }) else {
        err("Could not determine a dominant speaker in \(sample).")
        exit(1)
    }
    let dominantId = dominant.key
    err("Dominant speaker '\(dominantId)': \(String(format: "%.1f", dominant.value))s of \(String(format: "%.1f", audioSeconds))s total.")

    // Collapse that speaker's segments into ONE representative embedding: duration-weighted
    // mean, L2-normalized - the same math coalesceSegments uses to merge a turn's segments,
    // via the shared durationWeightedMeanEmbedding helper (see its doc comment above).
    let dominantSegments = diarResult.segments.filter { $0.speakerId == dominantId }
    let embedding = durationWeightedMeanEmbedding(
        dominantSegments.map { (embedding: $0.embedding, duration: $0.durationSeconds) }
    )
    guard !embedding.isEmpty else {
        err("Could not compute a voiceprint embedding from \(sample).")
        exit(1)
    }

    // Speaker's own initializer (FluidAudio's Speaker.init(id:name:currentEmbedding:...)) is used
    // rather than hand-constructing every field: it already sets updateCount = 1, rawEmbeddings =
    // [] (both fixed by the initializer regardless of what's passed - there is no way to seed
    // rawEmbeddings via this init), and L2-normalizes currentEmbedding again (harmless - it's
    // already normalized; a no-op re-normalization). isPermanent: true because this voiceprint was
    // deliberately, manually enrolled - not a transient speaker discovered mid-meeting that should
    // be eligible for eviction/merging.
    let speaker = Speaker(
        name: name,
        currentEmbedding: embedding,
        duration: dominant.value,
        isPermanent: true
    )

    let encoder = JSONEncoder()
    let json = try encoder.encode(speaker)
    try json.write(to: URL(fileURLWithPath: outPath))

    let elapsed = Date().timeIntervalSince(t0)
    err(String(format: "Wrote voiceprint for '%@' (id=%@, %d-d, %.1fs of speech) to %@. Done in %.1fs.",
               name, speaker.id, embedding.count, dominant.value, outPath, elapsed))
}

func run() async throws {
    // MARK: CLI parsing - <audiofile> [--voiceprint <path.json>] [--out <transcript.jsonl>] [--append]
    var audioPath: String?
    var voiceprintPath: String?
    var outPath = "transcript.jsonl"
    var appendFlag = false
    var i = 1
    let args = CommandLine.arguments
    // Consume the path argument that follows a flag; errors + exits if it's missing.
    func flagValue(_ flag: String) -> String { consumeFlagValue(flag, &i, args, noun: "path") }
    while i < args.count {
        switch args[i] {
        case "--voiceprint": voiceprintPath = flagValue("--voiceprint")
        case "--out": outPath = flagValue("--out")
        case "--append": appendFlag = true; i += 1 // boolean flag, no value
        default:
            if audioPath == nil { audioPath = args[i] } // first positional = audio file
            i += 1
        }
    }
    guard let path = audioPath else {
        err("usage: bionic <audiofile> [--voiceprint <path.json>] [--out <transcript.jsonl>] [--append]")
        exit(2)
    }

    let sampleRate: Float = 16000
    let t0 = Date()

    // MARK: Decide seq numbering vs. existing --out content BEFORE any expensive work. This is
    // a microsecond-cost check that can exit(2) ("refusing to overwrite"), and running it after
    // model download + diarization + ASR would make a user wait minutes on a long recording only
    // to be told the output path was unusable from the start. `listen` already checks this first
    // (Listen.swift) - openTurnOutput is shared, so both paths now fail fast identically.
    let (handle, startSeq) = openTurnOutput(outPath: outPath, appendFlag: appendFlag)
    defer { try? handle.close() }

    err("Loading + resampling audio...")
    let samples = try AudioConverter().resampleAudioFile(path: path)
    let audioSeconds = Double(samples.count) / Double(sampleRate)

    err("Preparing diarization models (first run downloads them)...")
    let diar = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    try await diar.prepareModels()

    err("Diarizing...")
    let diarResult = try await diar.process(audio: samples)

    err("Loading ASR models (Parakeet, ANE)...")
    let asr = UnifiedAsrManager()
    try await asr.loadModels()

    let speakers = Set(diarResult.segments.map { $0.speakerId })
    err("Detected \(speakers.count) speaker(s) across \(diarResult.segments.count) turn(s).")

    // MARK: Epoch base - fixture timestamps are 0-based; contract wants Unix epoch.
    // Land the turns in a plausible "just now" window instead of 1970.
    let epochBase = Date().timeIntervalSince1970 - audioSeconds

    // MARK: Determine the "me" voiceprint (256-d [Float]).
    var meVoiceprint: [Float] = []
    if let vp = voiceprintPath {
        // Source 1: a persisted Codable Speaker JSON; use its .currentEmbedding.
        let data = try Data(contentsOf: URL(fileURLWithPath: vp))
        let speaker = try JSONDecoder().decode(Speaker.self, from: data)
        meVoiceprint = speaker.currentEmbedding
        err("Loaded 'me' voiceprint from \(vp) (speaker id=\(speaker.id), \(meVoiceprint.count)-d).")
    } else {
        // Source 2: circular self-enrollment from the fixture.
        printBoxedWarning([
            "# WARNING: no --voiceprint given -> CIRCULAR SELF-ENROLLMENT FALLBACK.       ",
            "# The 'me' voiceprint is derived from the fixture's own longest speaker.     ",
            "# This exercises the speaker-verification plumbing but does NOT validate     ",
            "# real me/not-me accuracy - that requires a real enrolled voiceprint.        ",
        ])

        // Pick the speaker with the most total speech duration across segments.
        var durationById: [String: Float] = [:]
        for seg in diarResult.segments {
            durationById[seg.speakerId, default: 0] += seg.durationSeconds
        }
        guard let me = durationById.max(by: { $0.value < $1.value }) else {
            err("No diarization segments - nothing to enroll or emit.")
            return
        }
        let meId = me.key
        err("Self-enrolled 'me' = longest speaker '\(meId)' (\(String(format: "%.1f", me.value))s of speech).")

        if let db = diarResult.speakerDatabase, let mean = db[meId], !mean.isEmpty {
            meVoiceprint = mean // mean embedding for that speaker
        } else {
            // Further fallback: mean of that speaker's own segment embeddings. Reuses
            // FluidAudio's own averaging helper (public, same one the library's speaker-merge
            // path uses) instead of hand-rolling the sum/divide loop; it also L2-normalizes,
            // which is a no-op on the eventual cosineDistance result (scale-invariant, see
            // l2Normalize's comment above).
            err("speakerDatabase empty/nil - averaging longest speaker's segment embeddings instead.")
            let embs = diarResult.segments.filter { $0.speakerId == meId }.map { $0.embedding }
            if let mean = SpeakerUtilities.averageEmbeddings(embs) {
                meVoiceprint = mean
            }
        }
    }
    guard !meVoiceprint.isEmpty else {
        err("Could not construct a 'me' voiceprint - aborting.")
        exit(1)
    }

    // MARK: Loud, explicit, one-time warning if the voiceprint's dimension doesn't
    // match the diarizer's segment embeddings. Without this, cosineDistance silently returns
    // .infinity for every turn (-> every turn labeled "unknown") with zero signal to the operator.
    if let firstDim = diarResult.segments.first?.embedding.count, firstDim != meVoiceprint.count {
        printBoxedWarning([
            "# WARNING: 'me' voiceprint dimension (\(meVoiceprint.count)) != diarizer segment  ",
            "# embedding dimension (\(firstDim)). cosineDistance will return .infinity for  ",
            "# EVERY turn as a result, so EVERY turn will be labeled \"unknown\".            ",
            "# Check that the voiceprint was produced by the same embedding model/version  ",
            "# as this diarizer.                                                           ",
        ])
    }

    // MARK: Coalesce consecutive same-speaker diarizer segments into merged turns
    // BEFORE running ASR (one ASR call per turn, not per raw sub-segment).
    let mergedTurns = coalesceSegments(diarResult.segments)
    err("Coalesced \(diarResult.segments.count) diarizer segment(s) into \(mergedTurns.count) turn(s).")

    let encoder = JSONEncoder()

    // MARK: Emit one JSONL line per non-empty turn. seq advances only for emitted lines.
    var seq = startSeq
    var emittedThisRun = 0
    for turn in mergedTurns {
        let startIdx = max(0, Int(turn.startTimeSeconds * sampleRate))
        let endIdx = min(samples.count, Int(turn.endTimeSeconds * sampleRate))
        guard endIdx > startIdx else { continue }
        let slice = Array(samples[startIdx..<endIdx])

        // MARK: One bad turn must not kill the whole run. Everything per-turn that
        // can throw (ASR, JSON encoding) is contained here; on failure we log which turn/time
        // range failed, do NOT advance seq, do NOT fabricate a placeholder line, and continue.
        do {
            let text = try await asr.transcribe(slice)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue } // skip blank turns; do not advance seq

            let d = SpeakerUtilities.cosineDistance(turn.embedding, meVoiceprint)
            let (speaker, conf) = labelAndConf(forDistance: d)

            // Round FIRST, then enforce start < end on the rounded values so the guard can't be
            // undone by later quantization. Bump by 0.01 (one round2 quantum) so it survives.
            let start = round2(epochBase + Double(turn.startTimeSeconds))
            var end = round2(epochBase + Double(turn.endTimeSeconds))
            if !(start < end) { end = start + 0.01 } // guarantee start < end (both already 0.01-quantized)

            let record = Turn(
                seq: seq,
                start: start,
                end: end,
                speaker: speaker,
                text: trimmed,
                final: true,
                conf: round2(conf)
            )

            let json = try encoder.encode(record)
            // write(contentsOf:) not write(_:) - the latter is the deprecated overload that
            // raises an uncatchable ObjC NSException on I/O failure (disk full, revoked fd),
            // crashing mid-meeting and possibly leaving a torn line. This one throws into the
            // per-turn catch below instead. Still one direct write() syscall - a tailer sees it
            // immediately.
            try handle.write(contentsOf: json + Data([0x0A]))
            if let s = String(data: json, encoding: .utf8) { print(s) } // echo for live visibility

            seq += 1
            emittedThisRun += 1
        } catch {
            err("Turn failed (speaker=\(turn.speakerId), \(String(format: "%.2f", turn.startTimeSeconds))s-\(String(format: "%.2f", turn.endTimeSeconds))s): \(error) - skipping, continuing with remaining turns.")
            continue
        }
    }

    let elapsed = Date().timeIntervalSince(t0)
    let seqRange = emittedThisRun > 0 ? " (seq \(startSeq)-\(seq - 1))" : ""
    err(String(format: "\nEmitted %d turn(s)%@. Done in %.1fs for %.1fs of audio (%.1fx real-time).",
               emittedThisRun, seqRange, elapsed, audioSeconds, audioSeconds / elapsed))
}

// NOTE: top-level code in main.swift runs on the MainActor. A plain `Task { }`
// would inherit MainActor isolation and need the main thread to run - but the main
// thread blocks on `sema.wait()` below, which deadlocks (Task body never executes).
// `Task.detached` runs off-MainActor on a cooperative worker thread, so it proceeds.
func runBlocking(_ body: @escaping @Sendable () async throws -> Void) {
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            try await body()
        } catch {
            err("Error: \(error)")
            exit(1)
        }
        sema.signal()
    }
    sema.wait()
}

// Both write paths echo each turn to stdout for live visibility. The Swift runtime does NOT
// ignore SIGPIPE, so `bionic listen | consumer` where the consumer exits first would kill
// capture mid-meeting (exit 141) - losing the rest of the meeting to a broken pipe on what is only
// a convenience echo. The JSONL FILE is the real output, so a dead stdout must never stop capture:
// ignore SIGPIPE and let the failed writes be silently dropped.
signal(SIGPIPE, SIG_IGN)

// MARK: Top-level CLI dispatch. `enroll` and `listen` are subcommands; anything else (including
// no subcommand at all) falls through to the existing default batch-transcribe behavior
// unchanged. `--selftest-merge` is a hidden, non-user-facing subcommand: automated verification
// of TurnMerger's reordering logic (see SelfTest.swift) - not part of the public CLI surface.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "enroll" {
    runBlocking(runEnroll)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "listen" {
    runBlocking(runListen)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "diarize" {
    runBlocking(runDiarize)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "review" {
    runBlocking(runReview)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-merge" {
    runBlocking(runSelfTestMerge)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-pipeline" {
    runBlocking(runSelfTestPipeline)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-reconcile" {
    runBlocking(runSelfTestReconcile)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-record" {
    runBlocking(runSelfTestRecord)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-binding" {
    runBlocking(runSelfTestBinding)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-loadturns" {
    runBlocking(runSelfTestLoadTurns)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-review" {
    runBlocking(runSelfTestReview)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-record-crash" {
    runBlocking(runSelfTestRecordCrash)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-session" {
    runBlocking(runSelfTestSession)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-vadthrow" {
    runBlocking(runSelfTestVadThrow)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest-record-child" {
    runBlocking { await runSelfTestRecordChild() }
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "repair-wav" {
    runBlocking(runRepairWav)
} else {
    runBlocking(run)
}
