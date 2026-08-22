import Foundation

/// Session storage with TTL cleanup — parity port of transcribe/storage.py
/// (0.6.0), design §7 / AC-L5.
///
/// Layout (byte-parity with the Python engine):
/// - Root: `<home>/sessions/<YYYYMMDD>/` where home honors TRANSCRIBE_HOME.
/// - ID: `<yyyyMMdd_HHmmss>_<6 lowercase hex>` (matches `_new_id()`).
/// - Dictation: `<id>.wav` moved into the day dir + `<id>.json` meta with keys
///   {id, created_at, model, language, source, source_path, transcript_path,
///   transcript} — native writes `model:"apple/<locale>"` (honest label).
/// - File jobs: source stays in place; `<basename>.md` beside it; meta carries
///   `transcript_path`.
/// - TTLs: live 1 h, file transcripts 168 h (`live_cleanup_ttl_hours` /
///   `cleanup_ttl_hours` preserved verbatim); sweep every 30 min while running.
/// - Bookkeeping failures never fail a transcription (swallow at the caller;
///   `saveBestEffort` mirrors `save_result`).
public struct Session: Equatable, Sendable {
    public var id: String          // "20260809_143012_ab12cd"
    public var day: String         // "20260809"
    public var recording: String   // absolute path to the wav ("" if deleted)
    public var transcript: String
    public var createdAt: TimeInterval
    public var model: String
    public var language: String
    public var source: String      // "live" | "file" | legacy "cli"/"app"/"agent"/"server"
    public var sourcePath: String  // original file for a file job; never removed by cleanup
    public var transcriptPath: String

    public init(id: String, day: String, recording: String, transcript: String,
                createdAt: TimeInterval, model: String, language: String,
                source: String, sourcePath: String, transcriptPath: String) {
        self.id = id
        self.day = day
        self.recording = recording
        self.transcript = transcript
        self.createdAt = createdAt
        self.model = model
        self.language = language
        self.source = source
        self.sourcePath = sourcePath
        self.transcriptPath = transcriptPath
    }

    /// Meta keys exactly as storage.py writes them (no day/recording — those
    /// are reconstructed from the id by readers).
    struct Meta: Codable, Equatable {
        var id: String
        var created_at: TimeInterval
        var model: String
        var language: String
        var source: String
        var source_path: String
        var transcript_path: String
        var transcript: String
    }
}

@MainActor
public final class SessionStore {
    public typealias Now = () -> Date
    /// Returns 6 lowercase hex chars (parity: os.urandom(3).hex()).
    public typealias RandomHex = () -> String

    private let rootOverride: URL?
    private var now: Now
    private var randomHex: RandomHex
    private var sweeper: Timer?

    /// rootOverride for tests; default honors TRANSCRIBE_HOME like config.py.
    public init(root: URL? = nil, now: @escaping Now = { Date() },
                randomHex: @escaping RandomHex = SessionStore.systemRandomHex) {
        self.rootOverride = root
        self.now = now
        self.randomHex = randomHex
    }

    nonisolated public static func systemRandomHex() -> String {
        var b = [UInt8](repeating: 0, count: 3)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 3, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Paths

    nonisolated public static func defaultHome() -> URL {
        AppConfig.homeDirectory()
    }
    nonisolated public static func defaultSessionsRoot() -> URL {
        defaultHome().appendingPathComponent("sessions", isDirectory: true)
    }
    public func sessionsRoot() -> URL {
        rootOverride ?? SessionStore.defaultSessionsRoot()
    }
    private func dayDirectory(_ day: String) -> URL {
        sessionsRoot().appendingPathComponent(day, isDirectory: true)
    }
    func metaURL(_ session: Session) -> URL {
        dayDirectory(session.day).appendingPathComponent("\(session.id).json")
    }

    // MARK: - Time formatting (local timezone, engine parity)

    nonisolated static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f
    }
    nonisolated static func idFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }

    public func newSessionID(at date: Date? = nil) -> String {
        let d = date ?? now()
        return SessionStore.idFormatter().string(from: d) + "_" + randomHex()
    }

    // MARK: - Writing

    /// Move (or reference) a recording into session storage and write metadata.
    /// Throws on filesystem errors; callers that must never fail a transcript
    /// use `saveBestEffort` (parity: save_result swallowing OSError).
    @discardableResult
    public func save(recording: URL?, transcript: String,
                     model: String = "", language: String = "",
                     source: String = "cli", keepTranscripts: Bool = true,
                     sourcePath: String = "", transcriptPath: String = "") throws -> Session {
        let stamp = now()
        let day = SessionStore.dayFormatter().string(from: stamp)
        let sid = newSessionID(at: stamp)
        let dayDir = dayDirectory(day)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        var storedWav = ""
        if let rec = recording, FileManager.default.fileExists(atPath: rec.path) {
            let dest = dayDir.appendingPathComponent("\(sid).wav")
            if rec.standardizedFileURL != dest.standardizedFileURL {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)  // os.replace semantics
                }
                try FileManager.default.moveItem(at: rec, to: dest)
            }
            storedWav = dest.path
        }

        var tp = transcriptPath
        if source == "file" && !sourcePath.isEmpty && tp.isEmpty {
            tp = SessionStore.markdownPath(forAudio: sourcePath).path
        }

        let session = Session(
            id: sid, day: day, recording: storedWav, transcript: transcript,
            createdAt: stamp.timeIntervalSince1970, model: model,
            language: language, source: source, sourcePath: sourcePath,
            transcriptPath: tp)

        // Keep metadata whenever there is a recording or generated file output
        // so cleanup can remove it even when text retention is disabled.
        if keepTranscripts || !session.recording.isEmpty || !session.transcriptPath.isEmpty {
            let meta = Session.Meta(
                id: session.id, created_at: session.createdAt, model: session.model,
                language: session.language, source: session.source,
                source_path: session.sourcePath, transcript_path: session.transcriptPath,
                transcript: keepTranscripts ? transcript : "")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(meta)
            try data.write(to: metaURL(session), options: [.atomic])
        }
        return session
    }

    /// Parity of storage.save_result: bookkeeping never fails a transcription.
    @discardableResult
    public func saveBestEffort(recording: URL?, transcript: String,
                               model: String = "", language: String = "",
                               source: String = "cli", keepTranscripts: Bool = true,
                               sourcePath: String = "", transcriptPath: String = "") -> Session? {
        try? save(recording: recording, transcript: transcript, model: model,
                  language: language, source: source, keepTranscripts: keepTranscripts,
                  sourcePath: sourcePath, transcriptPath: transcriptPath)
    }

    /// Write the transcript as `<basename>.md` next to the audio file
    /// (`# <title>\n\n<text>\n` — identical bytes to write_transcript_markdown).
    @discardableResult
    public func writeMarkdown(audioPath: URL, text: String) throws -> URL {
        let md = SessionStore.markdownPath(forAudio: audioPath.path)
        let title = md.deletingPathExtension().lastPathComponent
        let body = "# \(title)\n\n\(text)\n"
        try Data(body.utf8).write(to: md, options: [.atomic])
        return md
    }

    nonisolated public static func markdownPath(forAudio path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".md")
    }

    // MARK: - Reading / sweeping

    /// All persisted sessions, sorted by day then name (engine parity).
    public func iterSessions() -> [Session] {
        let fm = FileManager.default
        let root = sessionsRoot()
        guard let days = try? fm.contentsOfDirectory(atPath: root.path).sorted() else { return [] }
        var out: [Session] = []
        for day in days {
            let dayDir = root.appendingPathComponent(day)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dayDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: dayDir.path).sorted() else { continue }
            for name in names where name.hasSuffix(".json") {
                guard let data = fm.contents(atPath: dayDir.appendingPathComponent(name).path),
                      let meta = try? JSONDecoder().decode(Session.Meta.self, from: data) else {
                    continue  // corrupt meta tolerated, skipped (parity)
                }
                let wav = dayDir.appendingPathComponent("\(meta.id).wav")
                out.append(Session(
                    id: meta.id, day: day,
                    recording: fm.fileExists(atPath: wav.path) ? wav.path : "",
                    transcript: meta.transcript, createdAt: meta.created_at,
                    model: meta.model, language: meta.language, source: meta.source,
                    sourcePath: meta.source_path, transcriptPath: meta.transcript_path))
            }
        }
        return out
    }

    /// Delete expired live data and generated file transcripts. Everything not
    /// a file job is live data; file sources are NEVER removed, generated
    /// `.md` always is. Defaults live=1 h, file=168 h. Returns removed paths
    /// (or candidates when `dryRun`; `clean --dry-run` parity, AC-L5).
    @discardableResult
    public func clean(dryRun: Bool = false,
                      liveTTLHours: Double? = nil,
                      fileTTLHours: Double? = nil) -> [String] {
        let liveTTL = liveTTLHours ?? 1.0
        let fileTTL = fileTTLHours ?? 168.0
        let cutoffBase = now().timeIntervalSince1970
        let fm = FileManager.default
        var removed: [String] = []
        for s in iterSessions() {
            let ttl = s.source == "file" ? fileTTL : liveTTL
            let cutoff = cutoffBase - ttl * 3600
            guard s.createdAt > 0, s.createdAt < cutoff else { continue }
            for path in [s.recording, metaURL(s).path, s.transcriptPath] {
                if path.isEmpty { continue }
                if dryRun {
                    if fm.fileExists(atPath: path) { removed.append(path) }
                } else if fm.fileExists(atPath: path) {
                    do { try fm.removeItem(atPath: path); removed.append(path) }
                    catch { /* swallow: housekeeping never fails */ }
                }
            }
        }
        if !dryRun {  // drop empty day directories (parity)
            let root = sessionsRoot()
            if let days = try? fm.contentsOfDirectory(atPath: root.path) {
                for d in days {
                    let dir = root.appendingPathComponent(d)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                          isDir.boolValue,
                          ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty else { continue }
                    try? fm.removeItem(at: dir)
                }
            }
        }
        return removed
    }

    // MARK: - Periodic sweep (engine parity: every 30 min while running)

    /// Starts the TTL timer on the main runloop. intervalMinutes ≤ 0 disables
    /// (config `cleanup_interval_minutes` semantics).
    public func startSweeper(intervalMinutes: Double, liveTTLHours: Double, fileTTLHours: Double) {
        stopSweeper()
        guard intervalMinutes > 0 else { return }
        let t = Timer(timeInterval: intervalMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.clean(liveTTLHours: liveTTLHours, fileTTLHours: fileTTLHours)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sweeper = t
    }

    public func stopSweeper() {
        sweeper?.invalidate()
        sweeper = nil
    }
}
