import Foundation

// MARK: - TurnWriter: the ONE place that ever advances `seq` or writes to the output JSONL file
// for the live `listen` path. Wraps the same output mechanics run() uses inline (JSONEncoder ->
// Turn -> newline-terminated direct write() + stdout echo) so the two subcommands' emitted lines
// are byte-for-byte the same shape, without run()'s per-turn loop being touched at all.
//
// @unchecked Sendable: this class holds mutable state (`seq`, `emittedCount`) and a non-Sendable
// FileHandle, but it is only ever constructed once per `listen` invocation and only ever mutated
// from within TurnMerger's actor-isolated methods (submit/flushReady/flushAll), which serialize
// all access by construction - there is exactly one writer, never shared/called concurrently
// from anywhere else.
final class TurnWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var seq: Int
    private(set) var emittedCount = 0

    init(handle: FileHandle, startSeq: Int) {
        self.handle = handle
        self.seq = startSeq
    }

    /// Encode + append one finalized turn. Advances seq only on success - same "one bad turn must
    /// not corrupt seq numbering" contract run() upholds in main.swift.
    ///
    /// `conf` is hardcoded to 1.0: intentional, not a placeholder. The live path's speaker label
    /// is structural (which capture stream the audio arrived on - mic vs. system audio), not
    /// inferred from a voiceprint distance threshold, so there is no attribution ambiguity left
    /// to express a lower confidence over (contrast with run()'s cosineDistance-derived conf).
    func write(_ turn: FinalizedTurn) {
        let start = round2(turn.start)
        var end = round2(turn.end)
        if !(start < end) { end = start + 0.01 } // guarantee start < end, same as run()

        let record = Turn(
            seq: seq,
            start: start,
            end: end,
            speaker: turn.speaker,
            text: turn.text,
            final: true,
            conf: 1.0
        )
        do {
            let json = try encoder.encode(record)
            // write(contentsOf:) not write(_:) - see the matching note in main.swift's run():
            // the non-throwing overload raises an uncatchable NSException on I/O failure.
            try handle.write(contentsOf: json + Data([0x0A]))
            if let s = String(data: json, encoding: .utf8) { print(s) } // echo for live visibility
            seq += 1
            emittedCount += 1
        } catch {
            err("listen: turn failed to encode (speaker=\(turn.speaker), \(turn.start)-\(turn.end)): \(error) - skipping, not advancing seq.")
        }
    }

    func close() {
        try? handle.close()
    }
}

// MARK: - TurnMerger: reorders finalized turns from the two independent per-stream pipelines
// (mic -> "me", system-audio -> "other") into start-time order before handing them to the
// single TurnWriter/seq counter.
//
// WHY this exists: each stream's pipeline (TurnPipeline.swift) finalizes turns independently and
// asynchronously - VAD hangover plus per-turn ASR latency differ between the two streams, so a
// turn that STARTED later can FINISH (finalize) before one that started earlier. Appending in
// raw finalization order would still be seq-monotonic and contract-valid, but would jumble
// conversation order in a way that's confusing for a consumer/human reading the transcript.
//
// MECHANISM - bounded watermark delay: each finalized turn is held for `watermark` seconds of
// wall-clock time (measured from when the MERGER received it, not from the turn's own start)
// before it becomes eligible to flush. A background loop flushes all currently-eligible turns
// together, in ascending `start` order, every ~250ms. This is a bounded-delay heuristic, not a
// proof of correctness:
//   - too SHORT a watermark: more reordering slips through under load (slow ASR, CPU
//     contention, a long turn on one stream while the other finalizes several short ones).
//   - too LONG a watermark: every turn incurs up to `watermark` extra seconds of latency before
//     the consumer (the Python feedback app) ever sees it, even in the common well-behaved case
//     where no reordering was ever going to happen.
// Default `watermark = 1.5s`: bigger than typical VAD hangover (minSilenceDuration default 0.75s
// + speechPadding 0.1s ~= 0.85s) plus a margin for ASR-latency skew between the two streams,
// without adding multi-second lag to live turn delivery. Tune per how much reordering vs.
// latency the consumer can tolerate - there is no universally-correct value.
//
// At shutdown (flushAll), ALL buffered turns are flushed immediately in start-time order,
// watermark or not: once both capture streams have stopped, no further turns can ever arrive,
// so waiting out the watermark can't reveal anything new - flushing immediately is strictly
// correct at that point, not just an approximation.
actor TurnMerger {
    private struct Pending {
        let turn: FinalizedTurn
        let receivedAt: Date
    }

    private var pending: [Pending] = []
    private let watermark: TimeInterval
    private let writer: TurnWriter
    private var flushLoopTask: Task<Void, Never>?
    private var flushLoopStarted = false

    init(writer: TurnWriter, watermark: TimeInterval = 1.5) {
        self.writer = writer
        self.watermark = watermark
    }

    // Started lazily (on first submit/flushAll) rather than from init: an actor init cannot
    // spawn a Task capturing `self` and then keep assigning stored properties afterward (Swift
    // reports "cannot access property here in nonisolated initializer" - once a closure captures
    // self, init treats self as having escaped). Starting it as a normal actor-isolated method
    // call, after init has fully returned, sidesteps that restriction entirely.
    private func ensureFlushLoopStarted() {
        guard !flushLoopStarted else { return }
        flushLoopStarted = true
        flushLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self?.flushReady()
            }
        }
    }

    /// Called by each stream's pipeline when it finalizes a turn.
    func submit(_ turn: FinalizedTurn) {
        ensureFlushLoopStarted()
        pending.append(Pending(turn: turn, receivedAt: Date()))
    }

    // Flush the longest *start-ordered prefix* of pending turns that are ALL watermark-eligible.
    //
    // A naive "flush every eligible turn now" is WRONG: a later-start turn can become eligible on a
    // tick where an earlier-start turn is still sub-watermark (it arrived more recently), so the
    // later turn would be written BEFORE the earlier one - the exact reordering this component
    // exists to prevent. Eligibility crossing on the same tick only coincidentally sorts two turns
    // together; it depends on their arrival gap vs. the tick period, not on the watermark size, so a
    // bigger watermark does not fix it.
    //
    // Correct rule: sort ALL pending by start, then flush the longest leading run in which every
    // turn is itself eligible. The first not-yet-eligible turn (in start order) stops the flush -
    // every turn at or after it stays pending, including later-start turns that ARE already eligible,
    // because emitting them now would jump ahead of an earlier-start turn still in the buffer.
    //
    // This defers an eligible later turn until the earlier turns ahead of it clear. A long
    // earlier-start turn that keeps others waiting still flushes once it too crosses the watermark
    // (bounded by its own receivedAt), so pending drains - it never deadlocks.
    private func flushReady() {
        guard !pending.isEmpty else { return }
        let now = Date()
        let sorted = pending.sorted(by: { $0.turn.start < $1.turn.start })
        var prefixCount = 0
        for p in sorted {
            guard now.timeIntervalSince(p.receivedAt) >= watermark else { break }
            prefixCount += 1
        }
        guard prefixCount > 0 else { return }
        let toFlush = Array(sorted[..<prefixCount])
        pending = Array(sorted[prefixCount...])
        writeInStartOrder(toFlush)
    }

    /// Flush everything buffered right now, in start-time order, ignoring the watermark.
    /// Correct ONLY once no more turns can arrive (both stream pipelines have stopped) - callers
    /// must await both pipeline Tasks to completion before calling this (see Listen.swift).
    func flushAll() {
        flushLoopTask?.cancel()
        flushLoopTask = nil
        let all = pending
        pending = []
        writeInStartOrder(all)
    }

    /// The one place turns reach the writer: always start-time-sorted, so both the periodic
    /// watermark flush and the final shutdown flush emit in identical (start-ascending) order.
    private func writeInStartOrder(_ items: [Pending]) {
        for p in items.sorted(by: { $0.turn.start < $1.turn.start }) {
            writer.write(p.turn)
        }
    }
}
