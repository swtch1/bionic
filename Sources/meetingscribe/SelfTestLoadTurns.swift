import Foundation

// MARK: - Automated verification of Diarize.swift's loadTurns parse census.
//
// loadTurns must NOT silently swallow malformed JSONL - a reconciliation tool that quietly drops
// turns degrades the "same seq 1:1" guarantee into "1:1 with whatever parsed". This pins the census
// it returns (parsed turns, total content lines, skipped count, first offending 1-based line number)
// so diarize can warn and, when a transcript is substantially broken, refuse.
//
// Run via: swift run meetingscribe --selftest-loadturns   (hidden subcommand, see main.swift)
func runSelfTestLoadTurns() async throws {
    func fail(_ caseName: String, _ reason: String) -> Never {
        err("SELFTEST-LOADTURNS: FAIL [\(caseName)] - \(reason)")
        exit(1)
    }
    func pass(_ caseName: String, _ detail: String) {
        err("SELFTEST-LOADTURNS: PASS [\(caseName)] - \(detail)")
    }

    // A transcript with two good turns, a blank line, and two unparseable lines interleaved. Line
    // numbers (1-based, blank counted): 1 good, 2 blank, 3 BAD, 4 good, 5 BAD.
    func good(_ seq: Int) -> String {
        #"{"seq":\#(seq),"start":100.0,"end":101.0,"speaker":"other","text":"hi","final":true,"conf":0.5}"#
    }
    let lines = [good(0), "", "{ this is not json", good(1), #"{"seq":2,"start":"oops"}"#]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("meetingscribe-loadturns-\(UUID().uuidString).jsonl")
    try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let load = try loadTurns(path: tmp.path)

    // ---- Case: the census counts skips instead of hiding them. ----
    guard load.turns.count == 2 else { fail("census", "expected 2 parsed turns, got \(load.turns.count)") }
    guard load.turns.map({ $0.seq }) == [0, 1] else { fail("census", "expected seqs [0,1], got \(load.turns.map { $0.seq })") }
    guard load.totalLines == 4 else { fail("census", "expected 4 content lines (blank excluded), got \(load.totalLines)") }
    guard load.skipped == 2 else { fail("census", "expected 2 skipped, got \(load.skipped)") }
    guard load.firstBadLine == 3 else { fail("census", "expected first bad line 3 (blank line counted), got \(load.firstBadLine ?? -1)") }
    pass("census", "2 parsed, 2 skipped, first bad at line 3 (blank counted) - loss is reported, not swallowed")

    err("SELFTEST-LOADTURNS: PASS (all cases)")
    exit(0)
}
