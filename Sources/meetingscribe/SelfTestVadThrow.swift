import Foundation
import FluidAudio

// MARK: - Regression coverage for the VAD-throw handling in runStreamPipeline.
//
// This is the most dangerous unprotected code in the pipeline: when VAD inference throws for a
// chunk, runStreamPipeline must NOT advance totalSamplesConsumed, because VAD's own processedSamples
// counter did not move either (processStreamingChunk runs processChunk FIRST and only advances the
// counter in the state machine that a throw skips). Every later event's sampleIndex is expressed in
// VAD's frame, so if our counter and VAD's diverge, every subsequent turn boundary is decoded in the
// wrong frame - permanently, unrecoverably, and silently. Until now that invariant was defended only
// by a prose comment. It also underpins the end-of-stream trailing-pad guard: if the final padded
// chunk's VAD call throws, the pad was never baked into the counter, so subtracting it (as the code
// did before the fix) double-subtracts and pulls the last turn's end ~256ms early.
//
// Both are exercised here through the vadProcessor TEST SEAM on runStreamPipeline (a scripted VAD
// that throws on chosen chunks), driving the REAL pipeline + REAL ASR over REAL fixture speech so
// turns actually get emitted. The assertions read the force-finalize END boundary, which is computed
// straight from totalSamplesConsumed - so a wrongly-advanced counter shows up as the end epoch
// landing a clean, large multiple of 256ms away from truth, far outside tolerance. (Asserting "close
// to real audio" would NOT work here: a correct throw legitimately shifts the whole timeline 256ms
// early per throw - that benign shift is not the bug. The bug is counter DIVERGENCE, which the
// force-finalize end boundary isolates.)
//
// Run via: swift run meetingscribe --selftest-vadthrow

/// A scripted stand-in for VadManager.processStreamingChunk: throws on the given call indices and
/// emits a single speechStart on another, mimicking real VAD's contract that a throw happens BEFORE
/// processedSamples advances. State-thread only; the pipeline never inspects the returned state.
private final class ScriptedVad: @unchecked Sendable {
    private let lock = NSLock()
    private var call = 0
    private var processed = 0          // VAD's own frame: advances only on a NON-throwing call
    private let throwOn: Set<Int>
    private let speechStartOn: Int     // call index to emit speechStart at, or -1 for none

    init(throwOn: Set<Int>, speechStartOn: Int) {
        self.throwOn = throwOn
        self.speechStartOn = speechStartOn
    }

    func process(_ chunk: [Float], _ state: VadStreamState) throws -> VadStreamResult {
        lock.lock(); defer { lock.unlock() }
        let idx = call
        call += 1
        if throwOn.contains(idx) {
            // Real VAD throws inside processChunk, before the state machine advances processedSamples.
            throw VadError.modelProcessingFailed("scripted throw @\(idx)")
        }
        var event: VadStreamEvent?
        if idx == speechStartOn {
            event = VadStreamEvent(kind: .speechStart, sampleIndex: processed)
        }
        processed += chunk.count
        return VadStreamResult(state: state, event: event, probability: 1.0)
    }
}

private final class Collected: @unchecked Sendable {
    var turns: [FinalizedTurn] = []
    let lock = NSLock()
    func add(_ t: FinalizedTurn) { lock.lock(); turns.append(t); lock.unlock() }
}

func runSelfTestVadThrow() async throws {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-VADTHROW: FAIL - \(reason)")
        exit(1)
    }

    let sampleRate = 16000
    let chunkSize = VadManager.chunkSize // 4096
    let fixture = "testdata/test_meeting.wav"
    guard FileManager.default.fileExists(atPath: fixture) else {
        fail("fixture not found at \(fixture) - run this from the package root.")
    }
    let all = try AudioConverter().resampleAudioFile(path: fixture)

    err("Loading VAD + ASR models...")
    let vad = try await VadManager()      // only makeStreamState is used; vadProcessor overrides inference
    let asr = UnifiedAsrManager()
    try await asr.loadModels()

    // Feed `samples` into a fresh pipeline in EXACT chunkSize deliveries so processFixedChunk call
    // indices line up 1:1 with the scripted VAD's call counter. epochTime is set so firstChunkEpoch
    // resolves to 0 (epoch of sample 0), making expected end epochs a plain sampleIndex/sampleRate.
    func runPipeline(samples: [Float], script: ScriptedVad) async -> [FinalizedTurn] {
        let (stream, continuation) = AsyncStream<RawAudioChunk>.makeStream()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            continuation.yield(RawAudioChunk(
                samples: Array(samples[offset..<end]),
                epochTime: Double(end) / Double(sampleRate)   // firstChunkEpoch := 0
            ))
            offset = end
        }
        continuation.finish()

        let collected = Collected()
        await runStreamPipeline(
            speaker: "me", chunks: stream, vad: vad, asr: asr,
            vadProcessor: { chunk, state, _ in try script.process(chunk, state) }
        ) { turn in collected.add(turn) }
        return collected.turns
    }

    let tolerance = 0.030 // 30ms: far below the 256ms-multiples both bugs produce, above float noise.

    // --- Case A: desync lockstep -------------------------------------------------------------------
    // 11 full chunks, all real speech (the fixture's first utterance runs past 2.8s). Throw on calls
    // 1,2,3 (leading, before speech so the turn's audio stays contiguous), speechStart on call 4, no
    // speechEnd -> the turn is force-finalized at stream end using totalSamplesConsumed directly.
    //   correct: 3 throws don't advance the counter -> 8 consumed chunks -> end @ 8*4096/16000 = 2.048s
    //   broken (throw advances counter): 11 consumed -> end @ 11*4096/16000 = 2.816s (768ms late)
    let caseAChunks = 11
    guard all.count >= caseAChunks * chunkSize else {
        fail("fixture shorter than the \(caseAChunks * chunkSize) samples case A needs.")
    }
    let aSamples = Array(all[0..<(caseAChunks * chunkSize)])
    let aScript = ScriptedVad(throwOn: [1, 2, 3], speechStartOn: 4)
    let aTurns = await runPipeline(samples: aSamples, script: aScript)
    guard let aLast = aTurns.max(by: { $0.end < $1.end }) else {
        fail("case A emitted no turns - ASR returned nothing for the speech slice, so the end-boundary assertion could not run.")
    }
    let aExpectedEnd = Double((caseAChunks - 3) * chunkSize) / Double(sampleRate) // 2.048s
    let aErr = abs(aLast.end - aExpectedEnd)
    guard aErr < tolerance else {
        fail(String(format: "case A: force-finalized end epoch %.3fs, expected %.3fs (err %.3fs > %.3fs). 3 VAD throws advanced totalSamplesConsumed -> counter desynced from VAD's frame.",
                    aLast.end, aExpectedEnd, aErr, tolerance))
    }
    err(String(format: "SELFTEST-VADTHROW: PASS [desync-lockstep] - 3 mid-stream VAD throws kept the sample counter in lockstep; force-finalized end epoch %.3fs (expected %.3fs, a broken counter would land at %.3fs).",
               aLast.end, aExpectedEnd, Double(caseAChunks * chunkSize) / Double(sampleRate)))

    // --- Case B: trailing-pad double-subtraction ---------------------------------------------------
    // 6 full chunks + 1 leftover sample (real speech), speechStart on call 0, no throws in the main
    // loop, throw on the end-of-stream FINAL padded chunk (call index 6). The pad (4095 samples) was
    // never consumed, so:
    //   correct: guard zeroes trailingPadCount -> end @ 6*4096/16000 = 1.536s
    //   broken (always subtract pad): end @ (6*4096 - 4095)/16000 = 1.280s (256ms early)
    let bFullChunks = 6
    let bCount = bFullChunks * chunkSize + 1
    guard all.count >= bCount else { fail("fixture shorter than the \(bCount) samples case B needs.") }
    let bSamples = Array(all[0..<bCount])
    let bScript = ScriptedVad(throwOn: [bFullChunks], speechStartOn: 0) // call index 6 == the padded final chunk
    let bTurns = await runPipeline(samples: bSamples, script: bScript)
    guard let bLast = bTurns.max(by: { $0.end < $1.end }) else {
        fail("case B emitted no turns - ASR returned nothing, so the trailing-pad assertion could not run.")
    }
    let bExpectedEnd = Double(bFullChunks * chunkSize) / Double(sampleRate) // 1.536s
    let bErr = abs(bLast.end - bExpectedEnd)
    guard bErr < tolerance else {
        fail(String(format: "case B: last turn end epoch %.3fs, expected %.3fs (err %.3fs > %.3fs). A throw on the final padded chunk means the pad was never consumed; subtracting it double-subtracts and pulls the end early.",
                    bLast.end, bExpectedEnd, bErr, tolerance))
    }
    err(String(format: "SELFTEST-VADTHROW: PASS [trailing-pad-throw] - VAD throw on the final padded chunk did not double-subtract; last turn end epoch %.3fs (expected %.3fs, the double-subtract bug would land at %.3fs).",
               bLast.end, bExpectedEnd, Double(bFullChunks * chunkSize - (chunkSize - 1)) / Double(sampleRate)))

    err("SELFTEST-VADTHROW: PASS (all cases)")
    exit(0)
}
