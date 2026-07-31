import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import FluidAudio

// MARK: - Capture adapters: platform-specific glue that turns AVAudioEngine's mic tap /
// ScreenCaptureKit's system-audio tap into the same RawAudioChunk shape runStreamPipeline()
// consumes (TurnPipeline.swift). Nothing platform-specific leaks past this file - the pipeline
// itself never sees an AVAudioPCMBuffer or a CMSampleBuffer.

// MARK: - Microphone capture ("me")

/// Starts microphone capture via AVAudioEngine and returns an AsyncStream of RawAudioChunk
/// (resampled to 16kHz mono Float32 via FluidAudio's own AudioConverter, matching what VAD/ASR
/// expect). Also the primary defense against the correctness cliff called out in the task: on
/// speaker output (not headphones), the mic will otherwise pick up the call's own remote-party
/// audio and duplicate it onto the "me" stream. `setVoiceProcessingEnabled(true)` turns on
/// AVAudioEngine's built-in echo cancellation on the input node BEFORE the engine starts.
///
/// This is a MITIGATION, not a guarantee - it is not certain to fully suppress speaker bleed on
/// every device/routing combination. HEADPHONES ARE THE SAFE FALLBACK if "me" mislabeling
/// matters for a given meeting; see the module doc in Listen.swift.
///
/// ALSO HANDLES: a mid-session input-device change (e.g. switching from the built-in mic to
/// AirPods mid-meeting). AVAudioEngine posts `.AVAudioEngineConfigurationChange` when the DEFAULT
/// INPUT DEVICE changes under a running engine, and does NOT reconfigure a running tap for the
/// new device on its own - Apple's own guidance (and the well-known "format.sampleRate ==
/// hwFormat.sampleRate" crash reports on the developer forums) is that the app must tear the tap
/// down and reinstall it. Left unhandled, a device switch leaves the tap running against stale
/// state with no signal to the operator that anything changed - exactly what happened in a real
/// test: bleed-through (a duplicate "other" line re-appearing as "me") first showed up only after
/// switching to AirPods mid-call, never before. Two independent reasons a switch raises risk even
/// with reconfiguration: (1) without reacting to the notification, voice processing / the ducking
/// config above could silently be reset off by the OS-driven reconfiguration; (2) Bluetooth
/// devices like AirPods have a round-trip latency the built-in echo canceller isn't tuned for, so
/// AEC quality can genuinely be worse post-switch even once state is correctly reapplied.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private var continuation: AsyncStream<RawAudioChunk>.Continuation?
    private var configChangeObserver: NSObjectProtocol?
    private var isStopping = false

    // Serializes stop() against handleConfigurationChange(). The configuration-change
    // notification is registered with `queue: nil`, so its handler runs SYNCHRONOUSLY on whatever
    // thread posted it - an audio-system thread, not the one calling stop(). Without this lock
    // the two race on the `isStopping` flag and on the engine itself: stop() can set isStopping,
    // remove the tap and stop the engine while the handler is midway through its own teardown,
    // having already read isStopping as false - and the handler then reinstalls the tap and calls
    // engine.start() AFTER stop() finished. That leaves the microphone live past shutdown with a
    // tap yielding into a finished continuation, and `listen` reporting a clean exit while still
    // holding the mic. `isStopping` is checked and acted on inside the same critical section that
    // sets it, so the ordering is decided once, not observed twice.
    private let lock = NSLock()

    func start() throws -> AsyncStream<RawAudioChunk> {
        let (stream, continuation) = AsyncStream<RawAudioChunk>.makeStream()
        self.continuation = continuation

        try configureVoiceProcessingAndInstallTap()

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        try engine.start()
        return stream
    }

    // MARK: Shared by start() (initial setup) and handleConfigurationChange() (re-setup after a
    // device switch) - one implementation of "enable AEC, minimize ducking, install the tap",
    // so a post-switch reconfiguration can't silently diverge from initial startup.
    private func configureVoiceProcessingAndInstallTap() throws {
        let input = engine.inputNode

        do {
            try input.setVoiceProcessingEnabled(true)
            // Voice Processing I/O doesn't just add echo cancellation - by default it also
            // engages macOS's automatic "other audio" ducking, which treats this process as
            // being in a voice chat and lowers the volume of everything else playing, INCLUDING
            // the call app's own remote-party audio coming out of the speakers/headphones. That
            // is a real, audible regression to the actual meeting (not just to the transcript),
            // and we don't need it: "other" audio is captured independently via ScreenCaptureKit
            // (SystemAudioCapture below), so AEC here only needs to protect the "me" stream, not
            // suppress playback. Minimize ducking rather than accept Apple's default.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        } catch {
            printBoxedWarning([
                "# WARNING: could not enable AVAudioEngine echo cancellation on the mic input   ",
                "# (\(error)).                                                                  ",
                "# Continuing WITHOUT echo cancellation - on speaker output (not headphones),   ",
                "# the mic may pick up the call's own remote-party audio and mislabel it 'me'.  ",
                "# Headphones are the safe fallback if this matters for your meeting.           ",
            ])
        }

        let format = input.outputFormat(forBus: 0)
        guard let continuation else { return } // set by start() before this is ever called
        let converter = self.converter

        // safeInstallTap, not installTap: AVFoundation RAISES on a format mismatch rather than
        // returning an error, and `format` was read from the hardware a few statements ago - a
        // device change in that window makes it stale. See SafeInstallTap.swift.
        try input.safeInstallTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let samples = try? converter.resampleBuffer(buffer), !samples.isEmpty else { return }
            continuation.yield(RawAudioChunk(samples: samples, epochTime: Date().timeIntervalSince1970))
        }
    }

    // MARK: Fires on a mid-session input-device change. Tears down and reinstalls the tap
    // against the new device, per Apple's guidance - the engine does not do this itself. Also
    // surfaces a loud, visible warning (matching printBoxedWarning's existing shape elsewhere in
    // this project) so a human reading run output knows to distrust "me" turns immediately after
    // this timestamp, rather than a silent reconfiguration nobody sees.
    private func handleConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopping else { return } // our own stop() can trigger this; ignore during teardown
        printBoxedWarning([
            "# NOTICE: microphone input device changed mid-session - reconfiguring capture.   ",
            "# 'me' turns right around this point carry higher bleed-through risk: switching   ",
            "# devices (e.g. to a Bluetooth headset) can degrade echo cancellation even after  ",
            "# it's been reapplied below.                                                      ",
        ])
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        do {
            try configureVoiceProcessingAndInstallTap()
            try engine.start()
        } catch {
            err("Failed to reconfigure microphone capture after a device change: \(error)")
        }
    }

    func stop() {
        // Three phases, deliberately NOT one critical section. Taking the lock across
        // removeObserver would deadlock: removeObserver can block until an in-flight handler
        // returns, while that handler is itself blocked waiting for this lock. So: publish the
        // stopping flag under the lock (any handler that has not yet entered its critical section
        // will now see it and bail), THEN detach the observer with the lock released, THEN tear
        // down under the lock. A handler already past its guard finishes its reconfiguration
        // first and the teardown below undoes it - the engine still ends up stopped.
        lock.lock()
        isStopping = true
        lock.unlock()

        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }

        lock.lock()
        defer { lock.unlock() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - System-audio capture ("other")

enum ListenError: Error, LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "ScreenCaptureKit reported no displays - cannot capture system audio " +
                "(no Screen Recording permission granted to this terminal app? no display attached?)."
        }
    }
}

/// SCStreamOutput/SCStreamDelegate conformer bridging ScreenCaptureKit's Objective-C callback
/// (`stream(_:didOutputSampleBuffer:ofType:)`, invoked on an arbitrary dispatch queue) into the
/// RawAudioChunk AsyncStream the pipeline consumes.
///
/// @unchecked Sendable: the mutable state it touches (the AsyncStream continuation, the
/// AudioConverter) is safe to use from ScreenCaptureKit's callback queue - AudioConverter is
/// itself `Sendable`, and `AsyncStream.Continuation.yield` is documented safe to call
/// concurrently from any queue/thread.
final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<RawAudioChunk>.Continuation
    private let converter = AudioConverter()

    init(continuation: AsyncStream<RawAudioChunk>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return } // no video SCStreamOutput is ever registered, but guard anyway
        guard let samples = try? converter.resampleSampleBuffer(sampleBuffer), !samples.isEmpty else { return }
        continuation.yield(RawAudioChunk(samples: samples, epochTime: Date().timeIntervalSince1970))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        err("System-audio capture stopped unexpectedly: \(error)")
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

/// Starts system-audio (ScreenCaptureKit) capture: whatever the OS is currently playing through
/// output - the call's remote participants. Structurally "other" per the architecture decision:
/// no per-speaker diarization here, every remote voice collapses to "other" (per-name identity
/// is explicitly deferred to offline post-meeting reconciliation, per the handoff contract).
///
/// Verified working in this environment (2026-07-23): a standalone smoke test using this exact
/// SCShareableContent.current -> SCContentFilter -> SCStreamConfiguration(capturesAudio: true)
/// -> SCStream/SCStreamOutput shape received 418 real audio sample buffers over an 8s window
/// while `say` played, using the same Screen Recording TCC grant a prior spike in this project
/// established (tied to the terminal app's identity, not this ad-hoc binary - survives rebuilds).
///
/// API note: SCStream always captures SOME video surface even when only audio output is
/// registered - width/height are pinned to 2x2 and minimumFrameInterval to 1fps to make that
/// unavoidable video side as cheap as possible; no video SCStreamOutput is ever added.
final class SystemAudioCapture: @unchecked Sendable {
    private var stream: SCStream?
    private var tap: SystemAudioTap?

    func start() async throws -> AsyncStream<RawAudioChunk> {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ListenError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (asyncStream, continuation) = AsyncStream<RawAudioChunk>.makeStream()
        let tap = SystemAudioTap(continuation: continuation)
        self.tap = tap

        let scStream = SCStream(filter: filter, configuration: config, delegate: tap)
        try scStream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: DispatchQueue(label: "bionic.systemaudio"))
        self.stream = scStream

        try await scStream.startCapture()
        return asyncStream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        tap?.finish()
        tap = nil
        self.stream = nil
    }
}
