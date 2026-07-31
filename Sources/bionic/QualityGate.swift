import FluidAudio
import Foundation

// MARK: - The accuracy regression gate.
//
// Runs the real offline diarizer over a ground-truth fixture, computes DER, and compares it to a
// committed baseline. Every other check in this project verifies plumbing; this one is the only
// thing that notices if diarization gets WORSE.
//
// Semantics deliberately chosen:
//   * The baseline is a RATCHET, not a target. The committed number is whatever the current stack
//     scores. A run that improves on it does not fail - it prints how much room opened up, and
//     `--bless` writes the better number so the improvement can't silently regress later.
//   * Failure needs a margin (`tolerance`). Model inference is not bit-identical across machines
//     and OS versions, so an exact-match gate would fire on noise and get disabled within a week.
//   * A missing baseline is not a pass. It exits non-zero telling you to --bless, so a fixture
//     added but never blessed can't masquerade as coverage.
//
// Run via: swift run bionic quality [--fixtures DIR] [--bless] [--tolerance F]

/// One committed baseline row, keyed by (fixture, engine) exactly as the reference implementation
/// does - the same audio scores very differently across diarizer configurations, so one number per
/// fixture would be meaningless the moment a second mode exists.
struct QualityBaselineEntry: Codable {
    let fixture: String
    let engine: String
    let der: Double
}

private let baselineFileName = "quality-baseline.json"

/// Identifies the stack being scored. Bump this string when the diarizer configuration changes in a
/// way that legitimately moves the numbers - it forces a new baseline row rather than silently
/// comparing against a number produced by different settings.
private let engineID = "offlineDiarizer.default"

func runQualityGate() async throws {
    var fixturesDir = "testdata/quality"
    var bless = false
    // 0.02 absolute DER: comfortably above cross-machine inference jitter, well below any
    // regression worth catching. Absolute rather than relative because a relative margin on a small
    // baseline (say 0.03) is a rounding error, and on a large one (0.6) is enormous.
    var tolerance = 0.02

    var args = Array(CommandLine.arguments.dropFirst(2))
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--fixtures":
            guard !args.isEmpty else { err("quality: --fixtures requires a directory"); exit(2) }
            fixturesDir = args.removeFirst()
        case "--bless":
            bless = true
        case "--tolerance":
            guard !args.isEmpty, let t = Double(args.removeFirst()) else {
                err("quality: --tolerance requires a number"); exit(2)
            }
            tolerance = t
        case "-h", "--help":
            err("usage: bionic quality [--fixtures DIR] [--bless] [--tolerance F]")
            exit(0)
        default:
            err("quality: unknown flag \(flag)"); exit(2)
        }
    }

    let fm = FileManager.default
    let truthPaths = ((try? fm.contentsOfDirectory(atPath: fixturesDir)) ?? [])
        .filter { $0.hasSuffix(".truth.json") }
        .sorted()
    guard !truthPaths.isEmpty else {
        err("""
            quality: no *.truth.json fixtures in \(fixturesDir).
            Generate one first:  make fixture
            """)
        exit(1)
    }

    let baselinePath = "\(fixturesDir)/\(baselineFileName)"
    var baseline: [QualityBaselineEntry] = []
    if let data = fm.contents(atPath: baselinePath) {
        baseline = (try? JSONDecoder().decode([QualityBaselineEntry].self, from: data)) ?? []
    }

    var measured: [QualityBaselineEntry] = []
    var regressions: [String] = []
    var improvements: [String] = []

    for truthFile in truthPaths {
        let truthData = try Data(contentsOf: URL(fileURLWithPath: "\(fixturesDir)/\(truthFile)"))
        let truth = try JSONDecoder().decode(FixtureTruth.self, from: truthData)
        let audioURL = URL(fileURLWithPath: "\(fixturesDir)/\(truth.audioFile)")
        guard fm.fileExists(atPath: audioURL.path) else {
            err("quality: \(truthFile) references missing audio \(truth.audioFile)")
            exit(1)
        }

        let fixtureName = truthFile.replacingOccurrences(of: ".truth.json", with: "")
        err("quality: diarizing \(truth.audioFile) (first run downloads models)...")

        // Same stack and default configuration `diarize` uses, so the number this gate reports is
        // the number real usage gets. No --speakers hint: telling the diarizer the answer would
        // make the gate measure a configuration nobody runs in practice.
        let diar = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await diar.prepareModels()
        let result = try await diar.process(audioURL) { _, _ in }

        let hypothesis = result.segments.map {
            HypSegment(
                speaker: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
        let der = QualityMetrics.der(reference: truth.segments, hypothesis: hypothesis)
        let refSpeakers = Set(truth.segments.map(\.speaker)).count
        let hypSpeakers = Set(hypothesis.map(\.speaker)).count
        err(String(
            format: "quality: %@ [%@] DER=%.4f (ref %d speakers / %d turns, hyp %d speakers / %d segments)",
            fixtureName, engineID, der, refSpeakers, truth.segments.count, hypSpeakers, hypothesis.count
        ))

        measured.append(QualityBaselineEntry(fixture: fixtureName, engine: engineID, der: der))

        guard let prior = baseline.first(where: { $0.fixture == fixtureName && $0.engine == engineID }) else {
            regressions.append("\(fixtureName) [\(engineID)]: no baseline row (measured DER \(String(format: "%.4f", der))) - run `make quality-bless`")
            continue
        }
        let delta = der - prior.der
        if delta > tolerance {
            regressions.append(String(
                format: "%@ [%@]: DER regressed %.4f -> %.4f (+%.4f, tolerance %.4f)",
                fixtureName, engineID, prior.der, der, delta, tolerance
            ))
        } else if delta < -tolerance {
            improvements.append(String(
                format: "%@ [%@]: DER improved %.4f -> %.4f (%.4f) - re-bless to lock it in",
                fixtureName, engineID, prior.der, der, delta
            ))
        }
    }

    if bless {
        // Merge rather than overwrite: rows for fixtures/engines not measured in this run (a
        // fixture temporarily removed from the directory, say) must survive blessing.
        var merged = baseline.filter { old in
            !measured.contains { $0.fixture == old.fixture && $0.engine == old.engine }
        }
        merged.append(contentsOf: measured)
        merged.sort { ($0.fixture, $0.engine) < ($1.fixture, $1.engine) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(merged).write(to: URL(fileURLWithPath: baselinePath))
        err("quality: blessed \(measured.count) measurement(s) into \(baselinePath)")
        exit(0)
    }

    for i in improvements { err("quality: IMPROVED - \(i)") }
    guard regressions.isEmpty else {
        err("quality: FAIL")
        for r in regressions { err("  - \(r)") }
        exit(1)
    }
    err("quality: PASS - \(measured.count) fixture(s) within \(tolerance) DER of baseline")
    exit(0)
}
