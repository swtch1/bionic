import FluidAudio
import Foundation

// MARK: - Cross-meeting speaker identity that IMPROVES with use.
//
// What was already here: `review --enroll <dir>` writes one Speaker JSON per named cluster, and
// `diarize --voiceprints <dir>` binds later meetings against them. So identity already carried
// forward - this is not new capability.
//
// What was wrong with it:
//   1. Enrolling the same person again OVERWROTE their voiceprint with whatever a single meeting's
//      centroid happened to be. Five meetings of evidence were worth exactly as much as the last
//      one, and a bad centroid (short turn, crosstalk) silently replaced a good one.
//   2. `Speaker` already carries `updateCount`, `duration` and `rawEmbeddings` - all of which we
//      left at their defaults (1, 0, empty). The accumulation fields existed and went unused.
//   3. Both directories had to be passed by hand, and nothing checked that the enroll directory
//      and the voiceprint directory were the same one. Point them at different paths - easy, since
//      each is typed separately - and enrollment appears to work while binding silently never sees
//      it.
//
// This file fixes all three: a default location both sides agree on, and an upsert that merges new
// evidence into an existing voiceprint instead of clobbering it.
enum VoiceprintStore {
    /// Where voiceprints live when no directory is given. Alongside `transcripts/` under the same
    /// config root, so one `~/.config/bionic` holds everything stateful.
    static var defaultDirectory: String {
        NSHomeDirectory() + "/.config/bionic/voiceprints"
    }

    /// How many recent per-meeting embeddings to keep alongside the running centroid.
    ///
    /// The centroid is a mean, so it drifts toward the average recording condition and can end up
    /// closer to nobody in particular. Keeping a few recent raw embeddings and matching against the
    /// NEAREST of {centroid, recents} recovers the case where someone sounds distinctly different
    /// today (new headset, a cold) but identical to how they sounded last week.
    static let recentEmbeddingsKept = 3

    /// Minimum speech duration before a meeting's centroid is allowed to move the stored centroid.
    ///
    /// A two-second turn produces an embedding dominated by whichever phonemes happened to occur.
    /// Below this it still gets appended to the recent-FIFO (useful as a nearest-match anchor) but
    /// is not averaged into the long-term identity, so one clipped turn cannot degrade a voiceprint
    /// built from hours of audio.
    static let minDurationForCentroidUpdate: Float = 3.0

    /// Distance from `embedding` to a stored speaker: the nearest of the running centroid and each
    /// retained recent embedding. Lower is closer. See `recentEmbeddingsKept` for why the minimum
    /// rather than just the centroid.
    ///
    /// Returns `.infinity` for a dimension mismatch, matching `cosineDistance`'s own behavior, so a
    /// voiceprint enrolled with a different embedding model can never accidentally bind.
    static func hybridDistance(from embedding: [Float], to speaker: Speaker) -> Float {
        var best = Float.infinity
        if !speaker.currentEmbedding.isEmpty {
            best = min(best, SpeakerUtilities.cosineDistance(embedding, speaker.currentEmbedding))
        }
        for raw in speaker.rawEmbeddings where !raw.embedding.isEmpty {
            best = min(best, SpeakerUtilities.cosineDistance(embedding, raw.embedding))
        }
        return best
    }

    /// Weighted running mean of two embeddings. `existingWeight` is how many observations the
    /// existing centroid already represents, so early evidence is not swamped by a single new
    /// meeting and late evidence cannot swing an established identity.
    static func mergedCentroid(
        existing: [Float], existingWeight: Int, incoming: [Float]
    ) -> [Float] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty, existing.count == incoming.count else { return existing }
        let w = Float(max(existingWeight, 1))
        let total = w + 1
        return zip(existing, incoming).map { ($0 * w + $1) / total }
    }

    /// File a voiceprint is stored in. Name-derived, so re-enrolling the same person finds their
    /// existing record rather than creating a second one.
    static func path(forName name: String, in directory: String) -> String {
        (directory as NSString).appendingPathComponent("\(slugify(name)).json")
    }

    /// Load one speaker by name, if present. Tolerates the pre-slug filename (`<name>.json`) that
    /// earlier `review --enroll` runs wrote, so existing enrollments are still found and upgraded
    /// in place rather than orphaned.
    static func load(name: String, from directory: String) -> Speaker? {
        let candidates = [
            path(forName: name, in: directory),
            (directory as NSString).appendingPathComponent("\(name).json"),
        ]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)),
                  let speaker = try? JSONDecoder().decode(Speaker.self, from: data)
            else { continue }
            return speaker
        }
        return nil
    }

    /// Result of an upsert, for reporting to the user - "enrolled" and "refined from 4 meetings"
    /// deserve different messages.
    enum Outcome {
        case created
        case refined(observations: Int, centroidMoved: Bool)
    }

    /// Merge one meeting's evidence for `name` into the store, creating the record if absent.
    ///
    /// Idempotent in shape but not in content: calling it twice with the same embedding legitimately
    /// records two observations, because two meetings agreeing IS additional evidence.
    @discardableResult
    static func upsert(
        name: String,
        embedding: [Float],
        duration: Float,
        in directory: String
    ) throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let outcome: Outcome
        let speaker: Speaker

        if let existing = load(name: name, from: directory) {
            // Dimension mismatch means a different embedding model produced this. Averaging across
            // models is meaningless, so refuse rather than silently corrupting a good voiceprint.
            if !existing.currentEmbedding.isEmpty,
               existing.currentEmbedding.count != embedding.count {
                throw VoiceprintStoreError.dimensionMismatch(
                    name: name, stored: existing.currentEmbedding.count, incoming: embedding.count
                )
            }

            let mayUpdateCentroid = duration >= minDurationForCentroidUpdate
            var updated = existing
            if mayUpdateCentroid {
                updated.currentEmbedding = mergedCentroid(
                    existing: existing.currentEmbedding,
                    existingWeight: existing.updateCount,
                    incoming: embedding
                )
                updated.updateCount = existing.updateCount + 1
            }
            // The raw FIFO takes every observation, including short ones - they are useful as
            // nearest-match anchors even when too noisy to average in.
            var raws = existing.rawEmbeddings
            raws.append(RawEmbedding(segmentId: UUID(), embedding: embedding, timestamp: Date()))
            if raws.count > recentEmbeddingsKept {
                raws.removeFirst(raws.count - recentEmbeddingsKept)
            }
            updated.rawEmbeddings = raws
            updated.duration = existing.duration + duration
            updated.updatedAt = Date()
            updated.isPermanent = true
            speaker = updated
            outcome = .refined(observations: updated.updateCount, centroidMoved: mayUpdateCentroid)
        } else {
            var fresh = Speaker(
                name: name, currentEmbedding: embedding, duration: duration, isPermanent: true
            )
            fresh.rawEmbeddings = [
                RawEmbedding(segmentId: UUID(), embedding: embedding, timestamp: Date())
            ]
            speaker = fresh
            outcome = .created
        }

        // Atomic write: a crash mid-save must not leave a truncated voiceprint that decodes to a
        // garbage embedding and then mis-binds every future meeting.
        let finalPath = path(forName: name, in: directory)
        let tmpPath = finalPath + ".tmp"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(speaker).write(to: URL(fileURLWithPath: tmpPath))
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath)
        _ = try fm.replaceItemAt(
            URL(fileURLWithPath: finalPath), withItemAt: URL(fileURLWithPath: tmpPath)
        )
        return outcome
    }
}

enum VoiceprintStoreError: Error, LocalizedError {
    case dimensionMismatch(name: String, stored: Int, incoming: Int)

    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let name, let stored, let incoming):
            return """
                voiceprint for '\(name)' is \(stored)-dimensional but this meeting produced \
                \(incoming)-dimensional embeddings - a different embedding model. Refusing to merge \
                (it would corrupt the stored voiceprint). Delete the old one to re-enroll from \
                scratch.
                """
        }
    }
}
