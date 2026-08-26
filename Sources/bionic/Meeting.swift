import Foundation

// MARK: - `meeting` subcommand: run a whole meeting from any directory.
//
// The orchestration itself stays in scripts/meeting.sh - it owns signal handling,
// the WAV-flush wait and the manifest gate, all of which were settled empirically.
// This is only an entry point, so it execs the script rather than reimplementing it.
//
// The script needs the repo (the feedback app's venv lives there), which an
// installed binary cannot infer from its own path. Hence repo_dir in config.

private func configValue(_ key: String) -> String? {
    let dir = ProcessInfo.processInfo.environment["BIONIC_CONFIG_DIR"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/bionic")
    let path = (dir as NSString).appendingPathComponent("config.yaml")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.hasPrefix("\(key):") else { continue }
        var v = String(line.dropFirst(key.count + 1))
        if let hash = v.firstIndex(of: "#") { v = String(v[v.startIndex..<hash]) }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }
    return nil
}

private func selfExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
    let path = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return (path as NSString).resolvingSymlinksInPath
}

func runMeeting() async {
    let args = Array(CommandLine.arguments.dropFirst(2))
    if args.first == "-h" || args.first == "--help" {
        err("usage: bionic meeting <title> [--session <dir>] [--no-live] [--no-diarize]")
        err("")
        err("Creates <meetings_dir>/<date>-<slug>/ and records into it, with the")
        err("feedback app live in this terminal. Ctrl-C stops and diarizes.")
        err("")
        err("Paths come from ~/.config/bionic/config.yaml (repo_dir, meetings_dir).")
        exit(0)
    }

    guard let repo = ProcessInfo.processInfo.environment["BIONIC_REPO"] ?? configValue("repo_dir") else {
        err("error: cannot locate the bionic repo, which holds scripts/meeting.sh and the")
        err("       feedback app's venv. Add it to ~/.config/bionic/config.yaml:")
        err("")
        err("         repo_dir: \"/path/to/bionic\"")
        err("")
        err("       or set BIONIC_REPO.")
        exit(2)
    }

    let script = (repo as NSString).appendingPathComponent("scripts/meeting.sh")
    guard FileManager.default.isExecutableFile(atPath: script) else {
        err("error: \(script) is missing or not executable (repo_dir = \(repo))")
        exit(2)
    }

    // A bare title is the whole point of the subcommand; the script wants --title.
    var passthrough = args
    var scriptArgs = [script]
    if let first = passthrough.first, !first.hasPrefix("-") {
        scriptArgs += ["--title", first]
        passthrough.removeFirst()
    }
    scriptArgs += passthrough

    // Hand the script THIS binary. Without it the installed copy would silently
    // defer to whatever sits in the repo's .build/release. argv[0] is just
    // "bionic" when found on PATH, so ask the kernel instead.
    setenv("BIONIC", selfExecutablePath(), 1)

    // execv preserves both the signal mask and any SIG_IGN dispositions. The Swift
    // runtime leaves SIGINT/SIGTERM blocked or ignored here and main.swift SIG_IGNs
    // SIGPIPE, so without this reset bash inherits a shell that cannot trap Ctrl-C -
    // and passes that same deafness to the capture and feedback children it spawns.
    var mask = sigset_t()
    sigemptyset(&mask)
    sigaddset(&mask, SIGINT)
    sigaddset(&mask, SIGTERM)
    sigaddset(&mask, SIGPIPE)
    sigprocmask(SIG_UNBLOCK, &mask, nil)
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
    signal(SIGPIPE, SIG_DFL)

    let argv: [UnsafeMutablePointer<CChar>?] = scriptArgs.map { strdup($0) } + [nil]
    execv(script, argv)
    err("error: could not exec \(script): \(String(cString: strerror(errno)))")
    exit(126)
}
