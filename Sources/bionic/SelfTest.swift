import Foundation

// MARK: - Automated verification of TurnMerger's start-time reordering.
//
// The live dual-stream path can't be exercised end-to-end by a subagent speaking into a mic
// AND controlling system audio in a meaningfully separated way, but the ORDERING/MERGE LOGIC
// itself (TurnMerger.swift) doesn't depend on where turns came from - it just needs two
// FinalizedTurns submitted out of start-time order. This exercises the EXACT production
// TurnMerger/TurnWriter/Turn types against a real temp file - not a test-only reimplementation.
//
// Two sub-cases, both submitting a LATER-start turn before an EARLIER-start one (simulating a
// system-audio turn finalizing before an earlier-started mic turn still mid-ASR):
//
//   Case A (coincident eligibility): the two submissions are ~0.05s apart, well under the
//   watermark, so BOTH turns cross watermark-eligibility on the SAME background flush tick and
//   get sorted together. This passes even against the OLD buggy flushReady - it's regression
//   coverage for the simple case, and by itself it is a FALSE NEGATIVE for the reorder bug.
//
//   Case B (staggered eligibility - the actual bug): the two turns cross watermark-eligibility on
//   DIFFERENT flush ticks. The later-start turn arrives first, so it becomes eligible on an earlier
//   tick than the earlier-start turn - but the earlier-start turn is already sitting in `pending`
//   by then (it arrived within the tick-granularity window before the later turn's next flush tick).
//   The OLD flushReady flushed only the currently-eligible subset, so it wrote the later-start turn
//   FIRST and the earlier-start turn on a subsequent tick - out of start-time order. The FIXED
//   flushReady flushes only the longest start-ordered prefix that is fully eligible, so it DEFERS
//   the eligible later turn until the earlier turn ahead of it also clears. Case B therefore FAILS
//   against the old logic and PASSES against the fix.
//
//   NOTE on "gap vs watermark": the driving task description framed Case B as "gap between
//   submissions LARGER than the watermark." Taken literally that is unsatisfiable against a correct
//   merger: if the earlier-start turn has not yet ARRIVED when the later turn is flushed, nothing -
//   old or new - can defer the later turn (the merger can't reorder around a turn it hasn't seen).
//   The real, testable requirement is that the two turns cross eligibility on DIFFERENT ticks (vs
//   Case A's same tick), with the earlier turn present in `pending` before the later turn's flush
//   tick. That is what Case B sets up; the submission gap ends up slightly below the watermark to
//   keep every timing margin >=150ms (see below).
//
// Watermark is 0.4s (deliberately larger than TurnMerger's fixed 0.25s flush-tick period, so a turn
// survives at least the first tick after arrival before becoming eligible - which is what gives
// Case B's earlier turn time to arrive, and keeps the first-tick margin ~150ms so the test can't
// flake if a tick drifts late under load). Production default is 1.5s (see TurnMerger's doc).
//
// Run via: swift run bionic --selftest-merge   (hidden subcommand, see main.swift dispatch)
func runSelfTestMerge() async throws {
    let watermark: TimeInterval = 0.4

    func fail(_ caseName: String, _ reason: String) -> Never {
        err("SELFTEST-MERGE: FAIL [\(caseName)] - \(reason)")
        exit(1)
    }

    // Drive one merge scenario end-to-end against the real types and return the decoded lines.
    // `drive` performs the submits/sleeps; we then wait out the watermark, flushAll, and read back.
    func runCase(
        _ caseName: String,
        drive: (TurnMerger) async throws -> Void
    ) async throws -> (turns: [Turn], startSeq: Int) {
        let tmpPath = NSTemporaryDirectory() + "bionic-selftest-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let (handle, startSeq) = openTurnOutput(outPath: tmpPath, appendFlag: false)
        let writer = TurnWriter(handle: handle, startSeq: startSeq)
        let merger = TurnMerger(writer: writer, watermark: watermark)

        try await drive(merger)

        // Let the background flush loop run through the ticks the scenario depends on, then flush
        // whatever remains. flushAll ignores the watermark but still emits in start-time order, so
        // it cannot by itself repair an out-of-order emission the periodic flushReady already made.
        try await Task.sleep(nanoseconds: UInt64((watermark + 0.6) * 1_000_000_000))
        await merger.flushAll()
        writer.close()

        guard let text = try? String(contentsOfFile: tmpPath, encoding: .utf8) else {
            fail(caseName, "could not read back \(tmpPath)")
        }
        let decoder = JSONDecoder()
        var turns: [Turn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let t = try? decoder.decode(Turn.self, from: Data(line.utf8)) else {
                fail(caseName, "a written line failed to decode as Turn: \(line)")
            }
            turns.append(t)
        }
        return (turns, startSeq)
    }

    // Shared assertions: exactly [early, late] in start order, monotonic seq, start < end.
    func assertOrdered(
        _ caseName: String,
        _ turns: [Turn],
        startSeq: Int,
        early: FinalizedTurn,
        late: FinalizedTurn
    ) {
        guard turns.count == 2 else { fail(caseName, "expected 2 written turns, got \(turns.count)") }
        guard turns[0].text == early.text else {
            fail(caseName, "start-time ordering violated: line 0 was '\(turns[0].text)', expected the earlier-starting ('\(early.text)') turn first")
        }
        guard turns[1].text == late.text else {
            fail(caseName, "start-time ordering violated: line 1 was '\(turns[1].text)', expected the later-starting ('\(late.text)') turn second")
        }
        guard turns[0].seq == startSeq, turns[1].seq == startSeq + 1 else {
            fail(caseName, "seq not monotonic from startSeq=\(startSeq): got \(turns[0].seq), \(turns[1].seq)")
        }
        for t in turns {
            guard t.start < t.end else { fail(caseName, "start >= end for a turn: \(t.start) >= \(t.end)") }
        }
    }

    let now = Date().timeIntervalSince1970

    // ---- Case A: coincident eligibility (regression coverage for the simple reorder). ----
    let aEarly = FinalizedTurn(speaker: "me", start: now + 2.0, end: now + 3.0, text: "A: starts earlier, finalizes SECOND")
    let aLate = FinalizedTurn(speaker: "other", start: now + 5.0, end: now + 6.0, text: "A: starts later, finalizes FIRST")
    let a = try await runCase("A/coincident") { merger in
        await merger.submit(aLate)
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05s << watermark: same eligibility tick
        await merger.submit(aEarly)
    }
    assertOrdered("A/coincident", a.turns, startSeq: a.startSeq, early: aEarly, late: aLate)
    err("SELFTEST-MERGE: PASS [A/coincident] - two turns submitted in reversed finalization order (0.05s apart), written in start-time order; seq \(a.turns[0].seq)-\(a.turns[1].seq)")

    // ---- Case B: staggered eligibility - the bug this component exists to prevent. ----
    // Timeline (watermark 0.4s, flush tick every 0.25s; ticks at ~0.25/0.50/0.75 from first submit):
    //   t=0.00  submit bLate  (start=5)          -> pending [late]
    //   t=0.25  tick: late age 0.25 < 0.40       -> not eligible, flush nothing (150ms margin)
    //   t=0.30  submit bEarly (start=2)          -> pending [late, early]
    //   t=0.50  tick: late age 0.50 eligible, early age 0.20 NOT (eligible only at 0.70)
    //           OLD  -> flushes late alone (out of order)  == the bug -> Case B FAILs old code
    //           FIX  -> start-sorted prefix [early, late] blocked at early -> flush nothing
    //   t=0.75  tick: both eligible -> FIX flushes [early, late] in start order -> PASS
    // Every margin is >=150ms, so the test can't flake if a tick drifts late under load.
    let bEarly = FinalizedTurn(speaker: "me", start: now + 2.0, end: now + 3.0, text: "B: starts earlier, arrives LATE")
    let bLate = FinalizedTurn(speaker: "other", start: now + 5.0, end: now + 6.0, text: "B: starts later, arrives FIRST")
    let b = try await runCase("B/staggered") { merger in
        await merger.submit(bLate)
        try await Task.sleep(nanoseconds: 300_000_000) // 0.30s: earlier turn arrives before late's flush tick
        await merger.submit(bEarly)
    }
    assertOrdered("B/staggered", b.turns, startSeq: b.startSeq, early: bEarly, late: bLate)
    err("SELFTEST-MERGE: PASS [B/staggered] - later-start turn (eligible first) deferred behind an earlier-start turn that arrived on a later tick; written in start-time order; seq \(b.turns[0].seq)-\(b.turns[1].seq)")

    err("SELFTEST-MERGE: PASS (all cases)")
    exit(0)
}
