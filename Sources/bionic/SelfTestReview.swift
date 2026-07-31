import Foundation

// MARK: - Automated verification of review's two data-safety properties.
//
// review REWRITES transcript.diarized.jsonl in place, so two things must hold or an interactive
// relabel silently destroys data:
//   1. loadDiarizedTurns must COUNT unparseable lines (not silently skip), so review can refuse
//      rather than rewrite a truncated file. Same census as diarize's loadTurns, stricter policy.
//   2. writeDiarized must be ATOMIC (temp file + rename), so a crash or full disk mid-write never
//      leaves a half-written transcript where a complete one used to be. A rename installs a NEW
//      inode over the target; an in-place truncating write keeps the same inode - so the inode
//      changing across a rewrite is the observable signature of atomicity.
//
// Run via: swift run bionic --selftest-review   (hidden subcommand, see main.swift)
func runSelfTestReview() async throws {
    func fail(_ caseName: String, _ reason: String) -> Never {
        err("SELFTEST-REVIEW: FAIL [\(caseName)] - \(reason)")
        exit(1)
    }
    func pass(_ caseName: String, _ detail: String) {
        err("SELFTEST-REVIEW: PASS [\(caseName)] - \(detail)")
    }

    let fm = FileManager.default

    // ---- Case 1: loadDiarizedTurns census. 2 good, 1 blank, 2 malformed. Lines (1-based, blank
    // counted): 1 good, 2 blank, 3 BAD, 4 good, 5 BAD. ----
    do {
        func good(_ seq: Int) -> String {
            #"{"seq":\#(seq),"start":100.0,"end":101.0,"speaker":"other:1","text":"hi","final":true,"conf":0.9}"#
        }
        let lines = [good(0), "", "{ not json", good(1), #"{"seq":2,"speaker":42}"#]
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bionic-review-census-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }

        let load = try loadDiarizedTurns(path: tmp.path)
        guard load.turns.count == 2 else { fail("census", "expected 2 parsed, got \(load.turns.count)") }
        guard load.totalLines == 4 else { fail("census", "expected 4 content lines, got \(load.totalLines)") }
        guard load.skipped == 2 else { fail("census", "expected 2 skipped, got \(load.skipped)") }
        guard load.firstBadLine == 3 else { fail("census", "expected first bad line 3, got \(load.firstBadLine ?? -1)") }
        pass("census", "2 parsed, 2 skipped, first bad at line 3 - loss is counted, not swallowed")
    }

    // ---- Case 2: writeDiarized is atomic (rewrite installs a new inode). ----
    do {
        func turn(_ seq: Int, _ text: String) -> DiarizedTurn {
            DiarizedTurn(seq: seq, start: 100.0, end: 101.0, speaker: "other:1", text: text, final: true,
                         conf: 0.9, speakers: nil, bleed: nil, reason: nil, boundBy: nil)
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bionic-review-atomic-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: tmp) }

        try writeDiarized([turn(0, "first")], to: tmp, inSessionDir: false)
        let inode1 = (try fm.attributesOfItem(atPath: tmp.path)[.systemFileNumber] as? Int) ?? -1

        try writeDiarized([turn(0, "first"), turn(1, "second")], to: tmp, inSessionDir: false)
        let inode2 = (try fm.attributesOfItem(atPath: tmp.path)[.systemFileNumber] as? Int) ?? -2

        guard inode1 > 0, inode2 > 0 else { fail("atomic", "could not read inode(s): \(inode1), \(inode2)") }
        guard inode1 != inode2 else {
            fail("atomic", "inode unchanged (\(inode1)) across rewrite - the write is in-place, not temp+rename, so a crash mid-write could truncate the file")
        }
        // And the rewrite actually landed the new content.
        let reread = try loadDiarizedTurns(path: tmp.path)
        guard reread.turns.count == 2, reread.turns.map({ $0.text }) == ["first", "second"] else {
            fail("atomic", "rewrite content wrong: \(reread.turns.map { $0.text })")
        }
        pass("atomic", "rewrite installed a new inode (\(inode1) -> \(inode2)) and landed the new content -> temp+rename, crash-safe")
    }

    err("SELFTEST-REVIEW: PASS (all cases)")
    exit(0)
}
