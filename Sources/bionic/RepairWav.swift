import Foundation

// MARK: - repair-wav: rewrite a correct RIFF/data header from the actual on-disk byte length.
//
// The retention writer patches the WAV header on every flush, so a normally- or even abnormally-
// terminated recording is already self-describing. Two cases still need repair:
//   1. Files produced by an OLDER build that used AVAudioFile's deferred (close-only) header and
//      then died before close - the header claims 0 frames while the PCM is all on disk.
//   2. The microsecond window where a crash lands AFTER a flush appended PCM but BEFORE it patched
//      the size fields - the header under-reports by up to one flush.
// In both, the audio bytes are intact; only the two size fields lie. This rewrites them from the
// real file length, making the audio readable/reviewable again.

/// Locate an ASCII 4-byte marker in a byte buffer, returning its start index.
private func findMarker(_ bytes: [UInt8], _ marker: String) -> Int? {
    let m = Array(marker.utf8)
    guard bytes.count >= m.count else { return nil }
    for i in 0...(bytes.count - m.count) where Array(bytes[i..<i + m.count]) == m { return i }
    return nil
}

private func readLE32(_ bytes: [UInt8], _ off: Int) -> UInt32 {
    guard off + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8) | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24)
}

/// Inspect a WAV: returns (dataStartOffset, headerClaimedDataBytes, actualDataBytesOnDisk). Returns
/// nil if the file isn't a locatable RIFF/WAVE with a data chunk. Used by both repair-wav and
/// diarize's abnormal-termination diagnostic.
func inspectWav(path: String) -> (dataStart: Int, headerDataBytes: Int, diskDataBytes: Int)? {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int else { return nil }
    guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? h.close() }
    guard let headData = try? h.read(upToCount: 4096) else { return nil }
    let bytes = Array(headData)
    guard bytes.count >= 44,
          findMarker(bytes, "RIFF") == 0,
          findMarker(bytes, "WAVE") == 8,
          let dataMarker = findMarker(bytes, "data") else { return nil }
    let headerDataBytes = Int(readLE32(bytes, dataMarker + 4))
    let dataStart = dataMarker + 8
    let diskDataBytes = max(0, size - dataStart)
    return (dataStart, headerDataBytes, diskDataBytes)
}

func runRepairWav() async throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        err("usage: bionic repair-wav <file.wav>")
        err("  Rewrites the RIFF/data size fields from the file's actual byte length. Use on a")
        err("  recording whose header under-reports its length (e.g. a session killed mid-write).")
        exit(2)
    }
    let path = args[2]
    guard FileManager.default.fileExists(atPath: path) else { err("repair-wav: no such file: \(path)"); exit(2) }
    guard let info = inspectWav(path: path) else {
        err("repair-wav: \(path) is not a locatable RIFF/WAVE PCM file (no RIFF/WAVE/data header in the first 4KB) - refusing to touch it.")
        exit(2)
    }
    let (dataStart, headerDataBytes, diskDataBytes) = info
    if headerDataBytes == diskDataBytes {
        err("repair-wav: header already matches on-disk data (\(diskDataBytes) bytes) - nothing to repair.")
        return
    }

    let url = URL(fileURLWithPath: path)
    let h = try FileHandle(forUpdating: url)
    defer { try? h.close() }
    let fileSize = dataStart + diskDataBytes
    try h.seek(toOffset: 4)
    try h.write(contentsOf: AudioRecorder.le32(UInt32(fileSize - 8)))          // RIFF chunk size
    try h.seek(toOffset: UInt64(dataStart - 4))
    try h.write(contentsOf: AudioRecorder.le32(UInt32(diskDataBytes)))         // data chunk size
    try h.synchronize()

    let hdrFrames = headerDataBytes / 2   // mono Int16
    let diskFrames = diskDataBytes / 2
    err("repair-wav: \(path)")
    err("  header claimed \(hdrFrames) frames (\(headerDataBytes) B); on disk there are \(diskFrames) frames (\(diskDataBytes) B).")
    err(String(format: "  patched header to %d frames (%.2fs @16kHz). The recovered audio is now readable.", diskFrames, Double(diskFrames) / 16000.0))
}
