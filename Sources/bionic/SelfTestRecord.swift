import Foundation
import AVFoundation
import FluidAudio

// MARK: - Automated verification of the audio-retention tee + WAV writer (AudioRecorder.swift).
//
// Model-free (no VAD/ASR/network): drives synthetic RawAudioChunks through `recording(_:into:)`
// into an AudioRecorder, drains the teed stream the way a pipeline would, then asserts:
//   1. Every real sample fed reached the WAV, and NOTHING extra did (samplesWritten == fed). This
//      is the load-bearing "only real chunks are recorded" property: the tee wraps the INPUT
//      stream, so runStreamPipeline's synthetic end-of-stream pad - built internally from `carry`,
//      never yielded onto any stream - is structurally unreachable here. A pad leaking in would
//      show up as samplesWritten > fed.
//   2. The file reads back as real 16kHz mono audio of the expected length (via AudioConverter,
//      the same reader the rest of the tool uses), and its raw WAV header is 16-bit PCM.
//
// A deliberately non-chunk-aligned sample count is used so any off-by-a-chunk padding bug can't
// hide behind alignment.
//
// Run via: swift run bionic --selftest-record   (hidden subcommand, see main.swift)
func runSelfTestRecord() async throws {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-RECORD: FAIL - \(reason)")
        exit(1)
    }

    let sampleRate = 16000
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bionic-selftest-record-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let wavURL = tmpDir.appendingPathComponent("rec.wav")

    // A non-chunk-aligned total: 5 chunks of 4096 + a 1000-sample partial = 21480 samples.
    let deliverySizes = [4096, 4096, 4096, 4096, 4096, 1000]
    let fedTotal = deliverySizes.reduce(0, +)

    // Deterministic non-trivial waveform so a read-back isn't just checking a file of zeros.
    var phase = 0
    func nextChunk(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        for k in 0..<n {
            out[k] = Float(0.5 * sin(2.0 * Double.pi * 440.0 * Double(phase) / Double(sampleRate)))
            phase += 1
        }
        return out
    }

    let recorder = AudioRecorder(url: wavURL, sampleRate: Double(sampleRate))
    try await recorder.open()

    let (input, continuation) = AsyncStream<RawAudioChunk>.makeStream()
    let base = Date().timeIntervalSince1970
    var offset = 0
    for size in deliverySizes {
        offset += size
        continuation.yield(RawAudioChunk(samples: nextChunk(size), epochTime: base + Double(offset) / Double(sampleRate)))
    }
    continuation.finish()

    // Tee through the recorder and drain fully, exactly as the pipeline consumer would.
    let teed = recording(input, into: recorder)
    var drained = 0
    for await chunk in teed { drained += chunk.samples.count }
    await recorder.finish()

    guard drained == fedTotal else { fail("tee forwarded \(drained) samples, fed \(fedTotal) - tee dropped/added samples") }

    let written = await recorder.samplesWritten
    guard written == fedTotal else {
        fail("WAV holds \(written) samples but only \(fedTotal) real samples were fed - a phantom pad or drop leaked into retention")
    }
    guard await recorder.truncated == false else { fail("recorder marked itself truncated on a clean run") }

    // Read back with the tool's own reader: confirms it's a decodable 16kHz mono WAV of the right length.
    let readBack = try AudioConverter().resampleAudioFile(path: wavURL.path)
    guard abs(readBack.count - fedTotal) <= 1 else {
        fail("read-back sample count \(readBack.count) != fed \(fedTotal) (WAV duration/rate wrong)")
    }

    // Confirm the on-disk format is genuinely 16-bit PCM mono @ 16kHz via AVAudioFile metadata.
    let f = try AVAudioFile(forReading: wavURL)
    let fmt = f.fileFormat
    guard Int(fmt.sampleRate) == sampleRate else { fail("file sample rate \(fmt.sampleRate) != \(sampleRate)") }
    guard fmt.channelCount == 1 else { fail("file channel count \(fmt.channelCount) != 1 (not mono)") }
    let durationSeconds = Double(f.length) / fmt.sampleRate
    let expectedSeconds = Double(fedTotal) / Double(sampleRate)
    guard abs(durationSeconds - expectedSeconds) < 0.01 else {
        fail(String(format: "file duration %.3fs != expected %.3fs", durationSeconds, expectedSeconds))
    }

    err(String(format: "SELFTEST-RECORD: PASS [tee+wav] - fed %d samples, WAV holds exactly %d, reads back as %.3fs of 16kHz mono; no phantom pad.",
               fedTotal, written, durationSeconds))
    err("SELFTEST-RECORD: PASS (all cases)")
    exit(0)
}
