import Foundation
import AVFoundation

// MARK: - Audio retention for the live `listen` path.
//
// The live path (Listen.swift) transcribes and then DROPS its audio - nothing is retained, so
// offline post-meeting reconciliation (diarize/review) has nothing to run against. This file adds
// opt-in retention: a tee that records each real capture chunk to a 16kHz mono Int16 WAV while
// forwarding it unchanged into the existing pipeline, plus a per-session manifest describing the
// files and their epoch anchoring so the offline tools can align diarizer output back onto the
// live JSONL's epoch timeline.
//
// Two hard constraints drive the shape here:
//   1. The write must NOT happen on the realtime-ish capture thread (the ScreenCaptureKit
//      sampleHandlerQueue or the AVAudioEngine tap thread) - a blocking file write there risks
//      audio dropouts. AudioRecorder is an actor, so all file I/O runs on its own serial
//      executor, never on a capture thread. Samples are buffered and flushed ~2s at a time.
//   2. Only REAL captured audio may reach the WAV. runStreamPipeline (TurnPipeline.swift)
//      synthesizes a trailing pad chunk at end-of-stream INTERNALLY, from its own `carry` buffer
//      plus repeated samples - that pad is never a RawAudioChunk on the input stream. The tee
//      below wraps the INPUT stream (records on arrival, then yields through), so the synthetic
//      pad is physically unreachable by the recorder: there is nothing to exclude.

/// Writes a stream of 16kHz mono Float32 sample chunks to a 16kHz mono Int16 WAV file, buffered
/// and flushed from the actor's serial executor (never a capture thread). A write failure does
/// NOT abort the meeting: it is logged once to stderr, the recorder is marked truncated (surfaced
/// in the manifest), and subsequent samples are dropped while capture continues.
///
/// CRASH-SAFETY - why this hand-rolls RIFF instead of using AVAudioFile:
/// AVAudioFile only writes the RIFF/data chunk-size header fields on close (deinit). Any exit that
/// does not reach that close - SIGKILL, SIGSEGV, power loss, or the user's own second-Ctrl-C
/// exit(130) - leaves the placeholder header claiming the file is EMPTY, so every reader
/// (AVAudioFile(forReading:), afinfo) sees 0 frames even though the PCM is physically on disk. For
/// a 2-hour meeting that dies at 1h59m that is total, silent data loss. Instead we own the RIFF
/// writer: PCM goes out through a FileHandle, and on EVERY flush we seek back and patch the
/// RIFF-size and data-size fields to match what is actually on disk. Ordering is deliberate and the
/// two fsyncs are INTERLEAVED: append the PCM, fsync it durable, THEN patch the header, then fsync
/// that. The invariant held at every instant is header-reported-length <= durable-data-length - the
/// header may under-report (always readable, and recoverable in full by `repair-wav`) but can never
/// claim MORE data than is durably on disk, which would make a reader run off the end. A hard kill
/// therefore costs at most the un-flushed in-memory buffer (< one flush interval), not the whole
/// file. See flushBuffer for why a single trailing fsync would be a regression, not a speedup.
actor AudioRecorder {
    private let url: URL
    private let sampleRate: Double
    private let flushThreshold: Int // samples buffered before a flush (~1s worth)

    private var handle: FileHandle?
    private var buffer: [Float] = []
    private var dataBytes: Int = 0        // PCM payload bytes currently on disk (excludes the 44-byte header)
    private(set) var samplesWritten = 0
    private(set) var truncated = false
    private var loggedFailure = false

    private static let headerSize = 44
    private static let bitsPerSample = 16

    init(url: URL, sampleRate: Double = 16000) {
        self.url = url
        self.sampleRate = sampleRate
        self.flushThreshold = Int(sampleRate) // flush roughly every 1 second of audio (bounds hard-kill loss)
    }

    /// Create the destination WAV and write its 44-byte canonical PCM header with zeroed size
    /// fields (patched to real values on each flush). On-disk format is 16kHz mono Int16 LE LPCM.
    /// Throws if the file cannot be created - the caller (Listen.swift) decides whether that is
    /// fatal to enabling recording (it treats it as: warn and continue WITHOUT retention).
    func open() throws {
        let fm = FileManager.default
        // Create fresh (truncate any stale file), 0600 from birth.
        guard fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create \(url.path)"])
        }
        let h = try FileHandle(forWritingTo: url)
        h.write(AudioRecorder.wavHeader(sampleRate: Int(sampleRate), dataBytes: 0))
        handle = h
    }

    /// Buffer one chunk of already-resampled 16kHz mono Float32 samples. Flushes to disk once the
    /// buffer crosses the flush threshold. Awaited by the tee - which runs off the capture thread
    /// already - so no realtime thread ever blocks on the write.
    func append(_ samples: [Float]) {
        guard handle != nil, !truncated else { return }
        buffer.append(contentsOf: samples)
        if buffer.count >= flushThreshold {
            flushBuffer()
        }
    }

    /// Flush any remaining buffered samples and close the file. Idempotent.
    func finish() {
        flushBuffer()
        if let fd = handle?.fileDescriptor { AudioRecorder.fullSync(fd) }
        try? handle?.close()
        handle = nil
    }

    /// Flush through the drive's write cache (power-loss durable). Falls back to plain fsync if the
    /// filesystem doesn't support F_FULLFSYNC.
    private static func fullSync(_ fd: Int32) {
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
    }

    // MARK: Convert the buffered Float32 samples to Int16 LE, append them to the file, then patch
    // the header size fields to match and fsync. Any failure marks truncation (manifest records it)
    // and stops further writes, but never throws into the caller - a dead disk must not kill an
    // in-progress meeting.
    private func flushBuffer() {
        guard let handle, !buffer.isEmpty else { return }
        let frames = buffer.count
        var pcm = Data(capacity: frames * 2)
        for f in buffer {
            // Clamp to [-1, 1] then scale to full-scale Int16. 32767 (not 32768) keeps the positive
            // and negative peaks symmetric and avoids overflow at exactly +1.0.
            let clamped = max(-1.0, min(1.0, f))
            let s = Int16(clamped * 32767.0)
            let u = UInt16(bitPattern: s)
            pcm.append(UInt8(u & 0xFF))
            pcm.append(UInt8((u >> 8) & 0xFF))
        }
        do {
            // The invariant this ordering preserves at EVERY instant, including across power loss:
            //   header-reported-length  <=  durable-data-length
            // i.e. the header may under-report what's on disk (readable + repairable) but must never
            // claim MORE frames than are physically durable (a reader would then run off the end into
            // garbage or an unpredictable truncation - strictly worse than the AVAudioFile bug this
            // replaces). Getting there requires the two fsyncs to be INTERLEAVED, not appended after
            // both writes: durably land the data BEFORE the header that advertises it. Do not
            // "optimize" this into a single trailing fsync - that reintroduces the over-report window.
            //
            // 1. Append PCM at the current end of file.
            try handle.seek(toOffset: UInt64(AudioRecorder.headerSize + dataBytes))
            try handle.write(contentsOf: pcm)
            // 2. Make the DATA durable before any header can point at it. On macOS plain fsync only
            //    pushes to the drive's volatile cache (survives a process/OS crash, NOT power loss);
            //    F_FULLFSYNC flushes through it, which is what makes the power-loss claim hold. Both
            //    fsyncs run on the actor executor (~1/s), never on the capture thread, so the barriers
            //    can't cause dropouts.
            AudioRecorder.fullSync(handle.fileDescriptor)
            dataBytes += pcm.count
            samplesWritten += frames
            // 3. Now patch the two size fields to cover the just-durable data (write-then-patch: a
            //    crash before step 4's fsync under-reports, never over-reports).
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: AudioRecorder.le32(UInt32(36 + dataBytes)))   // RIFF chunk size
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: AudioRecorder.le32(UInt32(dataBytes)))        // data chunk size
            // 4. Make the HEADER durable. Only after this does a power-loss reader see the new frames.
            AudioRecorder.fullSync(handle.fileDescriptor)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            markTruncated("write failed: \(error)")
        }
    }

    private func markTruncated(_ reason: String) {
        truncated = true
        buffer.removeAll(keepingCapacity: false)
        if !loggedFailure {
            loggedFailure = true
            err("listen[record]: audio retention to \(url.lastPathComponent) stopped - \(reason). " +
                "Capture continues; the manifest will mark this stream truncated.")
        }
    }

    // MARK: RIFF header construction (shared with repair-wav).

    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    /// A canonical 44-byte mono Int16 PCM WAV header. `dataBytes` is the PCM payload size; the
    /// RIFF chunk size is `36 + dataBytes`.
    static func wavHeader(sampleRate: Int, dataBytes: Int) -> Data {
        let channels = 1
        let bits = bitsPerSample
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(UInt32(36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))                         // PCM fmt chunk size
        d.append(le16(1))                          // audioFormat = PCM
        d.append(le16(UInt16(channels)))
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(byteRate)))
        d.append(le16(UInt16(blockAlign)))
        d.append(le16(UInt16(bits)))
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(UInt32(dataBytes)))
        return d
    }
}

// MARK: - The tee. Wraps a RawAudioChunk stream so every chunk is recorded (into `recorder`) and
// then forwarded through unchanged. Lives here, not in Capture.swift: the capture adapters are
// deliberately dumb pass-throughs and must stay unaware of retention. Because this wraps the
// INPUT to runStreamPipeline, only real captured chunks pass through it - the pipeline's synthetic
// end-of-stream pad is built internally from `carry` and never appears on this stream.
func recording(_ chunks: AsyncStream<RawAudioChunk>, into recorder: AudioRecorder,
               sampleRate: Double = 16000,
               onFirstChunk: (@Sendable (_ anchorEpoch: Double) async -> Void)? = nil) -> AsyncStream<RawAudioChunk> {
    AsyncStream<RawAudioChunk> { continuation in
        let task = Task {
            var seenFirst = false
            for await chunk in chunks {
                if !seenFirst {
                    seenFirst = true
                    // anchorEpoch = epoch of this stream's sample 0. epochTime is when this chunk
                    // FINISHED arriving, so back off its own duration - identical to the anchor
                    // runStreamPipeline computes, so the partial manifest and the clean manifest agree.
                    let anchor = chunk.epochTime - Double(chunk.samples.count) / sampleRate
                    await onFirstChunk?(anchor)
                }
                await recorder.append(chunk.samples)
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// One-shot holder for a stream pipeline's completion values (firstChunkEpoch, vadDesyncChunks).
/// runStreamPipeline's `onComplete` fires once, awaited before the pipeline Task returns, so by
/// the time Listen.swift has awaited both Tasks these are populated. @unchecked Sendable + a lock,
/// matching this project's other cross-thread boxes (SelfTestPipeline.Collected).
final class StreamCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var _firstChunkEpoch: TimeInterval?
    private var _vadDesyncChunks = 0

    func record(firstChunkEpoch: TimeInterval?, vadDesyncChunks: Int) {
        lock.lock(); defer { lock.unlock() }
        _firstChunkEpoch = firstChunkEpoch
        _vadDesyncChunks = vadDesyncChunks
    }
    var firstChunkEpoch: TimeInterval? { lock.lock(); defer { lock.unlock() }; return _firstChunkEpoch }
    var vadDesyncChunks: Int { lock.lock(); defer { lock.unlock() }; return _vadDesyncChunks }
}

// MARK: - Session manifest. One JSON file per recorded session, describing each retained stream
// and the epoch anchoring the offline tools need to map diarizer output (seconds from the WAV's
// start) back onto the live JSONL's epoch timeline: for a stream, epoch = anchorEpoch + seconds.
//
// `anchorEpoch` is exactly the pipeline's firstChunkEpoch for that stream (epoch of absolute
// sample 0). `vadDesyncChunks` counts chunks where VAD inference threw: runStreamPipeline does not
// advance its sample counter on such a throw (TurnPipeline.swift) while the WAV still recorded that
// chunk, so a nonzero value means the JSONL turn epochs run early relative to the WAV by that many
// 256ms chunks - which is why `diarize` refuses to reconcile a desynced session without --force.
struct SessionManifest: Codable {
    struct Stream: Codable {
        let file: String
        let anchorEpoch: Double?   // nil if the stream produced no audio (no first chunk to anchor)
        let samples: Int
        let vadDesyncChunks: Int
        let truncated: Bool
    }
    let version: Int
    let sampleRate: Int
    let startedAt: Double
    let endedAt: Double
    let streams: [String: Stream] // keyed by logical stream name ("me", "other")
    // Written by finishAndWriteManifest on CLEAN exit -> nil/false. A PARTIAL manifest (persisted as
    // soon as a stream's first chunk arrives, so a crashed session still carries anchorEpoch and is
    // reconcilable at all) sets this true. diarize warns when it sees an incomplete manifest: the
    // WAV's own patched header is authoritative for sample count; samples/vadDesyncChunks/truncated
    // here are best-effort placeholders, not the clean-shutdown truth.
    let incomplete: Bool?
}

// MARK: - RecordingSession: owns the session directory + one recorder per stream + the manifest.
// Concentrates the retention side-effects (0700 dir, 0600 files, the WAV filenames, the manifest
// shape) so Listen.swift's wiring stays about capture, not disk layout.
final class RecordingSession: @unchecked Sendable {
    static let sampleRate = 16000
    static let meFile = "me.wav"
    static let otherFile = "other.wav"
    static let manifestFile = "manifest.json"

    let dir: URL
    let me: AudioRecorder
    let other: AudioRecorder
    private let startedAt: Double

    // Anchors captured from each stream's FIRST chunk (epoch of that stream's sample 0), persisted
    // in a partial manifest the instant they're known so a crash before clean shutdown still leaves
    // a reconcilable session. Guarded by a lock: noteAnchor is called from the tee tasks.
    private let anchorLock = NSLock()
    private var anchors: [String: Double] = [:]

    private init(dir: URL, me: AudioRecorder, other: AudioRecorder, startedAt: Double) {
        self.dir = dir
        self.me = me
        self.other = other
        self.startedAt = startedAt
    }

    /// Record a stream's anchorEpoch (from its first chunk) and immediately (re)write a PARTIAL
    /// manifest. Cheap and called ~once per stream. The write is atomic so a crash mid-write cannot
    /// corrupt an already-good manifest.
    func noteAnchor(stream: String, epoch: Double) {
        // The WHOLE operation (snapshot + write) is serialized under the lock, not just the dict
        // mutation. If it weren't, two streams' first chunks could interleave so the {me}-only write
        // lands AFTER the {me,other} write (atomic renames can reorder), leaving a manifest that is
        // permanently missing other's anchor - and noteAnchor early-returns on every later chunk, so
        // it would never be corrected. Serializing guarantees the last write always reflects every
        // anchor seen so far. The file I/O is tiny and happens ~once per stream, so the held lock is
        // not a contention concern.
        anchorLock.lock()
        defer { anchorLock.unlock() }
        if anchors[stream] != nil { return } // first chunk only
        anchors[stream] = epoch

        let streams = Dictionary(uniqueKeysWithValues: [RecordingSession.meFile: "me", RecordingSession.otherFile: "other"]
            .map { (file, name) -> (String, SessionManifest.Stream) in
                (name, .init(file: file, anchorEpoch: anchors[name], samples: 0, vadDesyncChunks: 0, truncated: false))
            })
        let manifest = SessionManifest(
            version: 1, sampleRate: RecordingSession.sampleRate,
            startedAt: startedAt, endedAt: Date().timeIntervalSince1970,
            streams: streams, incomplete: true)
        let manifestURL = dir.appendingPathComponent(RecordingSession.manifestFile)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        }
    }

    /// Create the session directory (0700) and open both WAV recorders (files forced to 0600).
    /// Throws if the directory or either file can't be created - the caller treats that as "warn
    /// and run without retention", never as fatal to the meeting.
    static func create(dir dirPath: String) throws -> RecordingSession {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: dirPath)
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory only applies posixPermissions to directories it actually creates; if the
        // dir pre-existed, tighten it explicitly so a caller-supplied path isn't left world-readable.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let meURL = dir.appendingPathComponent(meFile)
        let otherURL = dir.appendingPathComponent(otherFile)
        let me = AudioRecorder(url: meURL, sampleRate: Double(sampleRate))
        let other = AudioRecorder(url: otherURL, sampleRate: Double(sampleRate))

        // Open both WAVs now (not lazily on first append): the files must exist and be 0600 before
        // capture starts so the "RECORDING AUDIO" warning is truthful. openRecorder bridges the
        // actor-isolated open() across a semaphore - see its comment for why that's safe here.
        try openRecorder(me, at: meURL)
        try openRecorder(other, at: otherURL)

        return RecordingSession(dir: dir, me: me, other: other, startedAt: Date().timeIntervalSince1970)
    }

    // AVAudioFile creation must happen on the recorder's actor executor. We bridge the one-time
    // synchronous open across the actor boundary with a semaphore - safe here because create() runs
    // during `listen` startup (not on any capture/realtime thread) and blocks only briefly.
    private static func openRecorder(_ recorder: AudioRecorder, at url: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task {
            do { try await recorder.open() } catch { box.error = error }
            sem.signal()
        }
        sem.wait()
        if let e = box.error { throw e }
        // Force 0600 on the freshly created WAV (private meeting audio).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    /// Flush + close both recorders, then write the session manifest (0600) and report the retained
    /// path and byte sizes to stderr. Must be called only after both stream pipelines have joined.
    func finishAndWriteManifest(
        me meStats: (epoch: TimeInterval?, desync: Int),
        other otherStats: (epoch: TimeInterval?, desync: Int)
    ) async {
        await me.finish()
        await other.finish()

        let meSamples = await me.samplesWritten
        let meTruncated = await me.truncated
        let otherSamples = await other.samplesWritten
        let otherTruncated = await other.truncated

        let manifest = SessionManifest(
            version: 1,
            sampleRate: RecordingSession.sampleRate,
            startedAt: startedAt,
            endedAt: Date().timeIntervalSince1970,
            streams: [
                "me": .init(file: RecordingSession.meFile, anchorEpoch: meStats.epoch,
                            samples: meSamples, vadDesyncChunks: meStats.desync, truncated: meTruncated),
                "other": .init(file: RecordingSession.otherFile, anchorEpoch: otherStats.epoch,
                               samples: otherSamples, vadDesyncChunks: otherStats.desync, truncated: otherTruncated),
            ],
            incomplete: false
        )
        let manifestURL = dir.appendingPathComponent(RecordingSession.manifestFile)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            err("listen[record]: failed to write manifest \(manifestURL.path): \(error)")
        }

        let meBytes = fileSize(dir.appendingPathComponent(RecordingSession.meFile))
        let otherBytes = fileSize(dir.appendingPathComponent(RecordingSession.otherFile))
        err("Retained audio in \(dir.path):")
        err(String(format: "  me.wav    %d samples, %@%@", meSamples, humanBytes(meBytes), meTruncated ? " (TRUNCATED)" : ""))
        err(String(format: "  other.wav %d samples, %@%@", otherSamples, humanBytes(otherBytes), otherTruncated ? " (TRUNCATED)" : ""))
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }
    private func humanBytes(_ n: Int) -> String {
        if n >= 1 << 20 { return String(format: "%.1f MiB", Double(n) / Double(1 << 20)) }
        if n >= 1 << 10 { return String(format: "%.1f KiB", Double(n) / Double(1 << 10)) }
        return "\(n) B"
    }
}
