import AVFoundation
import CoreGraphics
import Foundation

/// Screen Recording permission state, checked WITHOUT prompting.
///
/// Why this exists: `SCShareableContent.current` does not fail fast when Screen Recording has not
/// been granted - it blocks. That is the hang README.md documents ("If `listen` hangs at 'Starting
/// system-audio capture', Screen Recording is not granted"), which puts the burden of diagnosing a
/// permission problem on the user staring at a frozen terminal. `CGPreflightScreenCaptureAccess()`
/// answers the same question immediately and, unlike `CGRequestScreenCaptureAccess()`, never shows
/// a dialog - so it is safe to call on every run, including in tests and CI.
///
/// A granted-but-broken state is possible in principle (TCC says yes, capture still yields
/// nothing), which is why the caller keeps its own no-audio stream-health warning; preflight only
/// rules out the common, actionable case.
enum ScreenRecordingPermission {
    /// True when this process (in practice: the terminal app hosting it) holds the TCC grant.
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The remediation text shown when the grant is missing. Names the exact Settings pane and the
    /// fact that the grant attaches to the TERMINAL, not to this binary - the single most confusing
    /// part of this permission, since rebuilding bionic does not revoke it but switching
    /// terminal apps silently does.
    static let remediation = """
        Screen Recording permission is not granted, so system audio ("other") cannot be captured.

        Grant it to your TERMINAL app (not to bionic itself - the grant follows the process
        that launches it, and survives rebuilds):

          System Settings -> Privacy & Security -> Screen & System Audio Recording

        Then fully quit and reopen the terminal; macOS only re-reads this grant at launch.
        """
}

/// Microphone permission, checked in two stages.
///
/// The TCC status alone is not sufficient. "Authorized" only means the user clicked Allow at some
/// point - it does not mean a usable input device exists right now. A machine with no input device,
/// or with the input device claimed exclusively by another process, reports `.authorized` and then
/// yields silence forever. That failure looks identical to "nobody spoke" in the transcript, which
/// is the worst possible way for it to present: a clean-looking run with no `me` turns.
///
/// So: ask TCC (cheap, definitive for the denied case), then confirm a device is actually there.
enum MicrophonePermission {
    enum Status: Equatable {
        case ok
        /// TCC says no. Actionable by the user.
        case denied
        /// TCC says yes but no usable capture device exists. Not a permission problem - a hardware
        /// or device-contention problem - and it needs a different message.
        case grantedButNoDevice
        /// The user has never been asked. `listen` triggers the prompt on first capture.
        case notDetermined
    }

    static func check() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .authorized:
            // The probe. `default(for:.audio)` is non-prompting and returns nil when there is no
            // usable input - which is exactly the granted-but-broken state a status-only check
            // reports as healthy.
            return AVCaptureDevice.default(for: .audio) == nil ? .grantedButNoDevice : .ok
        @unknown default:
            // A status this build does not know about. Do not guess "fine" - say so and let the
            // caller decide, rather than silently proceeding into a possibly-silent recording.
            return .notDetermined
        }
    }

    static func message(for status: Status) -> String? {
        switch status {
        case .ok, .notDetermined:
            return nil
        case .denied:
            return """
                Microphone permission is denied, so your own voice ("me") cannot be captured.

                Grant it to your TERMINAL app: System Settings -> Privacy & Security -> Microphone
                Then fully quit and reopen the terminal.
                """
        case .grantedButNoDevice:
            return """
                Microphone permission is granted, but macOS reports no usable audio input device.

                This is not a permissions problem - check that an input device is connected and
                selected under System Settings -> Sound -> Input, and that no other application has
                taken exclusive control of it. Recording would otherwise produce a transcript with
                no "me" turns at all, which looks the same as silence.
                """
        }
    }
}
