import Foundation

/// Mirrors `transcribe/config.py` so the app and the engine share one
/// configuration file at `~/Library/Application Support/transcribe/config.json`.
///
/// Design §8/§16 additions for Leggerissimo:
/// - `locale`: R42/R42a — nil or "auto" = system-language heuristic (§5.4);
///   otherwise a BCP-47 identifier from the shipped set ("it-IT", "de-CH", …).
/// - `engine`: cutover key "mlx" (0.6.0 default) | "apple"; inert until the
///   native lanes land (design §16).
/// Retention keys are preserved verbatim from the 0.6.0 engine config (§7).
/// Every key decodes as optional-with-default, matching the Python loader's
/// fill-missing-with-defaults semantics; unknown keys are ignored by
/// JSONDecoder, so upgrading never breaks.
public struct AppConfig: Codable, Equatable, Sendable {
    public var hotkey: String = "ctrl+space"
    /// Local engine port — inert at apple cutover; dies with the deletions
    /// ledger in W4 (design §11).
    public var port: Int = 8765
    public var locale: String?
    public var engine: String = "mlx"
    public var liveCleanupTTLHours: Double = 1.0
    public var cleanupTTLHours: Double = 168.0
    /// 0 disables the periodic TTL sweep (engine parity).
    public var cleanupIntervalMinutes: Double = 30.0
    public var keepTranscripts: Bool = true

    enum CodingKeys: String, CodingKey {
        case hotkey, port, locale, engine
        case liveCleanupTTLHours = "live_cleanup_ttl_hours"
        case cleanupTTLHours = "cleanup_ttl_hours"
        case cleanupIntervalMinutes = "cleanup_interval_minutes"
        case keepTranscripts = "keep_transcripts"
    }

    public init(
        hotkey: String = "ctrl+space",
        port: Int = 8765,
        locale: String? = nil,
        engine: String = "mlx",
        liveCleanupTTLHours: Double = 1.0,
        cleanupTTLHours: Double = 168.0,
        cleanupIntervalMinutes: Double = 30.0,
        keepTranscripts: Bool = true
    ) {
        self.hotkey = hotkey
        self.port = port
        self.locale = locale
        self.engine = engine
        self.liveCleanupTTLHours = liveCleanupTTLHours
        self.cleanupTTLHours = cleanupTTLHours
        self.cleanupIntervalMinutes = cleanupIntervalMinutes
        self.keepTranscripts = keepTranscripts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "ctrl+space"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8765
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "mlx"
        liveCleanupTTLHours = try c.decodeIfPresent(Double.self, forKey: .liveCleanupTTLHours) ?? 1.0
        cleanupTTLHours = try c.decodeIfPresent(Double.self, forKey: .cleanupTTLHours) ?? 168.0
        cleanupIntervalMinutes = try c.decodeIfPresent(Double.self, forKey: .cleanupIntervalMinutes) ?? 30.0
        keepTranscripts = try c.decodeIfPresent(Bool.self, forKey: .keepTranscripts) ?? true
    }

    /// True unless the user pinned an explicit language (R42a auto default).
    public var isLocaleAuto: Bool {
        guard let l = locale?.lowercased() else { return true }
        return l.isEmpty || l == "auto"
    }

    static func homeDirectory() -> URL {
        // Parity with transcribe/config.py default_home(): TRANSCRIBE_HOME
        // override exists for tests and exotic setups.
        if let override = ProcessInfo.processInfo.environment["TRANSCRIBE_HOME"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/transcribe", isDirectory: true)
        return base
    }

    public static func configURL() -> URL {
        homeDirectory().appendingPathComponent("config.json")
    }

    /// Load from disk; any read/decode failure falls back to defaults
    /// (same contract as the Python engine reading the same file).
    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL()),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    /// Persist back to config.json (menu Language submenu writes `locale`).
    /// Sorted keys + pretty printing, mirroring the Python `save()` shape.
    public func save() throws {
        let url = AppConfig.configURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
