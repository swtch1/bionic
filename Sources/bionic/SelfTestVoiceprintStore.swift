import FluidAudio
import Foundation

// MARK: - Automated verification of accumulating voiceprints (VoiceprintStore.swift).
//
// The behavior under test is the whole point of the store: enrolling the same person twice must make
// their voiceprint BETTER, not replace it. That is easy to get subtly wrong in ways nothing else
// notices - an overwrite looks identical to a merge until you check the arithmetic - so every
// expected value here is hand-computed and stated inline.
//
// Uses a scratch directory, never the real ~/.config/bionic/voiceprints.
//
// Run via: swift run bionic --selftest-voiceprintstore
func runSelfTestVoiceprintStore() async throws {
    var failures: [String] = []
    func check(_ label: String, _ cond: Bool, _ detail: String = "") {
        if !cond { failures.append("\(label)\(detail.isEmpty ? "" : ": \(detail)")") }
    }
    func close(_ a: Float, _ b: Float, _ tol: Float = 0.0001) -> Bool { abs(a - b) <= tol }

    let dir = NSTemporaryDirectory() + "bionic-vpstore-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let longEnough = VoiceprintStore.minDurationForCentroidUpdate + 1.0

    // --- 1. First enrollment creates the record. ---
    let e1: [Float] = [1.0, 0.0, 0.0, 0.0]
    let first = try VoiceprintStore.upsert(name: "Alice", embedding: e1, duration: longEnough, in: dir)
    guard case .created = first else {
        err("SELFTEST-VOICEPRINTSTORE: FAIL - first upsert reported \(first), expected .created")
        exit(1)
    }
    guard var stored = VoiceprintStore.load(name: "Alice", from: dir) else {
        err("SELFTEST-VOICEPRINTSTORE: FAIL - could not load the voiceprint just written")
        exit(1)
    }
    check("create/centroid", stored.currentEmbedding == e1, "got \(stored.currentEmbedding)")
    check("create/updateCount", stored.updateCount == 1, "got \(stored.updateCount)")
    check("create/duration", close(stored.duration, longEnough), "got \(stored.duration)")
    check("create/raws", stored.rawEmbeddings.count == 1, "got \(stored.rawEmbeddings.count)")
    check("create/permanent", stored.isPermanent)

    // --- 2. Second enrollment MERGES rather than overwrites. ---
    // Weighted running mean with existingWeight = updateCount = 1:
    //   new = (old * 1 + incoming) / 2  ->  ([1,0,0,0] + [0,1,0,0]) / 2 = [0.5, 0.5, 0, 0]
    // An overwrite would leave [0,1,0,0]; a plain unweighted average of everything ever seen would
    // also land here at n=2, which is why case 3 below uses a third observation to tell them apart.
    let e2: [Float] = [0.0, 1.0, 0.0, 0.0]
    let second = try VoiceprintStore.upsert(name: "Alice", embedding: e2, duration: longEnough, in: dir)
    if case .refined(let obs, let moved) = second {
        check("merge/observations", obs == 2, "got \(obs)")
        check("merge/centroidMoved", moved)
    } else {
        failures.append("second upsert reported \(second), expected .refined")
    }
    stored = VoiceprintStore.load(name: "Alice", from: dir)!
    check("merge/centroid",
          close(stored.currentEmbedding[0], 0.5) && close(stored.currentEmbedding[1], 0.5),
          "expected [0.5,0.5,0,0], got \(stored.currentEmbedding)")
    check("merge/duration", close(stored.duration, longEnough * 2), "got \(stored.duration)")
    check("merge/raws", stored.rawEmbeddings.count == 2, "got \(stored.rawEmbeddings.count)")

    // --- 3. Third observation is weighted by accumulated evidence, not averaged flat. ---
    // existingWeight = updateCount = 2:  new = (old * 2 + incoming) / 3
    //   = ([0.5,0.5,0,0] * 2 + [0,0,1,0]) / 3 = ([1,1,0,0] + [0,0,1,0]) / 3
    //   = [0.3333, 0.3333, 0.3333, 0]
    // A flat mean of the three raw embeddings would give the same thing here BY COINCIDENCE, so the
    // discriminating assertion is the weight itself: with existingWeight=2 the old centroid keeps
    // 2/3 of the mass. Verified directly against mergedCentroid below rather than only through the
    // file, so the weighting cannot hide behind a coincidence.
    let e3: [Float] = [0.0, 0.0, 1.0, 0.0]
    _ = try VoiceprintStore.upsert(name: "Alice", embedding: e3, duration: longEnough, in: dir)
    stored = VoiceprintStore.load(name: "Alice", from: dir)!
    check("weighted/centroid",
          close(stored.currentEmbedding[0], 1.0 / 3.0) && close(stored.currentEmbedding[2], 1.0 / 3.0),
          "expected ~[0.333,0.333,0.333,0], got \(stored.currentEmbedding)")
    check("weighted/updateCount", stored.updateCount == 3, "got \(stored.updateCount)")

    // Direct check of the weighting: heavy prior evidence must barely move.
    // (old*9 + incoming)/10 -> [0.9, 0.1]
    let heavy = VoiceprintStore.mergedCentroid(existing: [1.0, 0.0], existingWeight: 9, incoming: [0.0, 1.0])
    check("weighted/heavy-prior", close(heavy[0], 0.9) && close(heavy[1], 0.1), "got \(heavy)")

    // --- 4. Recent-embedding FIFO is capped. ---
    for i in 0..<5 {
        _ = try VoiceprintStore.upsert(
            name: "Alice", embedding: [Float(i), 0.0, 0.0, 1.0], duration: longEnough, in: dir
        )
    }
    stored = VoiceprintStore.load(name: "Alice", from: dir)!
    check("fifo/cap",
          stored.rawEmbeddings.count == VoiceprintStore.recentEmbeddingsKept,
          "expected \(VoiceprintStore.recentEmbeddingsKept), got \(stored.rawEmbeddings.count)")
    // FIFO drops the OLDEST: the survivors must be the last three pushed (i = 2,3,4).
    //
    // Compared by DIRECTION, not by component value: embeddings come back L2-normalized (the i=2
    // vector [2,0,0,1] is stored as [0.894, 0, 0, 0.447]), so an equality check on raw magnitudes
    // fails even when the FIFO is perfectly correct. Cosine distance is the meaningful comparison
    // and is what matching actually uses.
    func matchesADirection(_ v: [Float]) -> Bool {
        stored.rawEmbeddings.contains { SpeakerUtilities.cosineDistance(v, $0.embedding) < 0.001 }
    }
    check("fifo/keeps-newest",
          matchesADirection([2, 0, 0, 1]) && matchesADirection([3, 0, 0, 1]) && matchesADirection([4, 0, 0, 1]),
          "the last three pushed are not all retained: \(stored.rawEmbeddings.map(\.embedding))")
    check("fifo/drops-oldest",
          !matchesADirection([0, 0, 0, 1]) && !matchesADirection([1, 0, 0, 1]),
          "an evicted observation is still present: \(stored.rawEmbeddings.map(\.embedding))")

    // --- 5. A too-short turn does NOT move the centroid, but is still retained as an anchor. ---
    let before = stored.currentEmbedding
    let beforeCount = stored.updateCount
    let shortOutcome = try VoiceprintStore.upsert(
        name: "Alice", embedding: [9.0, 9.0, 9.0, 9.0],
        duration: VoiceprintStore.minDurationForCentroidUpdate - 0.5, in: dir
    )
    if case .refined(_, let moved) = shortOutcome {
        check("short/reports-not-moved", !moved)
    } else {
        failures.append("short upsert reported \(shortOutcome), expected .refined")
    }
    stored = VoiceprintStore.load(name: "Alice", from: dir)!
    check("short/centroid-unchanged", stored.currentEmbedding == before,
          "centroid moved from \(before) to \(stored.currentEmbedding)")
    check("short/updateCount-unchanged", stored.updateCount == beforeCount,
          "got \(stored.updateCount), expected \(beforeCount)")
    // Again by direction, not magnitude - see fifo/keeps-newest.
    check("short/still-anchored",
          stored.rawEmbeddings.contains {
              SpeakerUtilities.cosineDistance([9, 9, 9, 9], $0.embedding) < 0.001
          },
          "short observation was dropped entirely instead of kept as an anchor")

    // --- 6. Hybrid distance takes the NEAREST of centroid and recents. ---
    // A probe identical to one retained recent embedding must score ~0 even when the centroid is
    // far away - this is the case a centroid-only match would miss.
    let probe: [Float] = [4.0, 0.0, 0.0, 1.0]  // equals the i=4 raw pushed above
    let hybrid = VoiceprintStore.hybridDistance(from: probe, to: stored)
    let centroidOnly = SpeakerUtilities.cosineDistance(probe, stored.currentEmbedding)
    check("hybrid/near-zero-on-recent-match", hybrid < 0.001, "got \(hybrid)")
    check("hybrid/beats-centroid-only", hybrid < centroidOnly,
          "hybrid \(hybrid) not better than centroid-only \(centroidOnly)")

    // Dimension mismatch must be infinity, never a small number that could bind.
    let mismatched = VoiceprintStore.hybridDistance(from: [1.0, 2.0], to: stored)
    check("hybrid/dimension-mismatch-infinite", mismatched == .infinity, "got \(mismatched)")

    // --- 7. Merging across embedding dimensions is refused, not silently corrupting. ---
    do {
        _ = try VoiceprintStore.upsert(
            name: "Alice", embedding: [1.0, 2.0], duration: longEnough, in: dir
        )
        failures.append("upsert with a 2-d embedding into a 4-d voiceprint succeeded - it must throw")
    } catch is VoiceprintStoreError {
        // expected
    } catch {
        failures.append("expected VoiceprintStoreError for a dimension mismatch, got \(error)")
    }
    stored = VoiceprintStore.load(name: "Alice", from: dir)!
    check("mismatch/left-intact", stored.currentEmbedding.count == 4,
          "voiceprint was damaged by the rejected merge: \(stored.currentEmbedding)")

    // --- 8. Legacy filename from earlier `review --enroll` runs is still found. ---
    let legacyDir = dir + "/legacy"
    try FileManager.default.createDirectory(atPath: legacyDir, withIntermediateDirectories: true)
    let legacy = Speaker(name: "Bob Smith", currentEmbedding: [1, 0], duration: 5, isPermanent: true)
    try JSONEncoder().encode(legacy).write(
        to: URL(fileURLWithPath: (legacyDir as NSString).appendingPathComponent("Bob Smith.json"))
    )
    check("legacy/found", VoiceprintStore.load(name: "Bob Smith", from: legacyDir) != nil,
          "a voiceprint written under the pre-slug filename was not found, so it would be orphaned")

    guard failures.isEmpty else {
        err("SELFTEST-VOICEPRINTSTORE: FAIL")
        for f in failures { err("  - \(f)") }
        exit(1)
    }
    err("SELFTEST-VOICEPRINTSTORE: PASS - create/merge/weighting/FIFO/short-turn/hybrid-distance/dimension-guard/legacy-filename")
    exit(0)
}
