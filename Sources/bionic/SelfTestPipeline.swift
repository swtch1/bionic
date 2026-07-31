import Foundation
import FluidAudio

// MARK: - Automated regression test for runStreamPipeline's turn-boundary timestamping.
//
// runStreamPipeline is deliberately agnostic to where its audio came from (TurnPipeline.swift's
// module doc), which is exactly what makes it testable without a microphone: this drives the REAL
// pipeline - real VadManager, real UnifiedAsrManager, real RawAudioChunk shape - off a recorded
// fixture instead of a capture adapter. Only the audio source is synthetic.
//
// WHAT IT PINS DOWN: the end-of-stream force-finalize path. When a stream ends mid-utterance (no
// trailing silence, so VAD never fires speechEnd), the pipeline pads the trailing partial chunk up
// to VadManager.chunkSize by repeating the last sample, feeds it through VAD, and then force-
// finalizes the in-progress turn. Those padded samples never existed. If the finalize boundary
// counts them, the emitted turn's `end` epoch overshoots the real audio by up to one chunk
// (4096 samples = 256ms @ 16kHz) and ASR is handed a synthetic repeated-sample tail as real audio.
//
// The fixture is truncated MID-UTTERANCE and to a deliberately non-chunk-aligned length, because
// both conditions are required to reach the path at all: end during silence and VAD emits a normal
// speechEnd (real boundary, no padding involved); end on a chunk boundary and there is nothing to
// pad. A test that skipped either would pass against the bug.
//
// Run via: swift run bionic --selftest-pipeline   (hidden subcommand, see main.swift)
func runSelfTestPipeline() async throws {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-PIPELINE: FAIL - \(reason)")
        exit(1)
    }

    let sampleRate = 16000
    let fixture = "testdata/test_meeting.wav"
    guard FileManager.default.fileExists(atPath: fixture) else {
        fail("fixture not found at \(fixture) - run this from the package root.")
    }

    let all = try AudioConverter().resampleAudioFile(path: fixture)

    // Truncate to (a whole number of chunks + 1 sample). Two things are load-bearing here:
    //
    //   - It lands ~2.8s in, inside the fixture's first utterance (which runs to ~4.7s), so the
    //     stream ends with speech still in progress and VAD never fires a natural speechEnd. That
    //     is the only way to reach the force-finalize path at all.
    //   - The +1 leaves exactly ONE leftover sample, so the trailing chunk is padded with
    //     chunkSize-1 (4095) phantom samples - the MAXIMUM. This is not incidental: the overshoot
    //     the bug produces equals the pad size, so a truncation that happens to leave a nearly-full
    //     partial chunk pads only a handful of samples and the regression hides under any sane
    //     tolerance. Verified: at 3s+1000 samples the pad is 152 samples (~0.010s) and this test
    //     passes even WITH the bug reintroduced. Maximizing the pad is what gives it teeth.
    let realSampleCount = 11 * VadManager.chunkSize + 1
    guard all.count >= realSampleCount else {
        fail("fixture is shorter than the \(realSampleCount)-sample truncation point this test needs.")
    }
    guard realSampleCount % VadManager.chunkSize != 0 else {
        fail("truncation point is chunk-aligned - it would not exercise the padding path.")
    }
    let samples = Array(all[0..<realSampleCount])

    err("Loading VAD + ASR models...")
    let vad = try await VadManager()
    let asr = UnifiedAsrManager()
    try await asr.loadModels()

    // Feed the fixture in capture-sized pieces, stamping each with the epochTime a real adapter
    // would have used: the wall-clock instant that piece finished arriving. The pipeline anchors
    // its time base off the first chunk and dead-reckons from the sample count, so these stamps
    // fully determine every emitted timestamp.
    let deliverySize = 4096
    let base = Date().timeIntervalSince1970
    let (stream, continuation) = AsyncStream<RawAudioChunk>.makeStream()
    var offset = 0
    while offset < samples.count {
        let end = min(offset + deliverySize, samples.count)
        continuation.yield(RawAudioChunk(
            samples: Array(samples[offset..<end]),
            epochTime: base + Double(end) / Double(sampleRate)
        ))
        offset = end
    }
    continuation.finish()

    // epoch(sample 0) as the pipeline computes it: the first chunk's stamp minus its own duration.
    let epochAtSampleZero = base + Double(min(deliverySize, samples.count)) / Double(sampleRate)
        - Double(min(deliverySize, samples.count)) / Double(sampleRate)
    let lastRealSampleEpoch = epochAtSampleZero + Double(realSampleCount) / Double(sampleRate)

    final class Collected: @unchecked Sendable {
        var turns: [FinalizedTurn] = []
        let lock = NSLock()
        func add(_ t: FinalizedTurn) { lock.lock(); turns.append(t); lock.unlock() }
    }
    let collected = Collected()

    await runStreamPipeline(speaker: "me", chunks: stream, vad: vad, asr: asr) { turn in
        collected.add(turn)
    }

    let turns = collected.turns
    guard !turns.isEmpty else {
        fail("pipeline emitted no turns for \(realSampleCount) samples of speech - the force-finalize path did not run, so this test proved nothing.")
    }
    guard let last = turns.max(by: { $0.end < $1.end }) else { fail("unreachable") }

    // The real assertion. Tolerance is 20ms - comfortably above float/rounding noise and far below
    // the 256ms (one full padded chunk) overshoot the bug produces, so it cannot pass by accident.
    let overshoot = last.end - lastRealSampleEpoch
    let tolerance = 0.02
    guard overshoot <= tolerance else {
        fail(String(
            format: "final turn's end epoch overshoots the last REAL audio sample by %.3fs (tolerance %.3fs). The trailing partial chunk's padding is being counted as real audio in the force-finalize boundary.",
            overshoot, tolerance))
    }

    err(String(format: "SELFTEST-PIPELINE: PASS [trailing-pad] - %d turn(s) from a mid-utterance truncation; final end epoch within %.3fs of the last real sample (overshoot %.3fs, one padded chunk would be %.3fs).",
               turns.count, tolerance, overshoot, Double(VadManager.chunkSize) / Double(sampleRate)))
    err("SELFTEST-PIPELINE: PASS (all cases)")
    exit(0)
}
