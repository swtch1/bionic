import AVFoundation
import CExceptionCatcher
import Foundation

// MARK: - Automated verification that safeInstallTap survives AVFoundation's NSException.
//
// The bug this guards: AVAudioNode's tap API RAISES an Objective-C NSException on misuse instead of
// returning an error. Swift's do/catch cannot see it, so uncaught it hits
// `libc++abi: terminating due to uncaught exception of type NSException` and takes the whole
// process down - losing an in-progress meeting recording rather than one turn.
//
// Verifying this REQUIRES actually raising the exception: a mocked-out version would prove nothing
// about whether the @try/@catch shim is wired to the real call. The pass condition is therefore
// partly the assertions below and partly the fact that this process is still alive to print them -
// without the shim, this test would CRASH rather than fail.
//
// Trigger choice, established empirically (see the notes on each case): an out-of-range bus index
// raises reliably with no audio hardware and no microphone permission. Notably, a channel-count or
// sample-rate MISMATCH does NOT raise on a mixer node - AVAudioEngine silently downmixes and
// resamples for mixer taps - so a mismatch test here would pass vacuously. The production risk
// safeInstallTap covers on the engine's INPUT node (a stale hardware format after a device change)
// is a different trigger for the same NSException mechanism; the shim is format-agnostic, so
// exercising the mechanism is what matters, but this test does NOT itself reproduce the
// input-node-format case.
//
// Run via: swift run bionic --selftest-tapexception
func runSelfTestTapException() async throws {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-TAPEXCEPTION: FAIL - \(reason)")
        exit(1)
    }

    // A mixer node rather than the engine's input node: this test then needs no microphone
    // permission and no audio device, so it runs identically on a laptop and in CI.
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    engine.attach(mixer)
    let nodeFormat = mixer.outputFormat(forBus: 0)

    // --- Case 1: a raised NSException comes back as a Swift error instead of killing us. ---
    // Bus 99 does not exist on this node. Verified to raise; reaching the next line at all is
    // itself the headline result.
    var caught: Error?
    do {
        try mixer.safeInstallTap(onBus: 99, bufferSize: 4096, format: nodeFormat) { _, _ in }
    } catch {
        caught = error
    }
    guard let caught else {
        // Deliberately a failure, not a pass: if AVFoundation stops validating the bus index, this
        // test has stopped exercising the shim and must be given a new trigger rather than
        // silently reporting success forever.
        fail("installing a tap on out-of-range bus 99 did NOT raise - this test no longer exercises the NSException path and needs a new trigger")
    }
    guard let tapError = caught as? TapInstallError else {
        fail("expected a TapInstallError, got \(type(of: caught)): \(caught)")
    }
    guard !tapError.reason.isEmpty else {
        fail("TapInstallError carried an empty reason - the exception's message was lost")
    }

    // --- Case 2: the shim is transparent on the success path. ---
    // A shim that turned EVERY install into an error would sail through Case 1, so pin the happy
    // path: the node's own format on a valid bus must install without throwing.
    do {
        try mixer.safeInstallTap(onBus: 0, bufferSize: 4096, format: nodeFormat) { _, _ in }
    } catch {
        fail("installing a tap with the node's own format on bus 0 threw: \(error)")
    }

    // ...and prove that install actually ATTACHED a tap rather than silently no-op'ing. A second
    // install on an already-tapped bus raises (verified), so a raise here is the positive signal.
    // `removeTap` is NOT usable for this - it returns quietly when no tap is present.
    guard msTryCatch({ mixer.installTap(onBus: 0, bufferSize: 4096, format: nodeFormat) { _, _ in } }) != nil else {
        fail("a second install on bus 0 did not raise, so Case 2's install never attached a tap")
    }
    mixer.removeTap(onBus: 0)

    err("SELFTEST-TAPEXCEPTION: PASS - out-of-range bus surfaced as TapInstallError(\(tapError.reason)); valid install attached a tap and did not throw")
    exit(0)
}
