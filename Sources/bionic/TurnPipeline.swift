import Foundation
import FluidAudio

// MARK: - Live per-stream pipeline: raw audio -> streaming VAD turn boundaries -> per-turn ASR.
//
// This is the reusable unit the task calls for: it is agnostic to WHERE the audio came from
// (AVAudioEngine mic tap, ScreenCaptureKit system-audio tap, or a synthetic test harness) -
// the same function drives both the "me" and "other" streams, parameterized only by `speaker`.

/// One chunk of already-resampled 16kHz mono Float32 audio, tagged with the wall-clock epoch
/// time it was received by the capture adapter (i.e. `Date().timeIntervalSince1970` at the
/// moment the adapter's callback fired). The pipeline below never looks at where this came
/// from - mic, system audio, and the synthetic ordering test in SelfTest.swift all produce the
/// same shape.
struct RawAudioChunk: Sendable {
    let samples: [Float]
    let epochTime: TimeInterval
}

/// One finalized turn, ready for the ordering/merge layer (TurnMerger). `speaker` is passed in
/// by the caller (structural labeling - "me" for the mic stream, "other" for the system-audio
/// stream - see Listen.swift's module doc for why there's no verification/distance threshold
/// here at all).
struct FinalizedTurn: Sendable {
    let speaker: String
    let start: TimeInterval // epoch seconds
    let end: TimeInterval   // epoch seconds
    let text: String
}

/// Consumes one stream of RawAudioChunks, runs FluidAudio's streaming VAD
/// (`VadManager.processStreamingChunk` / `VadStreamEvent`) across it to detect speech-start and
/// speech-end boundaries, accumulates the audio between those boundaries, and transcribes each
/// finalized segment. Calls `emit` once per non-blank finalized turn.
///
/// ASR CHOICE - documented per the task's request: this uses
/// `UnifiedAsrManager.transcribe(_:)` (one batch call on the full turn's accumulated audio at
/// VAD speech-end) rather than a true streaming ASR manager (`StreamingAsrManager` /
/// `StreamingEouAsrManager` / `StreamingNemotronAsrManager`, see
/// `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/`). Reasoning:
///   - The JSONL contract (transcriber-handoff.md) only requires `final:true` turns in v0;
///     `final` exists for FUTURE partial/live-display support, but the consumer explicitly
///     ignores non-final lines today. Streaming ASR's main advantage - incremental partial
///     text mid-utterance - has no consumer yet, so its extra complexity buys nothing yet.
///   - `StreamingAsrManager`'s protocol (appendAudio / processBufferedAudio / finish / reset)
///     is built around one continuous session that gets finished/reset at logical boundaries.
///     Here VAD - not the ASR engine - already owns turn-boundary detection, so driving a
///     `StreamingAsrManager` through a finish()/reset() cycle at every VAD speech-end would add
///     a second session-lifecycle to manage for no behavioral gain over calling `transcribe()`
///     once the segment's boundaries are already known.
///   - `UnifiedAsrManager.transcribe(_ samples: [Float])` is exactly what the existing offline
///     batch path (`run()`, main.swift) already uses per-turn - reusing it keeps one ASR calling
///     convention in the whole project, and it's already proven correct against real audio.
/// If v1 wants live partial captions, swap this call for a `StreamingAsrManager` driven by the
/// same VAD boundaries - the surrounding turn-boundary/merge machinery would not need to change.
///
/// `conf` is NOT part of `FinalizedTurn` - it's fixed to 1.0 when TurnWriter converts to the
/// wire `Turn` struct. That's intentional, not a placeholder; see TurnWriter.write for why.
/// `onComplete`, if given, is called exactly once when the stream has fully drained (after any
/// end-of-stream force-finalize), reporting `firstChunkEpoch` (epoch of absolute sample 0 - the
/// anchor the offline tools use to map WAV seconds back onto epoch time; nil if the stream carried
/// no audio) and `vadDesyncChunks` (count of chunks whose VAD inference threw, so the caller can
/// record the JSONL-vs-WAV timeline drift in the session manifest). Added as an optional callback,
/// NOT a changed return type, so existing call sites (Listen.swift, SelfTestPipeline.swift) that
/// don't need it stay valid unchanged.
func runStreamPipeline(
    speaker: String,
    chunks: AsyncStream<RawAudioChunk>,
    vad: VadManager,
    asr: UnifiedAsrManager,
    vadConfig: VadSegmentationConfig = .default,
    onComplete: (@Sendable (_ firstChunkEpoch: TimeInterval?, _ vadDesyncChunks: Int) async -> Void)? = nil,
    // TEST SEAM ONLY (SelfTestVadThrow). When non-nil, each chunk is run through this closure
    // instead of vad.processStreamingChunk, so a test can deterministically inject a throw and
    // cover the two branches that otherwise have NONE and both fail silently + unrecoverably: the
    // desync-lockstep invariant (a VAD throw must NOT advance totalSamplesConsumed) and the
    // trailing-pad double-subtraction guard. Production callers (Listen.swift, SelfTestPipeline)
    // leave it nil and get the real VAD. This is deliberately NOT surfaced as a CLI flag or config
    // knob - it is a test seam, not a runtime option, and must never become one.
    vadProcessor: (@Sendable (_ chunk: [Float], _ state: VadStreamState, _ config: VadSegmentationConfig) async throws -> VadStreamResult)? = nil,
    emit: @escaping @Sendable (FinalizedTurn) async -> Void
) async {
    let sampleRate = 16000
    let chunkSize = VadManager.chunkSize // 4096 samples = 256ms @ 16kHz

    // Real VAD by default; a test seam may substitute a scripted processor (see vadProcessor).
    let runVadChunk = vadProcessor ?? { chunk, state, config in
        try await vad.processStreamingChunk(chunk, state: state, config: config)
    }

    var vadState = await vad.makeStreamState()
    var carry: [Float] = [] // audio received but not yet forming one full VAD chunk

    var firstChunkEpoch: TimeInterval?   // epoch time corresponding to absolute sample 0
    var totalSamplesConsumed = 0         // kept in exact lockstep with VAD's own processedSamples
    var vadDesyncChunks = 0              // chunks whose VAD inference threw (timeline drift vs. WAV)

    var previousChunk: [Float]?          // one-chunk lookback, for speech-start pre-roll
    var inTurn = false
    var turnBuffer: [Float] = []
    var turnStartAbsSample = 0
    var turnStartEpoch: TimeInterval = 0

    func epoch(forAbsoluteSample sample: Int) -> TimeInterval {
        (firstChunkEpoch ?? Date().timeIntervalSince1970) + Double(sample) / Double(sampleRate)
    }

    // Finalize the in-progress turn using `endAbsSample` as its end boundary: slice the
    // accumulated buffer, run ASR, and emit if non-blank. Awaited (not fire-and-forget):
    // UnifiedAsrManager is a shared actor also driven by the OTHER stream's pipeline, so
    // concurrent transcribe() calls already serialize on it - awaiting here costs no throughput
    // and keeps this function's local state (turnBuffer etc.) trivially race-free.
    func finalizeTurn(endAbsSample: Int) async {
        let endEpoch = epoch(forAbsoluteSample: endAbsSample)
        let length = max(0, endAbsSample - turnStartAbsSample)
        let samples = length > 0 ? Array(turnBuffer.prefix(length)) : []
        inTurn = false
        turnBuffer = []
        guard !samples.isEmpty else { return }
        do {
            let text = try await asr.transcribe(samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let start = turnStartEpoch
            let end = max(endEpoch, start + 0.01)
            await emit(FinalizedTurn(speaker: speaker, start: start, end: end, text: trimmed))
        } catch {
            err("listen[\(speaker)]: ASR failed for turn \(turnStartEpoch)-\(endEpoch): \(error) - dropping turn.")
        }
    }

    // Process exactly one chunkSize-sized chunk through VAD and the turn-accumulation state
    // machine. Shared by the main loop and by the end-of-stream partial-chunk flush below.
    func processFixedChunk(_ chunk: [Float]) async {
        let chunkAbsStart = totalSamplesConsumed
        guard let result = try? await runVadChunk(chunk, vadState, vadConfig) else {
            // VAD inference threw for this chunk. Do NOT advance totalSamplesConsumed here.
            // `processStreamingChunk` calls processChunk FIRST and only then runs the state
            // machine that does `processedSamples += chunkSampleCount`, so on a throw the VAD's
            // own counter did not move. Every event's `sampleIndex` is expressed in that counter's
            // frame, so advancing ours would desync the two by chunk.count PERMANENTLY - each
            // later speechStart/speechEnd would be decoded in the wrong frame, giving wrong
            // turnStartAbsSample, wrong epoch(), and misaligned audio slices for the rest of the
            // run, with no recovery. Staying in lockstep instead loses this chunk's 256ms from
            // the time base (timestamps run slightly early) but keeps every index consistent.
            // previousChunk is still updated: physically this audio does immediately precede the
            // next chunk, so it remains the correct pre-roll lookback.
            //
            // Count this: the WAV (if recording) DID retain this chunk while our sample counter did
            // not move, so each such throw shifts the JSONL turn epochs 256ms earlier relative to
            // the recorded audio. The manifest carries this count so `diarize` can refuse to
            // reconcile a drifted session without --force.
            vadDesyncChunks += 1
            previousChunk = chunk
            return
        }
        vadState = result.state

        if let event = result.event {
            switch event.kind {
            case .speechStart:
                let startAbs = event.sampleIndex
                if let prev = previousChunk, startAbs < chunkAbsStart {
                    // speechStart always backdates by a fixed pre-roll from the current chunk's
                    // start (see VadManager+Streaming.streamingStateMachine - it's a constant
                    // offset, not a re-detected onset sample), so at most the tail of the ONE
                    // previous chunk is needed to reconstruct the pre-roll audio.
                    let idealBack = chunkAbsStart - startAbs
                    let backBy = min(prev.count, idealBack)
                    turnBuffer = Array(prev.suffix(backBy)) + chunk
                    turnStartAbsSample = chunkAbsStart - backBy // actual data start (== startAbs
                    // unless idealBack exceeded one chunk's worth of lookback, e.g. a
                    // non-default speechPadding > 256ms - kept internally consistent either way)
                } else {
                    turnBuffer = chunk
                    turnStartAbsSample = chunkAbsStart
                }
                turnStartEpoch = epoch(forAbsoluteSample: turnStartAbsSample)
                inTurn = true
            case .speechEnd:
                if inTurn {
                    turnBuffer.append(contentsOf: chunk)
                    await finalizeTurn(endAbsSample: event.sampleIndex)
                }
            }
        } else if inTurn {
            turnBuffer.append(contentsOf: chunk)
        }

        totalSamplesConsumed += chunk.count
        previousChunk = chunk
    }

    for await raw in chunks {
        if firstChunkEpoch == nil {
            // Anchor epoch(sample 0) so that epoch(sample i) == anchor + i/sampleRate holds for
            // every chunk boundary, not just VAD-chunk-sized boundaries: `raw.epochTime` is the
            // wall-clock time this audio finished arriving, so subtract its own duration.
            firstChunkEpoch = raw.epochTime - Double(raw.samples.count) / Double(sampleRate)
        }
        carry.append(contentsOf: raw.samples)

        while carry.count >= chunkSize {
            let chunk = Array(carry.prefix(chunkSize))
            carry.removeFirst(chunkSize)
            await processFixedChunk(chunk)
        }
    }

    // Stream ended (capture stopped, e.g. SIGINT). Feed any trailing <1 chunk of audio through
    // VAD too (padded like VadManager.processChunk pads short chunks) rather than silently
    // dropping up to 256ms of trailing audio, then force-finalize an in-progress turn with
    // whatever we have - better a slightly-truncated last utterance than a silently dropped one.
    // The padding is counted by both VAD and us, so lockstep is preserved - but those padded
    // samples never existed. Subtract them from the final turn's end boundary below, or the last
    // utterance of every session gets an `end` epoch up to 256ms past when the speaker actually
    // stopped, and ASR is handed a synthetic repeated-sample tail as if it were real audio.
    var trailingPadCount = 0
    if !carry.isEmpty {
        var finalChunk = carry
        trailingPadCount = max(0, chunkSize - finalChunk.count)
        if trailingPadCount > 0 {
            let lastSample = finalChunk.last ?? 0
            finalChunk.append(contentsOf: Array(repeating: lastSample, count: trailingPadCount))
        }
        // If VAD throws on this final padded chunk, processFixedChunk takes the desync branch and
        // does NOT advance totalSamplesConsumed - so the pad was never baked into the counter. In
        // that case subtracting trailingPadCount below would pull the last turn's end ~256ms EARLIER
        // than reality (double subtraction). Detect the non-advance and zero the pad so the end
        // boundary stays at the last real consumed sample. (When the chunk IS consumed, the pad is
        // in the counter and must be subtracted, as before.)
        let beforeFinal = totalSamplesConsumed
        await processFixedChunk(finalChunk)
        if totalSamplesConsumed == beforeFinal { trailingPadCount = 0 }
    }
    if inTurn {
        await finalizeTurn(endAbsSample: totalSamplesConsumed - trailingPadCount)
    }

    await onComplete?(firstChunkEpoch, vadDesyncChunks)
}
