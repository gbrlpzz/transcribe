import Foundation
import TranscribeCore

// Deterministic clock + id randomness; temp root per suite.
// All state/methods are @MainActor because SessionStore is MainActor-isolated.
enum SessionStoreTests {
    @MainActor static var clock: Double = 1_755_900_000  // fixed epoch base
    @MainActor static var hexSeq: [String] = []
    @MainActor static var hexIdx = 0

    @MainActor static func makeStore() -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgg-sessions-\(UUID().uuidString)", isDirectory: true)
        return SessionStore(root: root, now: { Date(timeIntervalSince1970: clock) }) {
            defer { hexIdx += 1 }
            return hexSeq.isEmpty ? "000000" : hexSeq[hexIdx % hexSeq.count]
        }
    }

    @MainActor static func makeWav(in dir: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)  // RIFF magic bytes suffice for layout tests
        return url
    }

    // MARK: ID format parity (_new_id)

    @MainActor static func newIDFormatMatchesStoragePy() async throws {
        reset(["ab12cd"])
        let store = makeStore()
        // 2026-08-23 14:30:12 local — built via components to stay TZ-independent.
        var comps = DateComponents()
        (comps.year, comps.month, comps.day, comps.hour, comps.minute, comps.second) = (2026, 8, 23, 14, 30, 12)
        let date = Calendar.current.date(from: comps)!
        let id = store.newSessionID(at: date)
        try requireEqual(id, "20260823_143012_ab12cd", "_new_id parity")
    }

    @MainActor static func reset(_ hexes: [String]) {
        hexSeq = hexes
        hexIdx = 0
    }

    // MARK: Dictation save parity

    @MainActor static func dictationSaveMovesWavAndWritesMetaParity() async throws {
        reset(["feed01"])
        clock += 60
        let stamp = Date(timeIntervalSince1970: clock)
        let day = SessionStore.dayFormatter().string(from: stamp)
        let store = makeStore()
        let wav = try makeWav(in: FileManager.default.temporaryDirectory,
                              name: "dict-\(UUID().uuidString).wav")
        let s = try store.save(recording: wav, transcript: "ciao mondo",
                               model: "apple/it-IT", language: "it-IT", source: "live")
        let dayDir = store.sessionsRoot().appendingPathComponent(day)
        let storedWav = dayDir.appendingPathComponent("\(s.id).wav")
        try require(FileManager.default.fileExists(atPath: storedWav.path), "wav moved into day dir")
        try require(!FileManager.default.fileExists(atPath: wav.path), "original gone (os.replace semantics)")
        try requireEqual(s.recording, storedWav.path)
        // Meta keys exactly as storage.py writes them.
        let metaData = try Data(contentsOf: dayDir.appendingPathComponent("\(s.id).json"))
        guard let obj = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            throw fail("meta not a JSON object")
        }
        try requireEqual(Set(obj.keys), Set(["id", "created_at", "model", "language", "source",
                                             "source_path", "transcript_path", "transcript"]),
                         "meta key set byte-parity")
        try requireEqual(obj["model"] as? String ?? "", "apple/it-IT", "honest native model label")
        try requireEqual(obj["transcript"] as? String ?? "", "ciao mondo")
        try require(abs((obj["created_at"] as? Double ?? 0) - clock) < 2, "created_at epoch seconds")
    }

    @MainActor static func keepTranscriptsFalseStillWritesMetaWhenRecordingExists() async throws {
        reset(["feed02"]); clock += 60
        let store = makeStore()
        let wav = try makeWav(in: FileManager.default.temporaryDirectory,
                              name: "kt-\(UUID().uuidString).wav")
        let s = try store.save(recording: wav, transcript: "secret",
                               source: "live", keepTranscripts: false)
        let metaURL = store.sessionsRoot()
            .appendingPathComponent(s.day).appendingPathComponent("\(s.id).json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as! [String: Any]
        try requireEqual(obj["transcript"] as? String ?? "", "",
                         "text withheld when keepTranscripts=false")
        try require(FileManager.default.fileExists(atPath: s.recording),
                    "meta kept so cleanup can still remove the recording")
    }

    @MainActor static func noMetaWhenNothingToKeep() async throws {
        reset(["feed03"]); clock += 60
        let store = makeStore()
        _ = try store.save(recording: nil, transcript: "t", source: "live",
                           keepTranscripts: false)
        let root = store.sessionsRoot()
        let days = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for d in days {
            let left = (try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(d).path)) ?? []
            try require(left.isEmpty, "no meta written when nothing to retain (parity condition)")
        }
    }

    // MARK: File-job parity

    @MainActor static func fileJobKeepsSourceWritesMdFillsTranscriptPath() async throws {
        reset(["feed04"]); clock += 60
        let store = makeStore()
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgg-src-\(UUID().uuidString)", isDirectory: true)
        let src = try makeWav(in: srcDir, name: "interview.wav")
        let md = try store.writeMarkdown(audioPath: src, text: "hello world")
        try requireEqual(md.lastPathComponent, "interview.md")
        let body = try String(contentsOf: md, encoding: .utf8)
        try requireEqual(body, "# interview\n\nhello world\n", "write_transcript_markdown bytes")
        let s = try store.save(recording: nil, transcript: "ignored", source: "file",
                               sourcePath: src.path)
        try requireEqual(s.recording, "", "no copy of the source")
        try require(FileManager.default.fileExists(atPath: src.path), "source stays in place")
        try requireEqual(s.transcriptPath, md.path, "meta carries transcript_path (auto-filled)")
    }

    // MARK: TTL sweep (AC-L5)

    @MainActor static func cleanTTLsDryRunAndReal() async throws {
        reset(["aa0001", "bb0002", "cc0003"])
        let baseClock = clock
        // Live session created 2 h ago.
        clock = baseClock - 7200
        let store = makeStoreRef()
        let wavLive = try makeWav(in: FileManager.default.temporaryDirectory,
                                  name: "live-\(UUID().uuidString).wav")
        let live = try store.save(recording: wavLive, transcript: "old live", source: "live")
        // File job created 1 h ago with generated .md.
        clock = baseClock - 3600
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgg-src-\(UUID().uuidString)", isDirectory: true)
        let src = try makeWav(in: srcDir, name: "talk.wav")
        let md = try store.writeMarkdown(audioPath: src, text: "file text")
        _ = try store.save(recording: nil, transcript: "x", source: "file", sourcePath: src.path)
        // Fresh live session that must survive both TTLs.
        clock = baseClock + 60
        hexIdx += 1  // fresh gets cc0003
        let freshWav = try makeWav(in: FileManager.default.temporaryDirectory,
                                   name: "fresh-\(UUID().uuidString).wav")
        let fresh = try store.save(recording: freshWav, transcript: "fresh", source: "live")

        // Dry run: lists candidates, deletes nothing (clean --dry-run parity).
        let candidates = store.clean(dryRun: true)
        try require(candidates.contains(live.recording))
        try require(!candidates.contains(src.path), "file sources never removed")
        try require(FileManager.default.fileExists(atPath: live.recording))
        try require(FileManager.default.fileExists(atPath: md.path))

        // Real sweep: live >1h removed; file .md only 1h old survives until 168h.
        let removed = store.clean()
        try require(removed.contains(live.recording))
        try require(!removed.contains(md.path), "file md survives until 168h TTL")
        try require(!FileManager.default.fileExists(atPath: live.recording))
        try require(!FileManager.default.fileExists(atPath:
            store.sessionsRoot().appendingPathComponent(live.day)
                .appendingPathComponent("\(live.id).json").path))
        try require(FileManager.default.fileExists(atPath: md.path))
        try require(FileManager.default.fileExists(atPath: src.path), "file source stays")
        try require(FileManager.default.fileExists(atPath: fresh.recording))

        // After 169 h everything expired is swept, empty day dirs dropped.
        clock = baseClock + 169 * 3600
        let removed2 = store.clean()
        try require(removed2.contains(md.path), "generated .md always cleaned at file TTL")
        try require(!FileManager.default.fileExists(atPath: md.path))
        try require(FileManager.default.fileExists(atPath: src.path), "source STILL in place")
        try require(!FileManager.default.fileExists(atPath: fresh.recording),
                    "fresh live session expired too at 169h (live TTL = 1h)")
    }

    /// Same store across clock jumps: fixed temp root + advancing clock.
    @MainActor private static func makeStoreRef() -> SessionStore {
        SessionStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("lgg-sessions-\(UUID().uuidString)", isDirectory: true),
            now: { Date(timeIntervalSince1970: clock) },
            randomHex: {
                defer { hexIdx += 1 }
                return hexSeq.isEmpty ? "000000" : hexSeq[hexIdx % hexSeq.count]
            })
    }

    @MainActor static func corruptMetaTolerated() async throws {
        reset(["dd0004"]); clock += 120
        let store = makeStoreRef()
        let wav = try makeWav(in: FileManager.default.temporaryDirectory,
                              name: "cm-\(UUID().uuidString).wav")
        let s = try store.save(recording: wav, transcript: "ok", source: "live")
        let bad = store.sessionsRoot()
            .appendingPathComponent(s.day).appendingPathComponent("garbage.json")
        try Data("{not json".utf8).write(to: bad)
        let all = store.iterSessions()
        try requireEqual(all.count, 1, "corrupt meta skipped, good one parsed")
        try requireEqual(all.first?.id ?? "", s.id)
        _ = store.clean()  // must not crash on corrupt entries
    }

    static var allTests: [(String, TestCase)] {
        [
            ("newIDFormatMatchesStoragePy", newIDFormatMatchesStoragePy),
            ("dictationSaveMovesWavAndWritesMetaParity", dictationSaveMovesWavAndWritesMetaParity),
            ("keepTranscriptsFalseStillWritesMetaWhenRecordingExists", keepTranscriptsFalseStillWritesMetaWhenRecordingExists),
            ("noMetaWhenNothingToKeep", noMetaWhenNothingToKeep),
            ("fileJobKeepsSourceWritesMdFillsTranscriptPath", fileJobKeepsSourceWritesMdFillsTranscriptPath),
            ("cleanTTLsDryRunAndReal", cleanTTLsDryRunAndReal),
            ("corruptMetaTolerated", corruptMetaTolerated),
        ]
    }
}
