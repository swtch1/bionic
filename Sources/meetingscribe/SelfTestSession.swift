import Foundation

// MARK: - Verifies the PARTIAL-manifest path: a session that never shuts down cleanly still leaves
// a manifest carrying each stream's anchorEpoch, so diarize can reconcile it.
//
// This is the half of the crash-safety work the SIGKILL test does NOT cover. That test drives
// AudioRecorder directly and proves the audio BYTES survive a kill. But diarize places segments on
// the transcript timeline via anchorEpoch, which lives only in the manifest - and the clean manifest
// is written only on a graceful exit. So the bytes surviving is useless if the anchor doesn't. Here
// we drive the real RecordingSession + tee (the exact path Listen.swift uses), feed one chunk per
// stream, and DELIBERATELY never call finishAndWriteManifest - simulating a crash - then assert the
// partial manifest exists with incomplete:true and a non-nil anchorEpoch for BOTH streams.
//
// Run via: swift run meetingscribe --selftest-session   (hidden subcommand, see main.swift)
func runSelfTestSession() async throws {
    func fail(_ reason: String) -> Never {
        err("SELFTEST-SESSION: FAIL - \(reason)")
        exit(1)
    }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("meetingscribe-session-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let session = try RecordingSession.create(dir: tmp.path)

    // Drive both streams through the tee concurrently, wiring noteAnchor exactly as Listen.swift does.
    // Distinct epochs per stream so we can tell they were captured independently, not cross-wired.
    func drive(_ name: String, into recorder: AudioRecorder, epoch: Double) async {
        let (s, c) = AsyncStream<RawAudioChunk>.makeStream()
        let teed = recording(s, into: recorder, sampleRate: 16000) { anchor in
            session.noteAnchor(stream: name, epoch: anchor)
        }
        // epochTime is when the chunk finished arriving; the tee back-computes anchor = epoch - dur.
        c.yield(RawAudioChunk(samples: [Float](repeating: 0.1, count: 4096), epochTime: epoch))
        c.finish()
        for await _ in teed {} // drain so the tee task processes the first chunk
    }
    async let a: Void = drive("me", into: session.me, epoch: 5000.0)
    async let b: Void = drive("other", into: session.other, epoch: 6000.0)
    _ = await (a, b)

    // NO finishAndWriteManifest() - this is the crash simulation. Whatever is on disk now is what a
    // killed session would leave.
    let manifestURL = tmp.appendingPathComponent(RecordingSession.manifestFile)
    guard let data = try? Data(contentsOf: manifestURL) else {
        fail("no manifest on disk after first chunks - a crashed session would be UN-reconcilable (diarize needs the anchor)")
    }
    let m = try JSONDecoder().decode(SessionManifest.self, from: data)
    guard m.incomplete == true else {
        fail("manifest is not marked incomplete - a partial manifest must flag that the session didn't shut down cleanly")
    }
    guard let other = m.streams["other"], let otherAnchor = other.anchorEpoch else {
        fail("partial manifest is missing other.anchorEpoch - diarize would exit 2, so the recovered audio is unreviewable")
    }
    guard let me = m.streams["me"], me.anchorEpoch != nil else {
        fail("partial manifest is missing me.anchorEpoch")
    }
    // Anchor = epochTime - chunkDuration (4096/16000 = 0.256s); other used epoch 6000.
    let expectedOther = 6000.0 - 4096.0 / 16000.0
    guard abs(otherAnchor - expectedOther) < 0.001 else {
        fail(String(format: "other.anchorEpoch %.4f != expected %.4f (anchor mis-computed)", otherAnchor, expectedOther))
    }

    err(String(format: "SELFTEST-SESSION: PASS [partial-manifest] - a session with no clean shutdown left incomplete:true with both anchors (other=%.3f); a crashed recording stays reconcilable.", otherAnchor))
    err("SELFTEST-SESSION: PASS (all cases)")
    exit(0)
}
