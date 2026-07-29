import Foundation
import AVFoundation

// MARK: - REAL crash-safety test for the WAV writer (AudioRecorder.swift).
//
// This is the single most important test in the retention feature, and it must be a REAL process
// kill, not an in-process simulation. The whole defect being guarded against is that AVAudioFile
// only writes the RIFF/data size header on close: a file killed before close looks EMPTY to every
// reader even though its PCM is physically on disk. An in-process assertion can't exhibit that -
// only an actual SIGKILL between flushes can - so this spawns a child that records audio, kills it
// with SIGKILL after a confirmed flush, and asserts the WAV still reads back with real frames.
//
// Two anti-cheat details:
//   - Read-back uses AVAudioFile(forReading:).length - the EXACT reader that reported 0 frames in
//     the pre-fix probe. A pass here means the reader the rest of the tool trusts sees the audio.
//   - No sleep-and-hope: the child prints "FLUSHED" to stdout AFTER at least one fsynced flush has
//     landed on disk, and the parent waits for that line before killing. The kill is therefore
//     always after durable data exists, never racing the first write.
//
// Run via: swift run meetingscribe --selftest-record-crash   (hidden; spawns --selftest-record-child)

/// The CHILD half. Opens a recorder, feeds it several seconds of synthetic audio (model-free: no
/// VAD/ASR), prints FLUSHED once durable data is on disk, then SPINS so the parent can SIGKILL it.
/// Deliberately never calls finish() - that is the whole point: prove the on-disk file is valid
/// WITHOUT the clean close.
func runSelfTestRecordChild() async -> Never {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("record-child: usage: --selftest-record-child <wav-path>\n".utf8))
        exit(2)
    }
    let sampleRate = 16000
    let recorder = AudioRecorder(url: URL(fileURLWithPath: args[2]), sampleRate: Double(sampleRate))
    do { try await recorder.open() } catch {
        FileHandle.standardError.write(Data("record-child: open failed: \(error)\n".utf8)); exit(3)
    }

    var phase = 0
    func chunk(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        for k in 0..<n { out[k] = Float(0.5 * sin(2.0 * Double.pi * 440.0 * Double(phase) / Double(sampleRate))); phase += 1 }
        return out
    }
    // Feed 3s in 4096-sample chunks. flushThreshold is ~1s, so at least two full flushes (each
    // fsynced, each patching the header) land on disk before we announce FLUSHED.
    let target = sampleRate * 3
    var fed = 0
    while fed < target {
        let n = min(4096, target - fed)
        await recorder.append(chunk(n))
        fed += n
    }
    let onDisk = await recorder.samplesWritten
    FileHandle.standardOutput.write(Data("FLUSHED \(onDisk)\n".utf8))
    // Spin forever; the parent SIGKILLs us here. No finish(), no manifest.
    while true { try? await Task.sleep(nanoseconds: 200_000_000) }
}

/// The PARENT half. Spawns the child (same binary), waits for its FLUSHED line, SIGKILLs it, then
/// asserts the abandoned WAV reads back with real frames via AVAudioFile.
// async entry (fits runBlocking); all the blocking Process/kill/semaphore logic lives in the
// synchronous helper below, where DispatchSemaphore.wait is permitted.
func runSelfTestRecordCrash() async throws {
    performRecordCrashTest()
}

private func performRecordCrashTest() {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-RECORD-CRASH: FAIL - \(reason)")
        exit(1)
    }
    let sampleRate = 16000
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("meetingscribe-crash-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let wavURL = tmpDir.appendingPathComponent("rec.wav")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]) // this same built binary
    proc.arguments = ["--selftest-record-child", wavURL.path]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    do { try proc.run() } catch { fail("could not spawn child: \(error)") }

    // Wait for the child's FLUSHED line, bounded so a hang fails loudly instead of blocking forever.
    let reader = outPipe.fileHandleForReading
    let sawFlush = DispatchSemaphore(value: 0)
    let box = FlushBox()
    let watcher = Thread {
        var acc = Data()
        while true {
            let d = reader.availableData
            if d.isEmpty { break } // EOF (child died before flushing)
            acc.append(d)
            if let s = String(data: acc, encoding: .utf8), let line = s.split(separator: "\n").first(where: { $0.hasPrefix("FLUSHED") }) {
                box.set(String(line)); sawFlush.signal(); return
            }
        }
        sawFlush.signal()
    }
    watcher.start()
    if sawFlush.wait(timeout: .now() + 30) == .timedOut {
        kill(proc.processIdentifier, SIGKILL)
        fail("child never reported FLUSHED within 30s")
    }
    guard let flushLine = box.get() else {
        kill(proc.processIdentifier, SIGKILL); proc.waitUntilExit()
        fail("child hit EOF (exited) before flushing - it should have spun waiting for the kill")
    }

    // Hard kill mid-session - the real thing, not a simulated close.
    kill(proc.processIdentifier, SIGKILL)
    proc.waitUntilExit()
    guard proc.terminationReason == .uncaughtSignal else {
        fail("child exited on its own (reason \(proc.terminationReason.rawValue)) rather than being SIGKILLed - test didn't exercise a crash")
    }

    // The child announced this many samples fsynced before we killed it.
    let announced = Int(flushLine.split(separator: " ").last.map(String.init) ?? "") ?? 0

    // Read back with the reader that reported 0 in the pre-fix probe.
    let f: AVAudioFile
    do { f = try AVAudioFile(forReading: wavURL) } catch {
        fail("SIGKILLed WAV is unreadable (\(error)) - the header was never patched, so the whole file is lost on a crash. This is the bug.")
    }
    let frames = Int(f.length)
    // Teeth: the bug yields exactly 0 frames. At least one ~1s flush (>= sampleRate) must survive.
    guard frames >= sampleRate else {
        fail("SIGKILLed WAV reads back as \(frames) frames (child had fsynced \(announced)). A crash lost the audio - header not incrementally patched.")
    }
    err(String(format: "SELFTEST-RECORD-CRASH: PASS [sigkill] - child fsynced %d samples then took a real SIGKILL; abandoned WAV still reads back %d frames (%.2fs) via AVAudioFile. Header is patched incrementally, not on close.",
               announced, frames, Double(frames) / Double(sampleRate)))
    err("SELFTEST-RECORD-CRASH: PASS (all cases)")
    exit(0)
}

private final class FlushBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
