import Foundation

// MARK: - REAL signal test: one SIGTERM must terminate a `listen` whose capture startup is wedged.
//
// The defect this guards: StopCoordinator SIG_IGNs SIGTERM so it can flush cleanly, but the
// graceful path only runs once runListen() reaches startupCompleteAndWait(). A startup blocked on
// a TCC prompt that can never be drawn never gets there, so `kill <pid>` used to be swallowed
// entirely - the request was recorded in actor state with nothing to consume it - and the process
// survived, silently, until SIGKILL. README promised `kill <pid>` always works.
//
// Must be a real child process taking a real signal: SIG_IGN, dispatch signal sources and exit()
// are all process-global, so an in-process simulation cannot exhibit the swallow.
//
// Anti-cheat: the child installs handlers through the SAME StopCoordinator.installHandlers()
// production uses - no inline copy - and the parent sends exactly ONE SIGTERM, never a SIGKILL
// fallback, so a pass means that single signal did the work.
//
// Run via: swift run bionic --selftest-stophang   (hidden; spawns --selftest-stophang-child)

/// The CHILD half, in two shapes selected by `--graceful`.
///
/// Default (wedged): installs the production stop handlers, then blocks its thread outright
/// without ever reaching startupCompleteAndWait() - exactly what `mic.start()` does while waiting
/// on a prompt nobody will ever see.
///
/// `--graceful`: reaches startupCompleteAndWait() first, standing the force-exit timer down. This
/// is the healthy path a real meeting takes, and it is here so the escape hatch can't be "fixed"
/// by simply killing every run.
func runSelfTestStopHangChild() async -> Never {
    let graceful = CommandLine.arguments.contains("--graceful")
    let stop = StopCoordinator()
    stop.installHandlers()
    FileHandle.standardOutput.write(Data("ARMED\n".utf8))
    guard graceful else { blockForeverSynchronously() }

    await stop.startupCompleteAndWait()
    // Stands in for runListen()'s flush: reached only via the graceful path, never the timer.
    FileHandle.standardOutput.write(Data("GRACEFUL\n".utf8))
    exit(0)
}

/// Blocks the calling thread outright, the way a `mic.start()` waiting on an undrawable TCC prompt
/// does. Not `Task.sleep`: that suspends and frees the cooperative thread, which is the opposite
/// of the condition under test.
private func blockForeverSynchronously() -> Never {
    DispatchSemaphore(value: 0).wait()
    fatalError("unreachable - nothing ever signals that semaphore")
}

/// The PARENT half. Spawns a child, waits for ARMED, sends exactly one SIGTERM, and asserts what
/// that single signal achieved - in both the wedged and the healthy case.
func runSelfTestStopHang() async throws {
    performStopHangTest()
}

private func performStopHangTest() {
    wedgedChildDiesOnOneSigterm()
    healthyChildStillFlushesOnOneSigterm()
    err("SELFTEST-STOPHANG: PASS (all cases)")
    exit(0)
}

private func fail(_ reason: String) -> Never {
    err("SELFTEST-STOPHANG: FAIL - \(reason)")
    exit(1)
}

/// The defect itself: one SIGTERM against a wedged startup must end the process.
private func wedgedChildDiesOnOneSigterm() {
    let child = spawnArmedChild(graceful: false)
    let sent = Date()
    kill(child.proc.processIdentifier, SIGTERM)

    // grace + generous margin for a loaded box. No SIGKILL fallback on the success path: if one
    // SIGTERM doesn't do it, the test must fail rather than paper over the defect by force.
    let deadline = StopCoordinator.forceExitGrace + 10
    guard child.waitForExit(within: deadline) else {
        let orphan = child.proc.processIdentifier
        kill(orphan, SIGKILL) // don't leak it, but the test has already failed
        fail("wedged child survived a single SIGTERM for \(Int(deadline))s - the signal was " +
             "swallowed by the wedged startup. This is the bug. (had to SIGKILL pid \(orphan))")
    }
    let elapsed = Date().timeIntervalSince(sent)

    // Teeth: it must have exited BY ITSELF via the force-exit path, not died of an uncaught
    // signal - an uncaught SIGTERM would mean SIG_IGN never took effect, so a healthy shutdown
    // would not flush either.
    guard child.proc.terminationReason == .exit else {
        fail("wedged child died of an uncaught signal rather than the force-exit path - SIGTERM " +
             "was not trapped, so a healthy shutdown would not flush either")
    }
    guard child.proc.terminationStatus == 130 else {
        fail("wedged child exited \(child.proc.terminationStatus), expected 130 from the force-exit path")
    }
    err(String(format: "SELFTEST-STOPHANG: PASS [wedged] - took ONE SIGTERM (no SIGKILL) and " +
               "force-exited 130 after %.1fs, within the %.0fs grace.",
               elapsed, StopCoordinator.forceExitGrace))
}

/// The other half of correct: the escape hatch must not have turned every SIGTERM into a kill.
/// A child that reached startupCompleteAndWait() must still run its flush and exit 0.
private func healthyChildStillFlushesOnOneSigterm() {
    let child = spawnArmedChild(graceful: true)
    kill(child.proc.processIdentifier, SIGTERM)

    // Deliberately longer than the grace period: if the timer fires against a healthy shutdown,
    // this waits long enough to catch it doing so.
    guard child.waitForExit(within: StopCoordinator.forceExitGrace + 10) else {
        kill(child.proc.processIdentifier, SIGKILL)
        fail("healthy child did not exit on SIGTERM - the graceful path is broken")
    }
    guard child.proc.terminationStatus == 0, child.proc.terminationReason == .exit else {
        fail("healthy child exited \(child.proc.terminationStatus) (reason " +
             "\(child.proc.terminationReason.rawValue)) - a SIGTERM after startup must flush and " +
             "exit 0, not be force-exited")
    }
    guard child.output().contains("GRACEFUL") else {
        fail("healthy child exited 0 without reaching its flush - shutdown skipped the work a real " +
             "run does after the wait returns")
    }
    err("SELFTEST-STOPHANG: PASS [healthy] - a SIGTERM after startup ran the flush and exited 0; " +
        "the force-exit timer stood down.")
}

private struct ArmedChild {
    let proc: Process
    private let sink: OutputSink

    init(proc: Process, sink: OutputSink) { self.proc = proc; self.sink = sink }

    func waitForExit(within seconds: TimeInterval) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        Thread { proc.waitUntilExit(); exited.signal() }.start()
        return exited.wait(timeout: .now() + seconds) != .timedOut
    }

    func output() -> String { sink.text() }
}

/// Spawns the child and returns only once it has printed ARMED, so the SIGTERM can never race
/// handler installation - a signal landing before the handlers exist would be taken by the OS
/// default and pass the wedged case for entirely the wrong reason.
private func spawnArmedChild(graceful: Bool) -> ArmedChild {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]) // this same built binary
    proc.arguments = ["--selftest-stophang-child"] + (graceful ? ["--graceful"] : [])
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = Pipe() // the force-exit notice is expected; keep it out of test output
    do { try proc.run() } catch { fail("could not spawn child: \(error)") }

    let sink = OutputSink()
    let sawArmed = DispatchSemaphore(value: 0)
    let reader = outPipe.fileHandleForReading
    Thread {
        var signalled = false
        while true {
            let d = reader.availableData
            if d.isEmpty { break } // EOF
            sink.append(d)
            if !signalled, sink.text().contains("ARMED") { signalled = true; sawArmed.signal() }
        }
        if !signalled { sawArmed.signal() } // child died before arming; caller checks below
    }.start()

    if sawArmed.wait(timeout: .now() + 30) == .timedOut {
        kill(proc.processIdentifier, SIGKILL)
        fail("child never reported ARMED within 30s")
    }
    guard sink.text().contains("ARMED") else {
        proc.waitUntilExit()
        fail("child exited before installing handlers - the test never reached the condition it checks")
    }
    return ArmedChild(proc: proc, sink: sink)
}

/// Accumulates the child's stdout from the reader thread while the main thread polls it.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
