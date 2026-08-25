import Foundation

// MARK: - Shutdown control for `listen`: the graceful Ctrl-C/SIGTERM path, plus the escape hatch
// that makes a stop signal work even when capture startup is wedged.
//
// The graceful path only becomes reachable once runListen() calls startupCompleteAndWait() -
// after model load and mic/ScreenCaptureKit init. Startup can block indefinitely, and the way it
// does is not exotic: a microphone TCC prompt raised by a process with no responsible GUI app
// (anything under a tmux server, which launchd reparents) is never drawn, so `engine.start()`
// simply never returns. Against that state a single `kill <pid>` used to do nothing observable -
// SIGTERM is SIG_IGN'd here, trigger() recorded the request in actor state, and nothing ever
// consumed it. The process was unkillable short of SIGKILL, silently.
//
// So the signal handler also checks, synchronously, whether startup finished, and arms a
// force-exit timer if it hasn't. That check and the timer run on GCD, never on the Swift
// concurrency pool: a synchronously-blocked `mic.start()` is sitting on a cooperative thread, and
// an escape hatch must not depend on the runtime it is escaping.
final class StopCoordinator: @unchecked Sendable {
    /// How long a stop signal received during startup waits for startup to finish before forcing
    /// the exit. Long enough for an almost-finished startup to reach the graceful path, far too
    /// short to sit through model loading - deliberately: Ctrl-C during a 10s model load should
    /// stop, not load to completion first.
    static let forceExitGrace: TimeInterval = 3

    private let stopSignal = StopSignal()
    private let lock = NSLock()
    private var startupFinished = false
    private var forceExitArmed = false
    /// Resumed dispatch sources must outlive installHandlers()'s frame or they are torn down
    /// while active.
    private var sources: [DispatchSourceSignal] = []

    /// Traps SIGINT and SIGTERM. Call BEFORE model loading and capture startup: installed later,
    /// an early Ctrl-C lands on the default terminate-immediately disposition instead.
    func installHandlers() {
        install(SIGINT, label: "bionic.sigint")
        install(SIGTERM, label: "bionic.sigterm")
    }

    /// SIGTERM gets the SAME graceful flush-and-exit as SIGINT. `kill <pid>` (and orderly logout/
    /// shutdown) sends it; on the OS default it would terminate immediately, losing the un-flushed
    /// audio buffer and skipping the final authoritative manifest.
    private func install(_ sig: Int32, label: String) {
        // SIG_IGN suppresses terminate-immediately so this handler, not the OS, decides when the
        // process exits - after flushing and closing the output file.
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: label))
        // Strong capture, deliberately: this makes a reference cycle (coordinator -> source ->
        // closure -> coordinator) and that is the correct lifetime. The handlers must keep working
        // for the whole process, including during shutdown - a second Ctrl-C mid-flush is a
        // documented escape hatch. Under `[weak self]` the coordinator can be released once
        // runListen() makes its last reference to it, which is the `await` at the START of
        // shutdown; every signal after that point would find a nil self and be dropped silently.
        source.setEventHandler {
            Task { await self.stopSignal.trigger() }
            self.armForceExitIfStartupWedged()
        }
        source.resume()
        sources.append(source)
    }

    private func armForceExitIfStartupWedged() {
        lock.lock()
        let wedged = !startupFinished && !forceExitArmed
        if wedged { forceExitArmed = true }
        lock.unlock()
        guard wedged else { return }

        err("""
            Stop requested before capture startup finished. If no permission dialog ever appeared, \
            this process has no responsible GUI app to draw one - see README, "Permissions". \
            Forcing exit in \(Int(Self.forceExitGrace))s unless startup completes first.
            """)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.forceExitGrace) {
            self.lock.lock()
            let finished = self.startupFinished
            self.lock.unlock()
            guard !finished else { return } // graceful shutdown got there; let it flush
            // Deliberately does not claim nothing was captured. The usual wedge is in mic or
            // system-audio start, where that is true - but the window also covers the moments
            // after both captures go live, when `--record` may already have real audio on disk
            // (headers patched incrementally, manifest not finalized). `diarize` handles that
            // case; telling the user it was empty would invite them to delete it.
            err("Capture startup did not finish - forcing exit.")
            exit(130)
        }
    }

    /// Marks capture startup finished and blocks until a stop signal arrives. One call, not two:
    /// the instant the graceful path is reachable, the force-exit timer must stand down, and
    /// splitting them leaves a window where a signal arms a timer that then kills a healthy flush.
    func startupCompleteAndWait() async {
        markStartupFinished()
        await stopSignal.wait()
    }

    // Separate only because NSLock is unavailable from an async context; keeping it private
    // preserves the "one call" contract above.
    private func markStartupFinished() {
        lock.lock()
        startupFinished = true
        lock.unlock()
    }
}

/// Bridges a synchronous, signal-safety-constrained C signal handler into async/await: the
/// handler itself stays minimal (just spawns a Task), and runListen() awaits `wait()` to learn
/// when to begin shutdown.
actor StopSignal {
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func trigger() {
        // Second Ctrl-C -> hard exit, immediately. During a wedged startup StopCoordinator's timer
        // already guarantees the process dies within a few seconds; this is the impatient path for
        // an operator who doesn't want to wait for it.
        // Tradeoff: a reflexive double-tap during a HEALTHY shutdown force-exits mid-flush. That's
        // acceptable - writes are one direct write() syscall per line, so at worst an un-flushed
        // in-progress turn is lost; no already-written line is ever torn.
        if stopped {
            err("\nSecond interrupt - forcing exit.")
            exit(130)
        }
        stopped = true
        for w in waiters { w.resume() }
        waiters = []
    }

    func wait() async {
        if stopped { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }
}
