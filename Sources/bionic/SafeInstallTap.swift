import AVFoundation
import CExceptionCatcher
import Foundation

/// Thrown when `installTap` raised an Objective-C NSException instead of returning.
struct TapInstallError: Error, CustomStringConvertible {
    let reason: String
    var description: String { "installTap failed: \(reason)" }
}

extension AVAudioNode {
    /// `installTap(onBus:bufferSize:format:block:)` that reports failure instead of aborting.
    ///
    /// AVFoundation raises an NSException - not a Swift error - when `format` doesn't match the
    /// node's hardware format. That is reachable in production: a mid-session input-device change
    /// (plugging in a headset, an AirPods A2DP/HFP renegotiation) can change the hardware format
    /// between reading `outputFormat(forBus:)` and installing the tap. Uncaught, it terminates the
    /// process and the in-progress meeting is lost. Route every tap install through here.
    func safeInstallTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        if let reason = msTryCatch({
            self.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
        }) {
            throw TapInstallError(reason: reason)
        }
    }
}
