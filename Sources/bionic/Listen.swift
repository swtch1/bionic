import Foundation
import FluidAudio

// MARK: - `listen` subcommand: live dual-stream capture -> structural me/other labeling ->
// streaming VAD turn-boundary detection -> per-turn ASR -> ordered JSONL append.
//
// ARCHITECTURE (decision already made, not relitigated here): dual-stream, STRUCTURAL labeling -
// no voiceprint, no diarizer, no cosineDistance anywhere in this path. Deliberately different
// from run()'s offline batch pipeline (main.swift), which IS voiceprint/diarizer-based. The
// speaker label falls out of WHICH CAPTURE STREAM the audio arrived on:
//   - AVAudioEngine mic tap (Capture.swift: MicCapture)         -> unambiguously "me"
//   - ScreenCaptureKit system-audio tap (Capture.swift: SystemAudioCapture) -> unambiguously
//     "other" (every remote participant on the call collapses to "other" - per-name identity
//     for multiple remote speakers is explicitly deferred to offline post-meeting reconciliation,
//     per transcriber-handoff.md's speaker-semantics section).
// Because the label is structural rather than inferred from a distance threshold, every emitted
// turn's `conf` is 1.0 - intentional, not a placeholder; see TurnWriter.write for the full why.
//
// KNOWN CORRECTNESS GAP - stated plainly, not papered over: on speaker output (not headphones),
// the mic will pick up the call's own remote-party audio, duplicating "other" speech onto the
// "me" stream. MicCapture.start() (Capture.swift) enables AVAudioEngine's built-in echo
// cancellation (`setVoiceProcessingEnabled(true)`) as the primary defense, but this is NOT
// guaranteed to fully suppress speaker bleed on every device/routing combination.
// HEADPHONES ARE THE SAFE FALLBACK - if "me" mislabeling matters for a given meeting, use
// headphones so the mic physically cannot pick up the call's own output. This is a real,
// disclosed limitation of the live path, not a solved problem.
func runListen() async throws {
    // MARK: CLI parsing - listen [--out <path>] [--title <desc>] [--append] [--record <session-dir>].
    // Same flag shapes as the batch path. --record is OPT-IN ONLY (never a default): it retains raw
    // meeting audio to disk, which is private, so nothing is written unless the operator asks by name.
    //
    // --out is now OPTIONAL: with no --out, the transcript is auto-named into the shared transcripts
    // directory (~/.config/bionic/transcripts, the same one feedbackapp's config points the responder
    // at) as `YYYY-MM-DD-HH-MM-SS-<title-slug>.jsonl` - so a meeting run without --out is still
    // discoverable later, and the responder can look it up by date. --title supplies the short
    // description; it defaults to "meeting" when the operator doesn't name the call up front.
    var outPath: String?
    var title = "meeting"
    var appendFlag = false
    var recordDir: String?
    var i = 2 // args[0] = binary, args[1] = "listen"
    let args = CommandLine.arguments
    func flagValue(_ flag: String) -> String { consumeFlagValue(flag, &i, args) }
    while i < args.count {
        switch args[i] {
        case "--out": outPath = flagValue("--out")
        case "--title": title = flagValue("--title")
        case "--append": appendFlag = true; i += 1
        case "--record": recordDir = flagValue("--record")
        default:
            err("listen: unrecognized argument '\(args[i])'")
            err("usage: bionic listen [--out <transcript.jsonl>] [--title <short description>] [--append] [--record <session-dir>]")
            exit(2)
        }
    }
    let outPathResolved = outPath ?? defaultTranscriptPath(title: title)

    // MARK: If retaining audio, create the session directory (0700) up front - BEFORE opening the
    // transcript, since the common invocation puts --out inside the session dir (make record uses
    // --out <SESSION>/transcript.jsonl). openTurnOutput can't create intermediate directories, so
    // without this an --out path inside a not-yet-existent session dir fails to open.
    if let recordDir {
        try? FileManager.default.createDirectory(
            atPath: recordDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    // MARK: Reuse the exact --out/--append/refuse-if-exists/resume-seq logic the batch path
    // uses (openTurnOutput, main.swift) - not reimplemented.
    let (handle, startSeq) = openTurnOutput(outPath: outPathResolved, appendFlag: appendFlag)
    // When retaining audio, the transcript is part of the same private session - tighten it to
    // 0600 to match the WAVs/manifest.
    if recordDir != nil {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outPathResolved)
    }
    let writer = TurnWriter(handle: handle, startSeq: startSeq)
    let merger = TurnMerger(writer: writer)

    // MARK: SIGINT -> clean flush-and-exit, installed FIRST, before model loading/capture
    // startup (which can take several seconds) - installing it later would leave a real window
    // where an early Ctrl-C lands while SIGINT still has its default (terminate-immediately)
    // disposition, or - worse - after `signal(SIGINT, SIG_IGN)` but before the DispatchSourceSignal
    // is resumed, where it would be silently swallowed and never seen again. Installed on a
    // DEDICATED BACKGROUND QUEUE, not `.main`: runBlocking() (main.swift) blocks the actual main
    // thread on a DispatchSemaphore for the whole run, so it never services the main dispatch
    // queue - a signal source targeting `.main` would simply never fire, and Ctrl-C would hang
    // instead of exiting cleanly. SIG_IGN suppresses the default terminate-immediately behavior
    // so THIS handler (not the OS default) decides when the process exits, after flushing and
    // closing the output file. If SIGINT arrives before startup finishes, `stopSignal.trigger()`
    // still records it (actor state, not lost) - shutdown then begins as soon as startup
    // completes and reaches `await stopSignal.wait()` below, rather than exiting instantly.
    let stopSignal = StopSignal()
    signal(SIGINT, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "bionic.sigint"))
    sigSource.setEventHandler {
        Task { await stopSignal.trigger() }
    }
    sigSource.resume()

    // SIGTERM -> the SAME graceful flush-and-exit as SIGINT. `kill <pid>` (and orderly logout/
    // shutdown) sends SIGTERM; without this it would hit the OS default (terminate immediately),
    // losing the un-flushed audio buffer AND skipping the final authoritative manifest. Routing it
    // through stopSignal.trigger() means kill flushes both WAVs, joins the pipelines, and writes the
    // complete manifest - exactly like Ctrl-C. (A crash/SIGKILL still can't be trapped; the
    // incremental header patch + partial manifest cover those.)
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "bionic.sigterm"))
    termSource.setEventHandler {
        Task { await stopSignal.trigger() }
    }
    termSource.resume()

    err("Loading VAD model...")
    let vad = try await VadManager()
    err("Loading ASR models (Parakeet, ANE)...")
    let asr = UnifiedAsrManager()
    try await asr.loadModels()
    // One VadManager + one UnifiedAsrManager instance, SHARED by both stream pipelines below.
    // Both are actors: each stream keeps its own VadStreamState (a value type, threaded through
    // processStreamingChunk by the caller, not stored in the actor) so the streams never
    // interfere with each other's turn-boundary detection; concurrent transcribe() calls from
    // the two pipelines simply serialize on the shared ASR actor. This avoids loading the VAD/ASR
    // models twice (memory + startup time) with no correctness cost.

    // MARK: Audio retention (opt-in via --record). Set up the session directory (0700) and one
    // Int16 WAV recorder per stream (files 0600) BEFORE capture starts, so no captured chunk is
    // missed. On any setup failure we warn loudly and continue WITHOUT retention rather than
    // aborting the meeting - a failed recording must never cost the live transcript.
    var session: RecordingSession?
    if let recordDir {
        session = try? RecordingSession.create(dir: recordDir)
        if let session {
            printBoxedWarning([
                "# RECORDING AUDIO to \(session.dir.path)                                       ",
                "# This retains RAW meeting audio (mic + system) to disk - private data.        ",
                "#   me.wav    <- your microphone                                               ",
                "#   other.wav <- remote participants (system audio)                            ",
                "# Delete the session directory when you no longer need it.                     ",
            ])
        } else {
            printBoxedWarning([
                "# WARNING: could not set up audio retention at \(recordDir).                   ",
                "# Continuing WITHOUT recording - the live transcript is unaffected.            ",
            ])
        }
    }

    err("Starting microphone capture ('me')...")
    let mic = MicCapture()
    var micStream = try mic.start()

    err("Starting system-audio capture ('other')...")
    let systemAudio = SystemAudioCapture()
    var systemStream = try await systemAudio.start()

    // Tee each capture stream through its recorder BEFORE it reaches the pipeline. Only real
    // captured chunks pass here; the pipeline's synthetic end-of-stream pad is built internally
    // and never crosses these streams (see AudioRecorder.recording / TurnPipeline).
    if let session {
        micStream = recording(micStream, into: session.me, sampleRate: Double(RecordingSession.sampleRate)) { anchor in
            session.noteAnchor(stream: "me", epoch: anchor)
        }
        systemStream = recording(systemStream, into: session.other, sampleRate: Double(RecordingSession.sampleRate)) { anchor in
            session.noteAnchor(stream: "other", epoch: anchor)
        }
    }

    let micDone = StreamCompletion()
    let systemDone = StreamCompletion()

    let micTask = Task { [micStream] in
        await runStreamPipeline(speaker: "me", chunks: micStream, vad: vad, asr: asr,
            onComplete: { epoch, desync in micDone.record(firstChunkEpoch: epoch, vadDesyncChunks: desync) }
        ) { turn in
            await merger.submit(turn)
        }
    }
    let systemTask = Task { [systemStream] in
        await runStreamPipeline(speaker: "other", chunks: systemStream, vad: vad, asr: asr,
            onComplete: { epoch, desync in systemDone.record(firstChunkEpoch: epoch, vadDesyncChunks: desync) }
        ) { turn in
            await merger.submit(turn)
        }
    }

    err("Listening. Press Ctrl-C to stop.")

    await stopSignal.wait()

    err("\nStopping capture... (press Ctrl-C again to force-quit)")
    mic.stop()
    await systemAudio.stop()

    // Both capture adapters just finished their AsyncStream's continuation, so each pipeline's
    // `for await` loop exits and (per TurnPipeline.swift's end-of-stream handling) force-
    // finalizes any turn that was still in progress, before returning.
    _ = await micTask.value
    _ = await systemTask.value

    // Only safe to flush unconditionally-in-start-order once both pipelines have fully stopped
    // producing (see TurnMerger.flushAll's doc comment) - guaranteed by the awaits just above.
    await merger.flushAll()
    writer.close()

    // Finalize retention AFTER both pipeline Tasks have joined: only then are the streams fully
    // drained (so every real chunk is buffered) and the onComplete callbacks fired (so the
    // per-stream anchorEpoch/vadDesyncChunks are populated for the manifest).
    if let session {
        await session.finishAndWriteManifest(
            me: (micDone.firstChunkEpoch, micDone.vadDesyncChunks),
            other: (systemDone.firstChunkEpoch, systemDone.vadDesyncChunks)
        )
    }

    let seqRange = writer.emittedCount > 0 ? " (seq \(startSeq)-\(startSeq + writer.emittedCount - 1))" : ""
    err("Done. Wrote \(writer.emittedCount) turn(s)\(seqRange) to \(outPathResolved).")
}

/// Default `listen` output path when --out isn't given: the shared transcripts directory
/// feedbackapp's `resources.yaml` registers as the "past-meetings" resource (see
/// feedbackapp/config.py's init_config), so a call transcribed without an explicit --out is
/// still something the responder can look up later, filed by date.
func defaultTranscriptPath(title: String) -> String {
    let dir = NSHomeDirectory() + "/.config/bionic/transcripts"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    formatter.timeZone = TimeZone.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let stamp = formatter.string(from: Date())
    return "\(dir)/\(stamp)-\(slugify(title)).jsonl"
}

/// Lowercase, alphanumerics-and-dashes only, collapsed - "Q3 Revenue Review!!" -> "q3-revenue-review".
/// Falls back to "meeting" for a title that slugifies to nothing (emoji-only, etc.) so the filename
/// is never left with a bare trailing/leading dash or an empty description segment.
func slugify(_ text: String) -> String {
    var result = ""
    var lastWasDash = false
    for scalar in text.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash && !result.isEmpty {
            result.append("-")
            lastWasDash = true
        }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "meeting" : result
}

/// Bridges a synchronous, signal-safety-constrained C signal handler into async/await: the
/// handler itself stays minimal (just spawns a Task), and runListen() awaits `wait()` to learn
/// when to begin shutdown.
actor StopSignal {
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func trigger() {
        // Second Ctrl-C -> hard exit. The graceful path (below) only runs once runListen()
        // reaches `await stopSignal.wait()`, which is AFTER capture startup (model load +
        // mic/ScreenCaptureKit init) completes. If startup itself hangs - e.g. a missing Screen
        // Recording TCC grant leaving `SCShareableContent.current` blocked forever - a single
        // Ctrl-C would set `stopped` here but never be acted on, and the process would be
        // un-interruptible. A second Ctrl-C forces the exit. This works even mid-hang because the
        // signal handler runs `trigger()` on the global executor, which still has free threads
        // while runListen() is suspended on the blocked startup await.
        // Tradeoff: a reflexive double-tap during a HEALTHY shutdown force-exits mid-flush. That's
        // acceptable - writes are one direct write() syscall per line, so at worst an un-flushed
        // in-progress turn is lost; no already-written line is ever torn.
        if stopped {
            err("\nSecond interrupt - forcing exit.")
            exit(130)
        }
        stopped = true
        for w in waiters { w.resume() }
        waiters = []
    }

    func wait() async {
        if stopped { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }
}
