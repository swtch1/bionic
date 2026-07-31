import Foundation
import FluidAudio

// MARK: - `review` subcommand: put human-readable names on the anonymous speaker clusters that
// `diarize` produced. Interactive and re-runnable: it reads the diarized transcript, shows each
// still-unbound cluster (speaking time, turn count, its longest turns), asks for a name, then
// rewrites the diarized transcript in place and persists the label->name map to speakers.json.
//
// Idempotent: names already in speakers.json are applied without re-prompting, so re-running only
// asks about clusters you haven't named yet. Optional --enroll persists each newly-named cluster's
// centroid (from diarize's clusters.json sidecar) as a Speaker JSON, so the same voice auto-binds
// (via `diarize --voiceprints`) in future meetings.

func runReview() async throws {
    // MARK: CLI parsing - review <session-dir> [--play] [--enroll <dir>]
    var sessionDir: String?
    var play = false
    var enrollDir: String?
    var force = false
    var i = 2
    let args = CommandLine.arguments
    func flagValue(_ flag: String) -> String { consumeFlagValue(flag, &i, args) }
    while i < args.count {
        switch args[i] {
        case "--play": play = true; i += 1
        case "--enroll":
            // Optional value. Bare `--enroll` uses the shared default directory, which is also
            // where `diarize` looks without --voiceprints - previously the two paths were typed
            // separately every time, and pointing them at different directories silently produced
            // enrollments that nothing ever matched against.
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                enrollDir = flagValue("--enroll")
            } else {
                enrollDir = VoiceprintStore.defaultDirectory
                i += 1
            }
        case "--force": force = true; i += 1
        default:
            if sessionDir == nil { sessionDir = args[i] }
            i += 1
        }
    }
    guard let dir = sessionDir else {
        err("usage: bionic review <session-dir> [--play] [--enroll [dir]] [--force]")
        err("  --enroll with no dir stores voiceprints in \(VoiceprintStore.defaultDirectory)")
        exit(2)
    }
    let dirURL = URL(fileURLWithPath: dir)
    let diarizedURL = dirURL.appendingPathComponent("transcript.diarized.jsonl")
    guard FileManager.default.fileExists(atPath: diarizedURL.path) else {
        err("No transcript.diarized.jsonl in \(dir) - run `bionic diarize \(dir)` first.")
        exit(2)
    }

    // Load with a parse census. review REWRITES this file in place, so unlike diarize's read-only
    // load a silently-skipped line here would be permanently DESTROYED by the rewrite. And this is
    // diarize's own machine-generated output - a malformed line means something is genuinely wrong,
    // not a benign hiccup - so refuse on ANY unparseable line (no fractional threshold) unless --force.
    let load = try loadDiarizedTurns(path: diarizedURL.path)
    if load.skipped > 0 && !force {
        err("ERROR: \(load.skipped) unparseable line(s) in \(diarizedURL.lastPathComponent) (first at line \(load.firstBadLine ?? -1)).")
        err("review rewrites this file in place, so continuing would permanently drop the unparseable line(s). Your file was NOT modified.")
        err("This is diarize's own output; a malformed line means something upstream is wrong. Regenerate it with `bionic diarize \(dir) --force`, or pass --force to rewrite keeping only the parsed lines (destructive).")
        exit(2)
    }
    if load.skipped > 0 {
        err("WARNING: --force: permanently dropping \(load.skipped) unparseable line(s) (first at line \(load.firstBadLine ?? -1)) from \(diarizedURL.lastPathComponent).")
    }
    var turns = load.turns

    // Existing name bindings (idempotency): speakers.json maps a cluster label -> chosen name.
    let speakersURL = dirURL.appendingPathComponent("speakers.json")
    var nameByLabel: [String: String] = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: speakersURL))) ?? [:]

    // Clusters still needing a name: labels of the form other:N present in the transcript that are
    // not already bound in speakers.json. (Turns already rewritten to a name no longer carry an
    // other:N label, so a re-run naturally skips them.)
    let unboundLabels = orderedUnboundLabels(turns: turns, alreadyNamed: nameByLabel)
    if unboundLabels.isEmpty {
        err("No unbound speaker clusters in \(diarizedURL.lastPathComponent) - nothing to review.")
        return
    }

    // Load anchor + centroid sidecar (needed for --play slicing and --enroll persistence).
    let sidecar = try? JSONDecoder().decode(
        ClustersSidecar.self, from: Data(contentsOf: dirURL.appendingPathComponent(ClustersSidecar.fileName)))

    var newlyNamed: [String: String] = [:]
    for label in unboundLabels {
        let clusterTurns = turns.filter { $0.speaker == label }
        let totalTime = clusterTurns.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        let longest = clusterTurns.sorted { ($0.end - $0.start) > ($1.end - $1.start) }

        err("")
        err("== \(label): \(clusterTurns.count) turn(s), \(String(format: "%.1f", totalTime))s total ==")
        for (n, t) in longest.prefix(3).enumerated() {
            err("  [\(n + 1)] (\(String(format: "%.1f", t.end - t.start))s) \(t.text)")
        }

        if play, let sidecar, let longestTurn = longest.first {
            playSlice(dirURL: dirURL, otherFile: sidecar.otherFile, anchorEpoch: sidecar.anchorEpoch, turn: longestTurn)
        }

        // Prompt. Enter (or EOF, e.g. non-interactive) keeps the anonymous label.
        FileHandle.standardError.write(Data("  name for \(label) (Enter to keep \(label)): ".utf8))
        let entered = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !entered.isEmpty else {
            err("  kept \(label).")
            continue
        }
        nameByLabel[label] = entered
        newlyNamed[label] = entered
        err("  \(label) -> \(entered)")
    }

    // Rewrite the diarized transcript, applying every binding (old + new). Only the speaker field
    // changes, and only for turns whose label is now bound; start/end/text/seq stay exact.
    turns = turns.map { t in
        guard let name = nameByLabel[t.speaker] else { return t }
        // A human chose this name here in review; stamp it "manual" so a later reader can tell it
        // apart from diarize's automatic "voiceprint" binds (and from anonymous clusters).
        return DiarizedTurn(seq: t.seq, start: t.start, end: t.end, speaker: name, text: t.text,
                            final: t.final, conf: t.conf, speakers: t.speakers, bleed: t.bleed,
                            reason: t.reason, boundBy: "manual")
    }
    try writeDiarized(turns, to: diarizedURL, inSessionDir: true)

    // Persist the name map (0600).
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(nameByLabel).write(to: speakersURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: speakersURL.path)

    // Optional enrollment: persist each newly-named cluster's centroid as a Speaker JSON so this
    // person auto-binds next meeting via `diarize --voiceprints <enrollDir>`.
    if let enrollDir, !newlyNamed.isEmpty {
        guard let sidecar else {
            err("--enroll given but \(ClustersSidecar.fileName) is missing - cannot persist voiceprints without cluster centroids.")
            return
        }
        let infoByLabel = Dictionary(uniqueKeysWithValues: sidecar.clusters.map { ($0.label, $0) })
        for (label, name) in newlyNamed {
            guard let info = infoByLabel[label], !info.centroid.isEmpty else {
                err("  enroll: no centroid for \(label) - skipping \(name).")
                continue
            }
            // A sidecar written before ClusterInfo carried a duration reports nil. Treat that as
            // "long enough": a whole cluster's centroid almost always clears the threshold, and the
            // previous behavior overwrote unconditionally, so assuming eligible is strictly no worse
            // than what this replaced.
            let duration = Float(info.durationSeconds ?? Double(VoiceprintStore.minDurationForCentroidUpdate))
            do {
                // upsert, not write: re-enrolling someone REFINES their stored voiceprint
                // (weighted running centroid + recent-embedding FIFO) instead of discarding
                // everything learned in previous meetings.
                let outcome = try VoiceprintStore.upsert(
                    name: name, embedding: info.centroid, duration: duration, in: enrollDir
                )
                let path = VoiceprintStore.path(forName: name, in: enrollDir)
                switch outcome {
                case .created:
                    err("  enrolled \(name) -> \(path)")
                case .refined(let observations, let centroidMoved):
                    err(centroidMoved
                        ? "  refined \(name) -> \(path) (now \(observations) observation(s))"
                        : "  refined \(name) -> \(path) (kept as a recent sample only - \(String(format: "%.1f", duration))s is under the \(String(format: "%.1f", VoiceprintStore.minDurationForCentroidUpdate))s needed to move the centroid)")
                }
            } catch {
                err("  enroll: failed to store \(name): \(error.localizedDescription)")
            }
        }
    }

    err("")
    err("Updated \(diarizedURL.path); bindings in \(speakersURL.lastPathComponent).")
}

// MARK: - Helpers.

/// Outcome of loading the diarized JSONL: parsed turns plus a parse census (see `parseJSONL`). review
/// rewrites this file in place, so the caller MUST refuse on any skip unless --force - a dropped line
/// would be destroyed by the rewrite.
struct DiarizedLoad {
    let turns: [DiarizedTurn]
    let totalLines: Int
    let skipped: Int
    let firstBadLine: Int?
}

func loadDiarizedTurns(path: String) throws -> DiarizedLoad {
    let r = parseJSONL(try String(contentsOfFile: path, encoding: .utf8), as: DiarizedTurn.self)
    return DiarizedLoad(turns: r.values, totalLines: r.totalLines, skipped: r.skipped, firstBadLine: r.firstBadLine)
}

/// Cluster labels (other:N) present in the transcript and not yet bound, ordered by total speaking
/// time descending so the operator names the most prominent voices first.
func orderedUnboundLabels(turns: [DiarizedTurn], alreadyNamed: [String: String]) -> [String] {
    var timeByLabel: [String: Double] = [:]
    for t in turns where t.speaker.hasPrefix("other:") && alreadyNamed[t.speaker] == nil {
        timeByLabel[t.speaker, default: 0] += max(0, t.end - t.start)
    }
    return timeByLabel.keys.sorted { timeByLabel[$0]! > timeByLabel[$1]! }
}

/// Slice the given turn's audio out of other.wav and play it via afplay. Best-effort: any failure
/// (missing file, afplay absent) is logged and skipped - playback is a convenience, not core.
func playSlice(dirURL: URL, otherFile: String, anchorEpoch: Double, turn: DiarizedTurn) {
    let sampleRate = 16000
    let wavURL = dirURL.appendingPathComponent(otherFile)
    guard let all = try? AudioConverter().resampleAudioFile(path: wavURL.path) else {
        err("  (--play: could not read \(otherFile))"); return
    }
    let startSec = max(0, turn.start - anchorEpoch)
    let endSec = max(startSec, turn.end - anchorEpoch)
    let startIdx = min(all.count, Int(startSec * Double(sampleRate)))
    let endIdx = min(all.count, Int(endSec * Double(sampleRate)))
    guard endIdx > startIdx else { err("  (--play: empty slice)"); return }
    let slice = Array(all[startIdx..<endIdx])

    let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bionic-play-\(UUID().uuidString).wav")
    let rec = AudioRecorder(url: tmpURL, sampleRate: Double(sampleRate))
    let sem = DispatchSemaphore(value: 0)
    Task { try? await rec.open(); await rec.append(slice); await rec.finish(); sem.signal() }
    sem.wait()
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    err(String(format: "  (--play: %.1fs from %@)", endSec - startSec, otherFile))
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc.arguments = [tmpURL.path]
    do { try proc.run(); proc.waitUntilExit() } catch { err("  (--play: afplay failed: \(error))") }
}
