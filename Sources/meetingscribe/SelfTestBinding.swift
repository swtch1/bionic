import Foundation

// MARK: - Automated verification of Diarize.swift's pure cluster->voiceprint binding decision.
//
// decideBinding is a pure function over (name, distance) pairs (no models/audio/IO), so like
// reconcileTurn it is exhaustively testable in-process. It is the higher-stakes half of diarize -
// a wrong bind puts a real person's name on the wrong turns - so these cases pin the load-bearing
// behaviors: a confident unambiguous bind, an ambiguous near-tie that must NOT guess, a lone
// candidate with no runner-up, bleed OVERRIDING a nearer colleague, and no-match-at-all.
//
// Run via: swift run meetingscribe --selftest-binding   (hidden subcommand, see main.swift)
func runSelfTestBinding() async throws {
    func fail(_ caseName: String, _ reason: String) -> Never {
        err("SELFTEST-BINDING: FAIL [\(caseName)] - \(reason)")
        exit(1)
    }
    func pass(_ caseName: String, _ detail: String) {
        err("SELFTEST-BINDING: PASS [\(caseName)] - \(detail)")
    }
    let dMe: Float = 0.45
    let margin: Float = 0.10

    // ---- Case 1: clean bind. Nearest named print is within dMe and clears the margin. ----
    do {
        let r = decideBinding(distances: [("alice", 0.30), ("bob", 0.60)], dMe: dMe, margin: margin)
        guard r == .bound("alice") else { fail("clean-bind", "expected .bound(alice), got \(r)") }
        pass("clean-bind", "alice 0.30 < dMe, 0.30 margin over bob -> bound alice")
    }

    // ---- Case 2: ambiguous near-tie. Nearest is within dMe but the runner-up is within margin,
    // so binding would be a guess -> must stay other:N (.unmatched). ----
    do {
        let r = decideBinding(distances: [("alice", 0.30), ("bob", 0.35)], dMe: dMe, margin: margin)
        guard r == .unmatched else { fail("ambiguous", "expected .unmatched (near-tie), got \(r)") }
        pass("ambiguous", "alice 0.30 vs bob 0.35 (0.05 < margin) -> unmatched, no guess")
    }

    // ---- Case 3: lone candidate, no runner-up. Below dMe with nothing to be ambiguous against. ----
    do {
        let r = decideBinding(distances: [("alice", 0.30)], dMe: dMe, margin: margin)
        guard r == .bound("alice") else { fail("no-runner-up", "expected .bound(alice), got \(r)") }
        pass("no-runner-up", "single candidate alice 0.30 < dMe -> bound alice")
    }

    // ---- Case 4: bleed overrides a NEARER colleague. me at 0.30 (< dMe) triggers bleed even though
    // alice is nearer at 0.28 - the cluster is more likely the user's own bleed than alice, and "me?"
    // is the review-reversible safe error. ----
    do {
        let r = decideBinding(distances: [("me", 0.30), ("alice", 0.28)], dMe: dMe, margin: margin)
        guard r == .bleed else { fail("bleed-overrides", "expected .bleed even with alice nearer, got \(r)") }
        pass("bleed-overrides", "me 0.30 < dMe -> bleed, overriding nearer alice 0.28")
    }

    // ---- Case 5: no match. Every print (incl. "me") is beyond dMe -> other:N. Margins are wide
    // (alice 0.60 vs bob 0.95) so the ONLY thing keeping this unmatched is the dMe gate, not an
    // ambiguity tie-break - a mutation that drops the dMe gate must flip this case. ----
    do {
        let r = decideBinding(distances: [("me", 0.90), ("alice", 0.60), ("bob", 0.95)], dMe: dMe, margin: margin)
        guard r == .unmatched else { fail("no-match", "expected .unmatched (all beyond dMe), got \(r)") }
        pass("no-match", "all prints >= dMe (incl. far me) -> unmatched, stays other:N")
    }

    // ---- Case 6: reserved bind target. A print literally named "other" is the nearest and well
    // within dMe, but binding to it would emit speaker:"other" - indistinguishable from an
    // unreconciled turn - so it must be EXCLUDED as a target and the cluster stays other:N. A
    // mutation that stops filtering reserved names would bind "other" and flip this. ----
    do {
        let r = decideBinding(distances: [("other", 0.10), ("alice", 0.80)], dMe: dMe, margin: margin)
        guard r == .unmatched else { fail("reserved-name", "expected .unmatched (reserved 'other' not a bind target), got \(r)") }
        pass("reserved-name", "nearest print named 'other' 0.10 excluded -> unmatched, no collision with diarize's labels")
    }

    err("SELFTEST-BINDING: PASS (all cases)")
    exit(0)
}
