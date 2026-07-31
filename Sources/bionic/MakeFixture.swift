import AVFoundation
import Foundation

// MARK: - Synthesized accuracy fixtures with ground truth by construction.
//
// A quality gate needs labelled audio, and hand-labelling is the reason projects never build one.
// `say` sidesteps it: we know exactly which words were spoken and, because we concatenate the
// per-utterance WAVs ourselves, exactly when each speaker starts and stops. The reference is
// therefore derived from the construction rather than transcribed after the fact.
//
// Deliberately no `sox` dependency (the obvious reference implementation of this uses it) -
// concatenation and resampling go through AVFoundation, which we already link, so `make fixture`
// works on a clean machine with no Homebrew packages.
//
// LIMITS, because a gate built on this will otherwise be over-trusted: synthesized speech has clean
// turn boundaries, no crosstalk, no overlap, no room noise and no channel effects. Diarization and
// ASR both score far better on it than on a real meeting. It is a REGRESSION detector - it answers
// "did we get worse than yesterday" - not an estimate of real-world accuracy. A real recorded
// fixture is still needed for that.
//
// Run via: swift run bionic make-fixture [--out DIR]

/// One scripted utterance: a `say` voice plus what it says.
private struct ScriptedLine {
    let speaker: String
    let voice: String
    let text: String
}

/// The fixture script. Voices are macOS built-ins present on a stock system; `speaker` is the
/// ground-truth identity the diarizer is expected to separate (not to name - naming is a different
/// problem, see Review.swift).
private let fixtureScript: [ScriptedLine] = [
    ScriptedLine(speaker: "alice", voice: "Samantha", text: "Good morning everyone, let us start the sprint review."),
    ScriptedLine(speaker: "bob", voice: "Daniel", text: "Thanks Alice. The billing service migration is finished."),
    ScriptedLine(speaker: "alice", voice: "Samantha", text: "Did we keep the old endpoints working for existing clients?"),
    ScriptedLine(speaker: "bob", voice: "Daniel", text: "Yes, both versions run side by side until the next release."),
    ScriptedLine(speaker: "carol", voice: "Karen", text: "I have an update on the frontend dashboard as well."),
    ScriptedLine(speaker: "alice", voice: "Samantha", text: "Go ahead Carol, we have plenty of time left."),
    ScriptedLine(speaker: "carol", voice: "Karen", text: "The new charts load twice as fast after the caching change."),
]

/// Silence inserted between utterances. 0.4s is long enough to be an unambiguous turn boundary for
/// any VAD without being so long that the fixture is mostly silence.
private let gapSeconds = 0.4

struct FixtureTruth: Codable {
    let audioFile: String
    let sampleRate: Double
    let segments: [TruthSegment]
    /// Full reference transcript in speaking order - the WER reference.
    let transcript: String
    let note: String
}

func runMakeFixture() async throws {
    var outDir = "testdata/quality"
    var args = Array(CommandLine.arguments.dropFirst(2))
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--out":
            guard !args.isEmpty else {
                err("make-fixture: --out requires a directory")
                exit(2)
            }
            outDir = args.removeFirst()
        case "-h", "--help":
            err("usage: bionic make-fixture [--out DIR]")
            exit(0)
        default:
            err("make-fixture: unknown flag \(flag)")
            exit(2)
        }
    }

    let fm = FileManager.default
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let tmp = NSTemporaryDirectory() + "bionic-fixture-\(UUID().uuidString)"
    try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    // --- 1. Synthesize each utterance separately, so boundaries are known exactly. ---
    var perLineFiles: [(line: ScriptedLine, path: String)] = []
    for (i, line) in fixtureScript.enumerated() {
        let path = "\(tmp)/line\(i)_\(line.speaker).wav"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = [
            "-v", line.voice,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            "-o", path,
            line.text,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stderrText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0, fm.fileExists(atPath: path) else {
            err("""
                make-fixture: `say -v \(line.voice)` failed (status \(proc.terminationStatus)).
                \(stderrText.isEmpty ? "" : "stderr: \(stderrText)")
                That voice may not be installed. Install it under System Settings -> Accessibility
                -> Spoken Content -> System Voice -> Manage Voices, or edit fixtureScript in
                Sources/bionic/MakeFixture.swift to use a voice from `say -v '?'`.
                """)
            exit(1)
        }
        perLineFiles.append((line, path))
    }

    // --- 2. Concatenate into one 16 kHz mono file, recording exact segment times. ---
    let targetRate = 16000.0
    // Two different formats are in play and conflating them corrupts the audio:
    //   * FILE format (settings below) - how samples are ENCODED on disk: 16-bit integer PCM.
    //   * PROCESSING format - the format of the AVAudioPCMBuffers we hand to `write(from:)`.
    // AVAudioFile converts between them, but only if the buffer we pass actually matches the
    // processing format. `AVAudioFile(forReading:)` always hands back Float32 buffers regardless of
    // what is on disk, so the writer must also be Float32 - opening it as Int16 and then writing
    // those Float32 buffers reinterprets the bytes and produces clipped noise (measured: peak 1.0 /
    // RMS 0.49 against the source's 0.16), which the diarizer correctly reports as no speech.
    let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: targetRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    let audioName = "meeting_3speakers_en.wav"
    let audioPath = "\(outDir)/\(audioName)"
    if fm.fileExists(atPath: audioPath) { try fm.removeItem(atPath: audioPath) }
    var cursorSeconds = 0.0
    var segments: [TruthSegment] = []

    // The writer lives ONLY inside this scope. AVAudioFile has no close() - it finalizes the
    // RIFF/data chunk sizes in deinit, so any surviving reference at process exit leaves a
    // zero-length header on disk (`afinfo` reports "audio bytes: 0" while all the samples are
    // actually there). That is the same unfinalized-WAV failure RepairWav.swift cleans up after
    // crashes; here it is avoidable, so the reference is scoped rather than nil'd - a `guard let`
    // copy elsewhere in the function would silently keep it alive and reintroduce the bug.
    do {
        let outFile = try AVAudioFile(
            forWriting: URL(fileURLWithPath: audioPath),
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let outFormat = outFile.processingFormat

        func writeSilence(_ seconds: Double) throws {
            let frames = AVAudioFrameCount(seconds * targetRate)
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) else { return }
            buf.frameLength = frames
            // A freshly allocated buffer is not guaranteed zeroed; zero it explicitly so "silence"
            // is actually silent rather than whatever was in that memory.
            if let ch = buf.floatChannelData {
                memset(ch[0], 0, Int(frames) * MemoryLayout<Float>.size)
            }
            try outFile.write(from: buf)
            cursorSeconds += Double(frames) / targetRate
        }

        for (index, entry) in perLineFiles.enumerated() {
            if index > 0 { try writeSilence(gapSeconds) }

            let inFile = try AVAudioFile(forReading: URL(fileURLWithPath: entry.path))
            // `say` was asked for 16 kHz mono LEI16 directly, so this should already match the
            // output format; assert rather than silently writing a rate-mismatched segment, which
            // would shift every subsequent ground-truth timestamp.
            guard abs(inFile.processingFormat.sampleRate - targetRate) < 1.0 else {
                err("""
                    make-fixture: \(entry.path) came back at \(inFile.processingFormat.sampleRate) Hz, \
                    expected \(targetRate) Hz. Ground-truth timings would be wrong, so refusing to \
                    continue.
                    """)
                exit(1)
            }
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: inFile.processingFormat,
                frameCapacity: AVAudioFrameCount(inFile.length)
            ) else {
                err("make-fixture: could not allocate a read buffer for \(entry.path)")
                exit(1)
            }
            try inFile.read(into: buf)

            let start = cursorSeconds
            try outFile.write(from: buf)
            let duration = Double(buf.frameLength) / targetRate
            cursorSeconds += duration

            segments.append(TruthSegment(
                speaker: entry.line.speaker,
                start: start,
                end: start + duration,
                text: entry.line.text
            ))
        }
    }

    // --- 3. Verify the audio we just wrote is actually speech. ---
    // This exists because the first version of this command silently produced clipped noise (a
    // Float32/Int16 processing-format mismatch). Everything downstream still "worked" - the file
    // was the right length, the truth JSON was correct - and the only symptom was the diarizer
    // reporting no speech, several layers away. Cheap sanity check, caught at the source.
    do {
        let check = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: check.processingFormat, frameCapacity: AVAudioFrameCount(check.length)
        ) else {
            err("make-fixture: could not read back \(audioPath) to verify it")
            exit(1)
        }
        try check.read(into: buf)
        var peak: Float = 0
        var sumSquares = 0.0
        if let ch = buf.floatChannelData {
            for i in 0..<Int(buf.frameLength) {
                let v = abs(ch[0][i])
                peak = max(peak, v)
                sumSquares += Double(v) * Double(v)
            }
        }
        let rms = buf.frameLength > 0 ? (sumSquares / Double(buf.frameLength)).squareRoot() : 0

        // Speech synthesized by `say` sits around peak 0.8 / RMS 0.15. Full-scale peak with high
        // RMS means reinterpreted bytes, not loud speech; near-zero means we wrote silence.
        guard rms > 0.01 else {
            err("make-fixture: written audio is effectively silent (rms \(rms)) - refusing to emit a fixture that scores nothing")
            exit(1)
        }
        guard rms < 0.40 else {
            err("""
                make-fixture: written audio looks like reinterpreted bytes, not speech \
                (rms \(String(format: "%.3f", rms)), peak \(String(format: "%.3f", peak))). \
                Check that the writer's processing format matches the buffers being written.
                """)
            exit(1)
        }
        err(String(format: "make-fixture: audio check ok (peak %.3f, rms %.3f)", peak, rms))
    }

    // --- 4. Write the ground truth alongside the audio. ---
    let truth = FixtureTruth(
        audioFile: audioName,
        sampleRate: targetRate,
        segments: segments,
        transcript: fixtureScript.map(\.text).joined(separator: " "),
        note: """
            Synthesized by `bionic make-fixture` via macOS `say`. Ground truth is exact by \
            construction (each utterance was rendered separately, then concatenated with \
            \(gapSeconds)s gaps). NOT representative of real meeting audio: no overlap, no \
            crosstalk, no room noise. Use for regression detection, not for absolute accuracy \
            claims.
            """
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let truthPath = "\(outDir)/\(audioName.replacingOccurrences(of: ".wav", with: ".truth.json"))"
    try encoder.encode(truth).write(to: URL(fileURLWithPath: truthPath))

    let speakers = Set(segments.map(\.speaker)).sorted().joined(separator: ", ")
    err("""
        make-fixture: wrote \(audioPath) (\(String(format: "%.1f", cursorSeconds))s, \
        \(segments.count) turns, speakers: \(speakers))
        make-fixture: wrote \(truthPath)
        """)
    exit(0)
}
