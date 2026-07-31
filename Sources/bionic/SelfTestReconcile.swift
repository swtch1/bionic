import Foundation

// MARK: - Automated verification of Reconcile.swift's pure overlap decision.
//
// reconcileTurn is a pure function over plain structs (no models/audio/IO), so unlike the capture
// path it is exhaustively testable in-process. These cases pin down the load-bearing behaviors:
// exact single-speaker alignment, one turn spanning two speakers (majority label + disclosed
// split, never a split turn), no diarizer overlap, a coverage miss, and a small-skew regression
// that a naive equality-based aligner would get wrong.
//
// Run via: swift run bionic --selftest-reconcile   (hidden subcommand, see main.swift)
func runSelfTestReconcile() async throws {
    func fail(_ caseName: String, _ reason: String) -> Never {
        err("SELFTEST-RECONCILE: FAIL [\(caseName)] - \(reason)")
        exit(1)
    }
    func pass(_ caseName: String, _ detail: String) {
        err("SELFTEST-RECONCILE: PASS [\(caseName)] - \(detail)")
    }
    func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    // ---- Case 1: exact alignment. One cluster covers the whole turn -> assigned, conf 1.0. ----
    do {
        let turn = ReconInterval(start: 100, end: 105)
        let clusters = [DiarCluster(label: "other:1", segments: [ReconInterval(start: 100, end: 105)])]
        let r = reconcileTurn(turn: turn, clusters: clusters)
        guard r.speaker == "other:1" else { fail("exact-alignment", "expected other:1, got \(r.speaker)") }
        guard r.reason == nil else { fail("exact-alignment", "expected no reason, got \(r.reason ?? "nil")") }
        guard approx(r.conf, 1.0) else { fail("exact-alignment", "expected conf 1.0, got \(r.conf)") }
        guard r.speakers == nil else { fail("exact-alignment", "expected no speakers split, got one") }
        pass("exact-alignment", "single cluster fully covers the turn -> other:1, conf 1.0")
    }

    // ---- Case 2: one turn, two speakers. 3s of cluster1 + 2s of cluster2 over a 5s turn. ----
    // purity = 3/5 = 0.60 (meets the 0.60 gate), coverage = 5/5 = 1.0 -> assign majority (other:1),
    // conf = 0.60. Runner-up share = 2/5 = 0.40 >= 0.15 -> speakers split disclosed. Whole turn,
    // never split.
    do {
        let turn = ReconInterval(start: 0, end: 5)
        let clusters = [
            DiarCluster(label: "other:1", segments: [ReconInterval(start: 0, end: 3)]),
            DiarCluster(label: "other:2", segments: [ReconInterval(start: 3, end: 5)]),
        ]
        let r = reconcileTurn(turn: turn, clusters: clusters)
        guard r.speaker == "other:1" else { fail("two-speakers", "expected majority other:1, got \(r.speaker)") }
        guard approx(r.conf, 0.60) else { fail("two-speakers", "expected conf 0.60, got \(r.conf)") }
        guard let sp = r.speakers, sp.count == 2 else { fail("two-speakers", "expected a 2-way speakers split") }
        guard sp[0].speaker == "other:1", approx(sp[0].share, 0.6), approx(sp[1].share, 0.4) else {
            fail("two-speakers", "expected shares [other:1=0.6, other:2=0.4], got \(sp)")
        }
        pass("two-speakers", "5s turn split 3:2 -> whole turn labeled majority other:1, split disclosed")
    }

    // ---- Case 3: zero overlap. Cluster speaks entirely outside the turn -> keep "other". ----
    do {
        let turn = ReconInterval(start: 0, end: 5)
        let clusters = [DiarCluster(label: "other:1", segments: [ReconInterval(start: 10, end: 15)])]
        let r = reconcileTurn(turn: turn, clusters: clusters)
        guard r.speaker == "other" else { fail("zero-overlap", "expected other, got \(r.speaker)") }
        guard r.reason == "no_diar_overlap" else { fail("zero-overlap", "expected no_diar_overlap, got \(r.reason ?? "nil")") }
        guard approx(r.conf, 0) else { fail("zero-overlap", "expected conf 0, got \(r.conf)") }
        pass("zero-overlap", "cluster outside the turn -> kept other, no_diar_overlap")
    }

    // ---- Case 4: low coverage. One pure cluster overlaps only 2s of a 5s turn. ----
    // purity = 1.0 (single cluster), coverage = 2/5 = 0.40 < 0.50 -> keep "other", low_coverage.
    do {
        let turn = ReconInterval(start: 0, end: 5)
        let clusters = [DiarCluster(label: "other:1", segments: [ReconInterval(start: 0, end: 2)])]
        let r = reconcileTurn(turn: turn, clusters: clusters)
        guard r.speaker == "other" else { fail("low-coverage", "expected other, got \(r.speaker)") }
        guard r.reason == "low_coverage" else { fail("low-coverage", "expected low_coverage, got \(r.reason ?? "nil")") }
        guard approx(r.conf, 0.40) else { fail("low-coverage", "expected conf 0.40, got \(r.conf)") }
        pass("low-coverage", "pure but only 40% covered -> kept other, low_coverage")
    }

    // ---- Case 5: 256ms-skew regression. The diarizer segment is offset by exactly one VAD chunk
    // (4096 samples @ 16kHz = 0.256s) from the turn - the same skew a single VAD-desync chunk
    // introduces. A correct overlap-based aligner still assigns the cluster (overlap is huge); an
    // aligner that matched on boundary equality would fail. Turn 0..5, segment 0.256..5.256:
    // overlap = 5 - 0.256 = 4.744; coverage = 4.744/5 = 0.9488, purity = 1.0, conf = 0.9488.
    do {
        let skew = Double(4096) / 16000.0
        let turn = ReconInterval(start: 0, end: 5)
        let clusters = [DiarCluster(label: "other:1", segments: [ReconInterval(start: skew, end: 5 + skew)])]
        let r = reconcileTurn(turn: turn, clusters: clusters)
        guard r.speaker == "other:1" else { fail("skew-256ms", "expected other:1 despite 256ms skew, got \(r.speaker)") }
        let expectedConf = (5 - skew) / 5
        guard approx(r.conf, expectedConf, 1e-6) else { fail("skew-256ms", "expected conf \(expectedConf), got \(r.conf)") }
        pass("skew-256ms", "one-chunk (256ms) skew still aligns via overlap -> other:1, conf ~\(String(format: "%.3f", expectedConf))")
    }

    err("SELFTEST-RECONCILE: PASS (all cases)")
    exit(0)
}
