import Foundation

// MARK: - Reconciliation: assign a specific speaker cluster to each live "other" turn, offline.
//
// The live path collapses every remote participant to "other" (structural labeling - see
// Listen.swift). Post-meeting, `diarize` (Diarize.swift) runs a real diarizer over the retained
// other.wav, producing time-stamped speaker CLUSTERS. This file is the PURE decision layer that
// maps those clusters back onto the live JSONL turns: no models, no audio, no I/O - just overlap
// arithmetic over plain structs, so it is exhaustively unit-testable (SelfTestReconcile.swift).
//
// Everything here works in ONE shared timeline. The caller is responsible for expressing both the
// turns and the cluster segments in the same units before calling in (Diarize offsets diarizer
// seconds by the stream's anchorEpoch so both are epoch seconds). This function never converts.
//
// KEY INVARIANT - a turn is NEVER split across two speakers. The live JSONL is append-only and its
// `text`/`seq` are fixed; splitting a turn would require re-running ASR on sub-slices and inventing
// new seq values, breaking the handoff contract. So a turn that spans two clusters is emitted WHOLE
// with the majority cluster's label and an honest, lowered confidence - plus a `speakers` array
// disclosing the runner-up share when it's non-trivial.

/// A [start, end] interval (epoch seconds). Both diarizer segments and turns reduce to this.
struct ReconInterval {
    let start: Double
    let end: Double
}

/// One diarizer speaker cluster: a stable label ("other:1", "other:2", ...) and the set of time
/// intervals it was found speaking in (already in the turns' timeline).
struct DiarCluster {
    let label: String
    let segments: [ReconInterval]
}

/// A single cluster's share of a turn, disclosed in a reconciled turn's `speakers` array so a
/// consumer can see when a turn was contested (concurrent/adjacent speakers within one utterance).
struct SpeakerShare: Equatable {
    let speaker: String
    let share: Double // fraction of total diarized overlap on this turn, [0, 1]
}

/// The reconciliation decision for one "other" turn.
struct ReconResult: Equatable {
    let speaker: String        // assigned cluster label, or "other" when no confident assignment
    let conf: Double           // purity * coverage (clamped), [0, 1]
    let reason: String?        // nil when assigned; else "no_diar_overlap"|"low_purity"|"low_coverage"
    let speakers: [SpeakerShare]? // present only when the runner-up share >= shareDisclosureThreshold
}

let defaultPurityThreshold = 0.60
let defaultCoverageThreshold = 0.50
// Disclose the per-cluster split on a turn once the SECOND-largest cluster holds at least this
// share of the diarized overlap - i.e. the turn was meaningfully contested.
let shareDisclosureThreshold = 0.15

/// Overlap of two intervals: max(0, min(ends) - max(starts)).
func overlap(_ a: ReconInterval, _ b: ReconInterval) -> Double {
    max(0, min(a.end, b.end) - max(a.start, b.start))
}

/// Reconcile ONE "other" turn against the diarizer clusters. Pure; no side effects.
///
/// - w[c]      = total overlap between the turn and cluster c's segments.
/// - total     = sum of w over all clusters.
/// - best      = argmax w.
/// - purity    = w[best] / total          (how single-speaker the diarized overlap is)
/// - coverage  = total / turnDuration      (how much of the turn the diarizer accounts for),
///               clamped to 1.0 - concurrent speech can make raw overlap exceed the turn length.
/// - conf      = purity * coverage.
///
/// Assigns best's label iff purity >= purityThreshold AND coverage >= coverageThreshold; otherwise
/// keeps "other" with the failing reason (purity checked first). total == 0 -> keep "other",
/// conf 0, reason "no_diar_overlap".
func reconcileTurn(
    turn: ReconInterval,
    clusters: [DiarCluster],
    purityThreshold: Double = defaultPurityThreshold,
    coverageThreshold: Double = defaultCoverageThreshold
) -> ReconResult {
    let turnDuration = max(0, turn.end - turn.start)

    // Overlap mass per cluster, preserving cluster order for deterministic argmax tie-breaking.
    var weights: [(label: String, w: Double)] = []
    for c in clusters {
        var w = 0.0
        for seg in c.segments { w += overlap(turn, seg) }
        weights.append((c.label, w))
    }
    let total = weights.reduce(0) { $0 + $1.w }

    guard total > 0 else {
        return ReconResult(speaker: "other", conf: 0, reason: "no_diar_overlap", speakers: nil)
    }

    // argmax by weight; first cluster wins ties (stable, deterministic).
    var best = weights[0]
    for entry in weights.dropFirst() where entry.w > best.w { best = entry }

    let purity = best.w / total
    let coverage = turnDuration > 0 ? min(1.0, total / turnDuration) : 0
    let conf = purity * coverage

    // Disclose the split when the second-largest cluster share is non-trivial.
    let shares = weights
        .filter { $0.w > 0 }
        .map { SpeakerShare(speaker: $0.label, share: $0.w / total) }
        .sorted { $0.share > $1.share }
    let runnerUpShare = shares.count > 1 ? shares[1].share : 0
    let speakers: [SpeakerShare]? = runnerUpShare >= shareDisclosureThreshold ? shares : nil

    // Assignment gate. Purity checked first so a turn failing both reports "low_purity".
    if purity < purityThreshold {
        return ReconResult(speaker: "other", conf: conf, reason: "low_purity", speakers: speakers)
    }
    if coverage < coverageThreshold {
        return ReconResult(speaker: "other", conf: conf, reason: "low_coverage", speakers: speakers)
    }
    return ReconResult(speaker: best.label, conf: conf, reason: nil, speakers: speakers)
}
