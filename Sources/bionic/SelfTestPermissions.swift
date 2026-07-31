import AVFoundation
import Foundation

// MARK: - Automated verification of the permission health checks.
//
// What this CAN verify without mutating the developer's actual TCC grants: that the checks are
// non-prompting and fast (a blocking or prompting check would hang `listen` at startup, which is
// the exact failure they were added to prevent), that every status maps to the right remediation
// message, and that the live-probe stage agrees with reality on this machine.
//
// What it CANNOT verify: the denied branches. Reaching those requires revoking a real permission,
// which is not something a test may do to the machine it runs on. Those paths are covered by the
// message-mapping assertions below plus review, and are called out as unexercised in the README.
//
// Run via: swift run bionic --selftest-permissions
func runSelfTestPermissions() async throws {
    var failures: [String] = []

    // --- Non-prompting and prompt: both checks must return well under a second. ---
    // A check that blocks (or shows a dialog) would reintroduce the startup hang.
    let screenStart = Date()
    let screenGranted = ScreenRecordingPermission.isGranted()
    let screenElapsed = Date().timeIntervalSince(screenStart)
    if screenElapsed > 1.0 {
        failures.append("ScreenRecordingPermission.isGranted() took \(screenElapsed)s - it must not block or prompt")
    }

    let micStart = Date()
    let micStatus = MicrophonePermission.check()
    let micElapsed = Date().timeIntervalSince(micStart)
    if micElapsed > 1.0 {
        failures.append("MicrophonePermission.check() took \(micElapsed)s - it must not block or prompt")
    }

    // --- Message mapping: healthy states are silent, unhealthy ones are actionable. ---
    if MicrophonePermission.message(for: .ok) != nil {
        failures.append(".ok produced a warning message - healthy states must stay silent")
    }
    if MicrophonePermission.message(for: .notDetermined) != nil {
        failures.append(".notDetermined produced a warning - the OS prompt handles this case")
    }
    for bad in [MicrophonePermission.Status.denied, .grantedButNoDevice] {
        guard let msg = MicrophonePermission.message(for: bad), !msg.isEmpty else {
            failures.append("\(bad) produced no message - an unhealthy state must be actionable")
            continue
        }
        // The whole point is telling the user where to go; a message with no destination is noise.
        if !msg.contains("System Settings") {
            failures.append("\(bad) message does not name System Settings: \(msg)")
        }
    }
    // The two unhealthy messages must differ - a device problem misdescribed as a permission
    // problem sends the user to the wrong settings pane.
    if MicrophonePermission.message(for: .denied) == MicrophonePermission.message(for: .grantedButNoDevice) {
        failures.append("denied and grantedButNoDevice share one message - they need different remediation")
    }
    if !ScreenRecordingPermission.remediation.contains("Screen & System Audio Recording") {
        failures.append("screen-recording remediation does not name the Settings pane")
    }

    // --- Probe agreement: the two-stage mic check must be consistent with the raw APIs. ---
    // This is the part that actually exercises the live probe rather than trusting the enum.
    let rawStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let hasDevice = AVCaptureDevice.default(for: .audio) != nil
    switch (rawStatus, hasDevice, micStatus) {
    case (.authorized, true, .ok),
         (.authorized, false, .grantedButNoDevice),
         (.denied, _, .denied),
         (.restricted, _, .denied),
         (.notDetermined, _, .notDetermined):
        break // consistent
    default:
        failures.append("mic check returned \(micStatus) but raw status is \(rawStatus.rawValue) with hasDevice=\(hasDevice)")
    }

    guard failures.isEmpty else {
        err("SELFTEST-PERMISSIONS: FAIL")
        for f in failures { err("  - \(f)") }
        exit(1)
    }
    err("""
        SELFTEST-PERMISSIONS: PASS - both checks non-prompting (screen \
        \(String(format: "%.3f", screenElapsed))s, mic \(String(format: "%.3f", micElapsed))s); \
        messages mapped and distinct; probe agrees with raw APIs \
        (screenGranted=\(screenGranted), mic=\(micStatus))
        """)
    exit(0)
}
