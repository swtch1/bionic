import Foundation

// MARK: - Automated verification of the DER/WER math in QualityMetrics.swift.
//
// These metrics are about to become a regression GATE, so the metric itself has to be trustworthy
// first: a DER function that quietly returns 0 for everything would happily bless any future
// regression. Every expected value below is hand-computed from the frame arithmetic and stated in
// the comment next to it, so a failure tells you which property broke rather than just "number
// moved."
//
// Run via: swift run bionic --selftest-qualitymetrics
func runSelfTestQualityMetrics() async throws {
    var failures: [String] = []

    func check(_ label: String, _ got: Double, _ want: Double, tolerance: Double = 0.005) {
        if abs(got - want) > tolerance {
            failures.append("\(label): got \(String(format: "%.4f", got)), want \(String(format: "%.4f", want))")
        }
    }

    // ---------- DER ----------

    let refTwo = [
        TruthSegment(speaker: "alice", start: 0.0, end: 1.0, text: "a"),
        TruthSegment(speaker: "bob", start: 1.0, end: 2.0, text: "b"),
    ]

    // Perfect match -> 0.
    check("der/perfect", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "alice", start: 0.0, end: 1.0),
        HypSegment(speaker: "bob", start: 1.0, end: 2.0),
    ]), 0.0)

    // Labels permuted but boundaries identical -> still 0. This is the property that makes DER
    // meaningful at all: diarizer label names are arbitrary.
    check("der/relabeled", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "speaker_7", start: 0.0, end: 1.0),
        HypSegment(speaker: "speaker_3", start: 1.0, end: 2.0),
    ]), 0.0)

    // Both speakers merged into one label. 200 ref frames; the single hyp label can map to only one
    // reference speaker, so the other speaker's 100 frames are all confusion -> 100/200 = 0.5.
    check("der/merged-speakers", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "only", start: 0.0, end: 2.0),
    ]), 0.5)

    // Hypothesis covers only the first half: 100 of 200 ref frames are missed speech -> 0.5.
    check("der/half-missed", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "alice", start: 0.0, end: 1.0),
    ]), 0.5)

    // Empty hypothesis: everything missed -> 1.0.
    check("der/empty-hyp", QualityMetrics.der(reference: refTwo, hypothesis: []), 1.0)

    // False alarm: correct 200 frames plus 100 frames of speech where the reference is silent.
    // Errors are divided by REFERENCE speech (200), not by the union - so 100/200 = 0.5, and DER
    // can legitimately exceed... nothing here, but this pins the denominator choice.
    check("der/false-alarm", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "alice", start: 0.0, end: 1.0),
        HypSegment(speaker: "bob", start: 1.0, end: 2.0),
        HypSegment(speaker: "ghost", start: 3.0, end: 4.0),
    ]), 0.5)

    // Swapped speakers: both segments attributed to the wrong person. No injective mapping fixes
    // this (alice->bob and bob->alice IS injective and would make it 0) - so use a case that is
    // genuinely wrong: one speaker's turn given to the other, other turn correct.
    // ref: alice[0,1] bob[1,2]; hyp: alice[0,1] alice[1,2] is the merged case above, so instead
    // shift the boundary by 0.5s: alice[0,1.5] bob[1.5,2].
    // Frames 100..149 (50 frames) are ref=bob, hyp=alice -> 50/200 = 0.25.
    check("der/boundary-shift", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "alice", start: 0.0, end: 1.5),
        HypSegment(speaker: "bob", start: 1.5, end: 2.0),
    ]), 0.25)

    // Empty reference with a non-empty hypothesis is undefined-by-division; pinned to 1.0 rather
    // than crashing or returning 0 (which would read as "perfect").
    check("der/empty-ref", QualityMetrics.der(reference: [], hypothesis: [
        HypSegment(speaker: "x", start: 0.0, end: 1.0),
    ]), 1.0)
    check("der/both-empty", QualityMetrics.der(reference: [], hypothesis: []), 0.0)

    // A third invented speaker over a correct 2-speaker reference: frames 0..99 alice (correct),
    // 100..199 split bob[1.0,1.5] + ghost[1.5,2.0]; ghost cannot map to an unused ref label after
    // alice/bob are taken, so its 50 frames are errors -> 50/200 = 0.25.
    check("der/extra-speaker", QualityMetrics.der(reference: refTwo, hypothesis: [
        HypSegment(speaker: "alice", start: 0.0, end: 1.0),
        HypSegment(speaker: "bob", start: 1.0, end: 1.5),
        HypSegment(speaker: "ghost", start: 1.5, end: 2.0),
    ]), 0.25)

    // ---------- WER ----------

    check("wer/identical", QualityMetrics.wer(reference: "hello there world", hypothesis: "hello there world"), 0.0)
    // Casing and punctuation are normalized away by design.
    check("wer/normalized", QualityMetrics.wer(reference: "Hello, there world!", hypothesis: "hello there world"), 0.0)
    // One substitution out of three words.
    check("wer/one-sub", QualityMetrics.wer(reference: "hello there world", hypothesis: "hello their world"), 1.0 / 3.0)
    // One deletion out of three.
    check("wer/one-del", QualityMetrics.wer(reference: "hello there world", hypothesis: "hello world"), 1.0 / 3.0)
    // One insertion out of three.
    check("wer/one-ins", QualityMetrics.wer(reference: "hello there world", hypothesis: "hello there big world"), 1.0 / 3.0)
    // Nothing recognized at all -> 1.0.
    check("wer/empty-hyp", QualityMetrics.wer(reference: "hello there world", hypothesis: ""), 1.0)
    // WER above 1.0 is legitimate (insertions are unbounded): 3 ref words, 6 spurious insertions.
    let over = QualityMetrics.wer(reference: "a b c", hypothesis: "a b c d e f g h i")
    if over <= 1.0 {
        failures.append("wer/over-one: expected >1.0 for heavy insertion, got \(over)")
    }
    check("wer/empty-ref", QualityMetrics.wer(reference: "", hypothesis: "anything"), 1.0)
    check("wer/both-empty", QualityMetrics.wer(reference: "", hypothesis: ""), 0.0)

    guard failures.isEmpty else {
        err("SELFTEST-QUALITYMETRICS: FAIL")
        for f in failures { err("  - \(f)") }
        exit(1)
    }
    err("SELFTEST-QUALITYMETRICS: PASS - 10 DER cases + 9 WER cases against hand-computed values")
    exit(0)
}
