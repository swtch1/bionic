import Foundation

// MARK: - Accuracy metrics: DER (diarization) and WER (transcription).
//
// Why these exist: every other self-test in this project verifies PLUMBING - turns come out in
// order, a crash-truncated WAV gets repaired, a path is shaped right. None of them notice if
// diarization or transcription gets WORSE. A VAD threshold tweak or a model swap can degrade
// accuracy while every test stays green. These two functions turn "did it get worse" into a number
// that a baseline file can ratchet against.
//
// The numbers are only meaningful against fixtures with known ground truth - see `make-fixture`,
// which synthesizes audio from `say` so the reference transcript and speaker boundaries are exact
// by construction rather than hand-labelled.

/// One ground-truth speech region: who spoke, when, and what they said.
struct TruthSegment: Codable, Sendable {
    let speaker: String
    let start: Double
    let end: Double
    let text: String
}

/// A hypothesis region produced by the pipeline (a diarized turn).
struct HypSegment: Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

enum QualityMetrics {
    /// Frame size for DER accounting. 10ms is the NIST/`pyannote` convention; small enough that
    /// boundary error is dominated by real disagreement rather than quantization.
    static let frameSeconds = 0.01

    /// Diarization Error Rate: (missed speech + false alarm + speaker confusion) / total reference
    /// speech, computed on a 10ms frame grid.
    ///
    /// Speaker LABELS are arbitrary - a diarizer calling someone "speaker_2" when the reference
    /// calls them "alice" is not an error, so hypothesis labels are first mapped onto reference
    /// labels by whichever assignment maximizes agreement. With meeting-sized speaker counts the
    /// mapping is found by brute force over permutations (exact, no Hungarian implementation
    /// needed); above `maxLabelsForExactMapping` it falls back to a greedy assignment so this can
    /// never blow up on pathological input.
    ///
    /// Single-label-per-frame: the reference grid keeps one speaker per frame (last writer wins on
    /// overlap). Real overlapped speech is therefore scored approximately - acceptable here because
    /// our fixtures are non-overlapping by construction, and noted so a future overlapping fixture
    /// does not get silently mis-scored.
    static let maxLabelsForExactMapping = 7

    static func der(reference: [TruthSegment], hypothesis: [HypSegment]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0.0 : 1.0 }

        let end = max(
            reference.map(\.end).max() ?? 0,
            hypothesis.map(\.end).max() ?? 0
        )
        let frameCount = Int((end / frameSeconds).rounded(.up)) + 1
        guard frameCount > 0 else { return 0.0 }

        // nil = silence in that frame.
        var refGrid = [String?](repeating: nil, count: frameCount)
        var hypGrid = [String?](repeating: nil, count: frameCount)

        func paint(_ grid: inout [String?], _ speaker: String, _ start: Double, _ end: Double) {
            guard end > start else { return }
            let from = max(0, Int((start / frameSeconds).rounded()))
            let to = min(frameCount - 1, Int((end / frameSeconds).rounded()) - 1)
            guard from <= to else { return }
            for i in from...to { grid[i] = speaker }
        }
        for s in reference { paint(&refGrid, s.speaker, s.start, s.end) }
        for s in hypothesis { paint(&hypGrid, s.speaker, s.start, s.end) }

        let totalRefSpeech = refGrid.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        guard totalRefSpeech > 0 else { return hypGrid.contains(where: { $0 != nil }) ? 1.0 : 0.0 }

        let hypLabels = Array(Set(hypGrid.compactMap { $0 })).sorted()
        let refLabels = Array(Set(refGrid.compactMap { $0 })).sorted()

        // Agreement count for a given hyp->ref label mapping.
        func errors(mapping: [String: String]) -> Int {
            var wrong = 0
            for i in 0..<frameCount {
                let r = refGrid[i]
                let rawH = hypGrid[i]
                // `mapped` is nil in two very different situations - the hypothesis was silent
                // here, or it named a speaker that the mapping left unmatched. Collapsing those
                // two loses every false alarm (an unmapped label reads as silence, silence-vs-
                // silence is skipped, and the error disappears), so `rawH` decides presence and
                // `mapped` only decides identity.
                let mapped = rawH.flatMap { mapping[$0] }
                switch (r, rawH) {
                case (nil, nil):
                    continue                                // agreed silence: not scored
                case (nil, _):
                    wrong += 1                              // false alarm
                case (_, nil):
                    wrong += 1                              // missed speech
                default:
                    if r != mapped { wrong += 1 }           // confusion (incl. unmapped hyp label)
                }
            }
            return wrong
        }

        var best: Int
        if hypLabels.count <= maxLabelsForExactMapping && refLabels.count <= maxLabelsForExactMapping {
            best = Int.max
            for perm in assignments(hypLabels: hypLabels, refLabels: refLabels) {
                best = min(best, errors(mapping: perm))
            }
            if best == Int.max { best = errors(mapping: [:]) }
        } else {
            // Greedy: give each hyp label the ref label it co-occurs with most, without reuse.
            var counts: [String: [String: Int]] = [:]
            for i in 0..<frameCount {
                guard let h = hypGrid[i], let r = refGrid[i] else { continue }
                counts[h, default: [:]][r, default: 0] += 1
            }
            var used = Set<String>()
            var mapping: [String: String] = [:]
            for h in hypLabels.sorted(by: { (counts[$0]?.values.max() ?? 0) > (counts[$1]?.values.max() ?? 0) }) {
                if let r = counts[h]?.sorted(by: { $0.value > $1.value }).first(where: { !used.contains($0.key) })?.key {
                    mapping[h] = r
                    used.insert(r)
                }
            }
            best = errors(mapping: mapping)
        }

        return Double(best) / Double(totalRefSpeech)
    }

    /// All injective hyp->ref label mappings. Unmapped hyp labels count as confusion, which is the
    /// correct treatment for a diarizer that invented an extra speaker.
    private static func assignments(hypLabels: [String], refLabels: [String]) -> [[String: String]] {
        guard !hypLabels.isEmpty, !refLabels.isEmpty else { return [[:]] }
        var out: [[String: String]] = []
        func recurse(_ index: Int, _ remaining: [String], _ current: [String: String]) {
            if index == hypLabels.count { out.append(current); return }
            // Option: leave this hyp label unmapped (it becomes error frames).
            recurse(index + 1, remaining, current)
            for (i, r) in remaining.enumerated() {
                var next = current
                next[hypLabels[index]] = r
                var rest = remaining
                rest.remove(at: i)
                recurse(index + 1, rest, next)
            }
        }
        recurse(0, refLabels, [:])
        return out
    }

    /// Word Error Rate: Levenshtein edit distance over word tokens / reference word count.
    ///
    /// Normalization is deliberately aggressive (lowercase, strip punctuation, collapse
    /// whitespace): ASR casing and punctuation choices are not what this metric is meant to police,
    /// and leaving them in makes the number swing on cosmetics.
    static func wer(reference: String, hypothesis: String) -> Double {
        let ref = tokenize(reference)
        let hyp = tokenize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }
        // Every reference word deleted. Also guards the `1...hyp.count` loop below, which would
        // trap on an empty hypothesis.
        guard !hyp.isEmpty else { return 1.0 }

        // Two-row Levenshtein: O(min) memory, and these are sentence-length inputs.
        var prev = Array(0...hyp.count)
        var cur = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            cur[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
