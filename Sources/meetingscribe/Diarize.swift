import Foundation
import FluidAudio

// MARK: - `diarize` subcommand: offline per-speaker attribution for a recorded session.
//
// Runs the OFFLINE diarizer stack (OfflineDiarizerManager - the SAME stack `enroll` uses, so
// centroids live in the same embedding space as enrolled voiceprints; mixing stacks would make
// voiceprint comparison meaningless) over the retained other.wav, then reconciles its speaker
// clusters back onto the live JSONL turns via the pure Reconcile layer. Emits a NEW file,
// transcript.diarized.jsonl, with the SAME seq values 1:1 - the live JSONL is append-only and is
// never touched (the handoff contract requires it).
//
// ONLY other.wav is diarized. The mic stream is structurally "me" and must pass through byte-
// identical - re-diarizing it would invent speakers for a single known person.

// A diarized turn: the live Turn's 7 fields (seq/start/end/text/final preserved exactly), with
// speaker/conf possibly rewritten for "other" turns, plus optional disclosure fields. The optionals
// encode only when present (JSONEncoder omits nil), so a diarized line stays a strict superset of
// the live schema.
struct DiarizedTurn: Codable {
    let seq: Int
    let start: Double
    let end: Double
    let speaker: String
    let text: String
    let final: Bool
    let conf: Double
    let speakers: [SpeakerShareCodable]? // per-cluster split when the turn was contested
    let bleed: Bool?                     // true when the assigned cluster looks like the enrolled "me"
    let reason: String?                  // why a turn stayed "other" (no_diar_overlap|low_purity|low_coverage)
    let boundBy: String?                 // HOW this turn's speaker name was chosen: "voiceprint" (auto-bound
                                         // by diarize from --voiceprints) | "manual" (a human named it in
                                         // review) | nil (still an anonymous other:N cluster, or me/unknown
                                         // passthrough). Lets a wrong auto-bind be told apart from a human
                                         // decision after the fact instead of being indistinguishable.
}

// MARK: - Cluster -> speaker binding (pure decision, unit-testable without models).
//
// A named voiceprint dir (Speaker JSONs from `enroll`, one possibly named "me") lets diarize put
// real names on clusters automatically - the whole payoff of the feature: name someone once and they
// resolve forever after, instead of sitting through review every meeting. This is the pure core; the
// caller computes cosine distances and hands them here.

/// Default clear-margin a cluster's nearest named voiceprint must beat the runner-up by before we
/// commit a name. ~half the dMe..dOther ambiguous band. A fixed binding internal, not a CLI flag.
let defaultBindMargin: Float = 0.10

/// Outcome of matching one cluster centroid against the enrolled voiceprints.
enum ClusterBinding: Equatable {
    case bleed            // matched the enrolled "me" voiceprint -> label "me?" (bleed), never hard "me"
    case bound(String)    // matched exactly one named voiceprint with a clear margin -> that name
    case unmatched        // no confident/unambiguous match -> stays other:N
}

/// Decide a cluster's binding from its cosine distances to every enrolled voiceprint. Two SEPARATE
/// checks in one pass (per the design):
///   - bleed: nearest "me"-named print within dMe (NO margin) -> .bleed. Bleed is a soft "me?"
///     warning, not a hard claim, so it stays as sensitive as the shipped detector. It OVERRIDES
///     binding: a cluster within dMe of both "me" and a colleague is more likely the user's own voice
///     bleeding into system audio than the colleague's, and mislabeling your words as theirs is the
///     worse error - "me?" is review-reversible, a wrong name is silently wrong.
///   - bind: among prints whose name is NOT reserved, the nearest within dMe AND beating the
///     runner-up by >= margin -> .bound(name). RESERVED names (me / other / unknown, and anything
///     shaped like the cluster label other:N) are excluded as bind targets: binding a cluster to a
///     print literally named "other" would emit speaker:"other", indistinguishable from an
///     unreconciled turn; "me" is owned by the structural mic-stream claim; "unknown" is a sentinel.
///     An ambiguous near-tie stays other:N rather than guessing.
/// "me" is matched case-insensitively on the voiceprint's name (enroll's default is NAME=me).
let reservedBindNames: Set<String> = ["me", "other", "unknown"]

func isReservedBindName(_ name: String) -> Bool {
    let l = name.lowercased()
    return reservedBindNames.contains(l) || l.hasPrefix("other:")
}

func decideBinding(distances: [(name: String, dist: Float)], dMe: Float, margin: Float) -> ClusterBinding {
    let bleedDist = distances.filter { $0.name.lowercased() == "me" }.map { $0.dist }.min() ?? .infinity
    if bleedDist < dMe { return .bleed }

    let candidates = distances.filter { !isReservedBindName($0.name) }.sorted { $0.dist < $1.dist }
    guard let nearest = candidates.first, nearest.dist < dMe else { return .unmatched }
    if candidates.count >= 2 && (candidates[1].dist - nearest.dist) < margin { return .unmatched }
    return .bound(nearest.name)
}

// Codable mirror of Reconcile's SpeakerShare (that one is a pure-layer value type with no Codable
// dependency; keeping them separate avoids coupling the pure module to the wire format).
struct SpeakerShareCodable: Codable {
    let speaker: String
    let share: Double
}

// Sidecar written by `diarize`, consumed by `review`: cluster centroids + the epoch anchor and
// source WAV needed to slice audio for playback and to persist named-cluster voiceprints.
struct ClusterInfo: Codable {
    let label: String
    let centroid: [Float]
}
struct ClustersSidecar: Codable {
    static let fileName = "clusters.json"
    let anchorEpoch: Double
    let otherFile: String
    let clusters: [ClusterInfo]
}

func runDiarize() async throws {
    // MARK: CLI parsing - diarize <session-dir> [--transcript <path>] [--voiceprints <path...>]
    //                             [--purity <f>] [--coverage <f>] [--force]
    var sessionDir: String?
    var transcriptPath: String?
    var voiceprintPaths: [String] = []
    var purity = defaultPurityThreshold
    var coverage = defaultCoverageThreshold
    // Known headcount is the single highest-leverage accuracy lever: "there are N people on this
    // call" constrains clustering directly. --speakers N pins the exact count, --max-speakers N caps
    // it; mutually exclusive (numSpeakers overrides min/max in the diarizer anyway, so allowing both
    // would silently ignore the cap - error instead).
    var exactSpeakers: Int?
    var maxSpeakers: Int?
    var force = false
    var i = 2
    let args = CommandLine.arguments
    func flagValue(_ flag: String) -> String { consumeFlagValue(flag, &i, args) }
    while i < args.count {
        switch args[i] {
        case "--transcript": transcriptPath = flagValue("--transcript")
        case "--voiceprints":
            // Accepts a directory of Speaker JSONs, or one/more explicit files. Consume the single
            // following token; a directory expands to its *.json contents.
            voiceprintPaths.append(flagValue("--voiceprints"))
        case "--purity": purity = Double(flagValue("--purity")) ?? purity
        case "--coverage": coverage = Double(flagValue("--coverage")) ?? coverage
        case "--speakers":
            guard let n = Int(flagValue("--speakers")), n > 0 else { err("--speakers needs a positive integer"); exit(2) }
            exactSpeakers = n
        case "--max-speakers":
            guard let n = Int(flagValue("--max-speakers")), n > 0 else { err("--max-speakers needs a positive integer"); exit(2) }
            maxSpeakers = n
        case "--force": force = true; i += 1
        default:
            if sessionDir == nil { sessionDir = args[i] }
            i += 1
        }
    }
    guard let dir = sessionDir else {
        err("usage: meetingscribe diarize <session-dir> [--transcript <path>] [--voiceprints <dir|file>] [--speakers <N> | --max-speakers <N>] [--purity <f>] [--coverage <f>] [--force]")
        exit(2)
    }
    if exactSpeakers != nil && maxSpeakers != nil {
        err("--speakers (exact) and --max-speakers (upper bound) are mutually exclusive - pass one or the other.")
        exit(2)
    }
    let dirURL = URL(fileURLWithPath: dir)

    // MARK: Load the manifest and validate the 'other' stream is reconcilable.
    let manifestURL = dirURL.appendingPathComponent(RecordingSession.manifestFile)
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
        err("No session manifest at \(manifestURL.path) - is this a --record session directory?"); exit(2)
    }
    let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)
    guard let other = manifest.streams["other"], let anchorEpoch = other.anchorEpoch else {
        err("Manifest has no anchorEpoch for the 'other' stream (no system audio was captured) - nothing to diarize."); exit(2)
    }
    if manifest.incomplete == true {
        // A PARTIAL manifest: the session did not shut down cleanly (crash / SIGKILL / power loss).
        // anchorEpoch is trustworthy (persisted from the first chunk), so reconciliation still works,
        // but the clean-shutdown fields (vadDesyncChunks, truncated) are placeholders, and the tail
        // of the recording past the last flush may be missing.
        err("NOTE: this session's manifest is INCOMPLETE - it terminated abnormally (crash/kill/power loss) rather than stopping cleanly.")
        err("      Diarization will proceed from the recovered audio + anchor, but the last few seconds before termination may be absent.")
    }
    if other.vadDesyncChunks > 0 && !force {
        err("The 'other' stream has \(other.vadDesyncChunks) VAD-desync chunk(s): live turn epochs run ~\(other.vadDesyncChunks)*256ms early relative to other.wav, so reconciliation would be misaligned.")
        err("Re-run with --force to proceed anyway (attribution near desync points will be less trustworthy).")
        exit(2)
    }
    if other.truncated {
        err("WARNING: other.wav was marked TRUNCATED during capture - some system audio is missing; attribution over the gap will be incomplete.")
    }
    let otherWavURL = dirURL.appendingPathComponent(other.file)
    guard FileManager.default.fileExists(atPath: otherWavURL.path) else {
        err("other.wav not found at \(otherWavURL.path)."); exit(2)
    }
    // Abnormal-termination diagnostic: if the WAV's own header under-reports its on-disk data, the
    // recording was killed after PCM hit disk but before the header was patched (or was written by
    // an older AVAudioFile-based build that only wrote the header on close). The audio is physically
    // present; only the size fields lie - so say THAT explicitly rather than letting the diarizer
    // read a header-truncated file and later report "found no speech". This is a header-vs-on-disk
    // check on purpose: an abnormal exit leaves no clean manifest, so a manifest-vs-header check
    // could not fire in the very case it targets.
    if let wav = inspectWav(path: otherWavURL.path), wav.diskDataBytes > wav.headerDataBytes + 1024 {
        let hdrFrames = wav.headerDataBytes / 2, diskFrames = wav.diskDataBytes / 2
        err("WARNING: \(other.file)'s header reports \(hdrFrames) frames but \(diskFrames) frames of audio are physically on disk.")
        err("         The session likely terminated abnormally, leaving the header under-reporting its length. The audio is intact.")
        err("         Recover it first:  meetingscribe repair-wav \(otherWavURL.path)")
        if !force {
            err("         Diarizing now would only see the \(hdrFrames) frames the header admits. Run repair-wav, or pass --force to diarize the truncated view.")
            exit(2)
        }
    }

    // MARK: Resolve transcript + output paths. Default the live transcript to <session-dir>/
    // transcript.jsonl; the diarized output always sits beside it as transcript.diarized.jsonl.
    let transcript = transcriptPath ?? dirURL.appendingPathComponent("transcript.jsonl").path
    guard FileManager.default.fileExists(atPath: transcript) else {
        err("No live transcript at \(transcript). Pass --transcript <path> pointing at the JSONL that listen wrote.")
        exit(2)
    }
    let outURL = dirURL.appendingPathComponent("transcript.diarized.jsonl")
    let existingOutSize = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? Int) ?? 0
    if FileManager.default.fileExists(atPath: outURL.path), existingOutSize > 0, !force {
        err("\(outURL.path) already exists and is non-empty. Refusing to overwrite; re-run with --force to replace it."); exit(2)
    }

    let load = try loadTurns(path: transcript)
    let turns = load.turns
    if load.skipped > 0 {
        // Silent data loss in a reconciliation tool is the wrong default: warn with the count and
        // the first offending line so the operator can find it.
        err("WARNING: \(load.skipped) of \(load.totalLines) transcript line(s) failed to parse (first at line \(load.firstBadLine ?? -1)) - those turns are absent from the diarized output.")
        // If more than a trivial fraction is unparseable, something upstream is broken; a
        // confident-looking diarized file built from a fraction of the turns is worse than stopping.
        let refuseThreshold = 0.05
        let frac = load.totalLines > 0 ? Double(load.skipped) / Double(load.totalLines) : 0
        if frac > refuseThreshold && !force {
            err(String(format: "That is %.0f%% of the transcript (> %.0f%% unparseable threshold). Refusing to diarize a substantially broken transcript; re-run with --force to proceed with only the lines that parsed.", frac * 100, refuseThreshold * 100))
            exit(2)
        }
    }
    err("Loaded \(turns.count) live turn(s) from \(transcript).")

    // MARK: Diarize other.wav via the offline stack. URL overload = memory-mapped streaming, so an
    // hour of audio isn't materialized as one giant [Float]. Progress -> stderr.
    err("Diarizing \(other.file) (offline stack; first run downloads models)...")
    var diarConfig = OfflineDiarizerConfig()
    if let n = exactSpeakers {
        diarConfig = diarConfig.withSpeakers(exactly: n)
        err("Constraining diarization to exactly \(n) speaker(s).")
    } else if let n = maxSpeakers {
        diarConfig = diarConfig.withSpeakers(min: nil, max: n)
        err("Constraining diarization to at most \(n) speaker(s).")
    }
    let diar = OfflineDiarizerManager(config: diarConfig)
    try await diar.prepareModels()
    let diarResult = try await diar.process(otherWavURL) { done, total in
        if total > 0 { FileHandle.standardError.write(Data("\rdiarize: chunk \(done)/\(total)".utf8)) }
    }
    FileHandle.standardError.write(Data("\n".utf8))

    guard !diarResult.segments.isEmpty else {
        err("Diarizer found no speech in \(other.file) - copying live turns through unchanged.")
        try writeDiarized(turns.map { passthrough($0) }, to: outURL, inSessionDir: true)
        err("Wrote \(turns.count) turn(s) to \(outURL.path) (no reclustering).")
        return
    }

    // MARK: Build clusters. Group all segments by diarizer speakerId; order speakerIds by total
    // speaking time DESCENDING and assign stable labels other:1..N. Offset every segment into the
    // live epoch timeline (epoch = anchorEpoch + seconds) so Reconcile compares like with like.
    var segmentsById: [String: [TimedSpeakerSegment]] = [:]
    var durationById: [String: Float] = [:]
    for seg in diarResult.segments {
        segmentsById[seg.speakerId, default: []].append(seg)
        durationById[seg.speakerId, default: 0] += seg.durationSeconds
    }
    let orderedIds = durationById.keys.sorted { durationById[$0]! > durationById[$1]! }
    var labelById: [String: String] = [:]
    var clusters: [DiarCluster] = []
    var centroidByLabel: [String: [Float]] = [:]
    for (idx, sid) in orderedIds.enumerated() {
        let label = "other:\(idx + 1)"
        labelById[sid] = label
        let segs = segmentsById[sid]!
        clusters.append(DiarCluster(label: label, segments: segs.map {
            ReconInterval(start: anchorEpoch + Double($0.startTimeSeconds), end: anchorEpoch + Double($0.endTimeSeconds))
        }))
        centroidByLabel[label] = durationWeightedMeanEmbedding(segs.map { (embedding: $0.embedding, duration: $0.durationSeconds) })
    }
    err("Diarizer found \(orderedIds.count) speaker cluster(s): " +
        orderedIds.enumerated().map { "other:\($0.offset + 1)=\(String(format: "%.1f", durationById[$0.element]!))s" }.joined(separator: ", "))

    // MARK: Optional auto-labeling + bleed detection from enrolled voiceprints. Load the named
    // Speaker JSONs; for each cluster centroid, take its cosine distance to every voiceprint and run
    // the pure decideBinding decision (see its doc): a confident, unambiguous match to a NAMED person
    // binds the cluster to that name (source "voiceprint"); a match to the enrolled "me" is the bleed
    // case ("me?" + bleed:true, never a hard "me"); anything ambiguous or far stays other:N. This is
    // the payoff of the whole feature - name someone once via review --enroll and they resolve
    // automatically in every later meeting, with no interactive prompt.
    let voiceprints = loadVoiceprints(voiceprintPaths)
    // A voiceprint named with a RESERVED word (other / unknown / an other:N label) can never bind a
    // cluster - decideBinding excludes those names as targets - so it would silently do nothing.
    // "me" is exempt: it legitimately drives bleed detection. Warn rather than ignore in silence.
    let reservedPrints = voiceprints.filter { isReservedBindName($0.name) && $0.name.lowercased() != "me" }
    if !reservedPrints.isEmpty {
        err("WARNING: \(reservedPrints.count) voiceprint(s) use a reserved name and will be IGNORED for binding (\(reservedPrints.map { $0.name }.joined(separator: ", "))).")
        err("         Reserved names (other, unknown, other:N) collide with diarize's own labels; re-enroll these people under a distinct name.")
    }
    var nameByLabel: [String: String] = [:]  // cluster label -> bound person name (source: voiceprint)
    var bleedLabels: Set<String> = []
    if !voiceprints.isEmpty {
        // Dimension-mismatch trap (same one enroll/run guard against): a voiceprint from a different
        // embedding-model version silently cosine-distances to .infinity against every cluster and so
        // matches NOTHING, with no signal. Warn loudly, once, naming the offenders.
        if let segDim = diarResult.segments.first?.embedding.count {
            let mismatched = voiceprints.filter { $0.embedding.count != segDim }
            if !mismatched.isEmpty {
                printBoxedWarning([
                    "# WARNING: \(mismatched.count) voiceprint(s) have an embedding dimension !=       ",
                    "# the diarizer's (\(segDim)). cosineDistance is .infinity for those, so they will ",
                    "# match NO cluster and auto-labeling silently does nothing for them:              ",
                ] + mismatched.map { "#   \($0.name) (\($0.embedding.count)-d)" } + [
                    "# Re-enroll them with the same embedding model/version as this diarizer.          ",
                ])
            }
        }
        for (label, centroid) in centroidByLabel {
            let distances = voiceprints.map { (name: $0.name, dist: SpeakerUtilities.cosineDistance(centroid, $0.embedding)) }
            switch decideBinding(distances: distances, dMe: dMe, margin: defaultBindMargin) {
            case .bleed:
                bleedLabels.insert(label)
                let d = distances.filter { $0.name.lowercased() == "me" }.map { $0.dist }.min() ?? .infinity
                err(String(format: "  bleed: %@ centroid within dMe (%.3f < %.2f) of the enrolled 'me' -> labeling its turns 'me?'.", label, d, dMe))
            case .bound(let name):
                nameByLabel[label] = name
                let d = distances.first(where: { $0.name == name })?.dist ?? .infinity
                err(String(format: "  bound: %@ -> '%@' (dist %.3f < dMe %.2f, clear margin) via voiceprint.", label, name, d, dMe))
            case .unmatched:
                break // stays other:N; review can name it interactively
            }
        }
    }

    // MARK: Reconcile each turn. Non-"other" turns pass through byte-identical (me/unknown are not
    // the diarizer's business). "other" turns get the pure overlap decision; a turn assigned to a
    // bleed cluster is relabeled "me?" with bleed:true.
    // Map a cluster label to its display speaker: a bleed cluster shows "me?", a voiceprint-bound
    // cluster shows the person's name, everything else keeps its anonymous other:N label.
    func display(_ label: String) -> String {
        if bleedLabels.contains(label) { return "me?" }
        return nameByLabel[label] ?? label
    }

    var out: [DiarizedTurn] = []
    var reassigned = 0
    for t in turns {
        guard t.speaker == "other" else { out.append(passthrough(t)); continue }
        let r = reconcileTurn(
            turn: ReconInterval(start: t.start, end: t.end),
            clusters: clusters,
            purityThreshold: purity,
            coverageThreshold: coverage
        )
        // Remap the runner-up shares' labels through the same binding so a contested turn discloses
        // real names / "me?" rather than internal other:N labels.
        let shares = r.speakers.map { $0.map { SpeakerShareCodable(speaker: display($0.speaker), share: round2($0.share)) } }
        var speaker = r.speaker
        var bleed: Bool? = nil
        var boundBy: String? = nil
        if r.reason == nil {
            // A cluster was assigned. Route it through voiceprint binding, if any applied.
            if bleedLabels.contains(r.speaker) {
                speaker = "me?"
                bleed = true
                boundBy = "voiceprint"
            } else if let name = nameByLabel[r.speaker] {
                speaker = name
                boundBy = "voiceprint"
            }
            reassigned += 1
        }
        out.append(DiarizedTurn(
            seq: t.seq, start: t.start, end: t.end, speaker: speaker, text: t.text,
            final: t.final, conf: round2(r.conf), speakers: shares, bleed: bleed, reason: r.reason, boundBy: boundBy
        ))
    }

    // MARK: Sidecar for `review`: per-cluster centroids (so review --enroll can persist a named
    // cluster's voiceprint without re-diarizing). Written beside the diarized transcript.
    let sidecar = ClustersSidecar(
        anchorEpoch: anchorEpoch,
        otherFile: other.file,
        clusters: clusters.map { ClusterInfo(label: $0.label, centroid: centroidByLabel[$0.label] ?? []) }
    )
    let sidecarURL = dirURL.appendingPathComponent(ClustersSidecar.fileName)
    if let data = try? JSONEncoder().encode(sidecar) {
        try? data.write(to: sidecarURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecarURL.path)
    }

    try writeDiarized(out, to: outURL, inSessionDir: true)
    err("Wrote \(out.count) turn(s) to \(outURL.path): reassigned \(reassigned) 'other' turn(s) to a speaker cluster; \(out.count - reassigned - turns.filter { $0.speaker != "other" }.count) kept 'other' (low confidence).")
}

// MARK: - Shared helpers (also used by Review.swift).

/// Outcome of loading a JSONL transcript: the parsed turns plus a parse census so the caller can
/// warn/refuse instead of silently degrading the "same seq 1:1" guarantee. `firstBadLine` is a
/// 1-based line number matching what an editor shows (blank lines counted).
struct TranscriptLoad {
    let turns: [Turn]
    let totalLines: Int      // non-blank content lines seen (parse attempts)
    let skipped: Int         // content lines that failed to parse
    let firstBadLine: Int?   // 1-based line number of the first unparseable line, if any
}

/// Parse newline-delimited JSON into `[T]`, COUNTING unparseable content lines instead of silently
/// dropping them: returns the decoded values, the number of non-blank content lines seen, the number
/// that failed to parse, and the 1-based line number of the first offender (blank lines counted, so
/// it lines up with an editor's gutter). Shared by `loadTurns` (diarize) and `loadDiarizedTurns`
/// (review) so both surface silent data loss identically rather than each re-deriving the logic.
func parseJSONL<T: Decodable>(_ text: String, as type: T.Type) -> (values: [T], totalLines: Int, skipped: Int, firstBadLine: Int?) {
    let decoder = JSONDecoder()
    var values: [T] = []
    var total = 0
    var skipped = 0
    var firstBad: Int?
    for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        total += 1
        guard let data = trimmed.data(using: .utf8), let v = try? decoder.decode(T.self, from: data) else {
            skipped += 1
            if firstBad == nil { firstBad = idx + 1 }
            continue
        }
        values.append(v)
    }
    return (values, total, skipped, firstBad)
}

/// Load and decode a JSONL transcript into Turn records, with a parse census (see `parseJSONL`) so
/// `diarize` can surface and, when substantially broken, refuse on the data loss rather than emitting
/// a confident-looking diarized file built from only the fraction that happened to parse.
func loadTurns(path: String) throws -> TranscriptLoad {
    let r = parseJSONL(try String(contentsOfFile: path, encoding: .utf8), as: Turn.self)
    return TranscriptLoad(turns: r.values, totalLines: r.totalLines, skipped: r.skipped, firstBadLine: r.firstBadLine)
}

/// A live turn carried into the diarized file unchanged (no cluster reassignment).
func passthrough(_ t: Turn) -> DiarizedTurn {
    DiarizedTurn(seq: t.seq, start: t.start, end: t.end, speaker: t.speaker, text: t.text,
                 final: t.final, conf: t.conf, speakers: nil, bleed: nil, reason: nil, boundBy: nil)
}

/// Write diarized turns as JSONL (0600 when it lands in a private session directory). The write is
/// ATOMIC (`.atomic` -> Foundation writes an auxiliary temp file in the same directory and renames it
/// over the target): `review` rewrites this file in place, so a crash or full disk mid-write must
/// never leave a half-written transcript where a complete one used to be - the rename is all-or-
/// nothing. Permissions are re-applied after, since the rename installs a fresh inode.
func writeDiarized(_ turns: [DiarizedTurn], to url: URL, inSessionDir: Bool) throws {
    let encoder = JSONEncoder()
    var data = Data()
    for t in turns {
        data.append(try encoder.encode(t))
        data.append(0x0A)
    }
    try data.write(to: url, options: .atomic)
    if inSessionDir { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}

/// Load enrolled voiceprints (name + embedding) from the given paths. A directory expands to its
/// top-level *.json files; a file is decoded directly. Each file is a Codable Speaker; we take its
/// .name (used to spot the "me" print for bleed detection) and .currentEmbedding.
func loadVoiceprints(_ paths: [String]) -> [(name: String, embedding: [Float])] {
    let fm = FileManager.default
    var files: [String] = []
    for p in paths {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            let contents = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            files.append(contentsOf: contents.filter { $0.hasSuffix(".json") }.map { (p as NSString).appendingPathComponent($0) })
        } else {
            files.append(p)
        }
    }
    var voiceprints: [(name: String, embedding: [Float])] = []
    for f in files {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: f)),
              let speaker = try? JSONDecoder().decode(Speaker.self, from: data),
              !speaker.currentEmbedding.isEmpty else {
            err("diarize: could not load a voiceprint from \(f) - skipping.")
            continue
        }
        voiceprints.append((name: speaker.name, embedding: speaker.currentEmbedding))
    }
    return voiceprints
}
