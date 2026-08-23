import Foundation

/// Mirrors `transcribe/config.py` so the app and the engine share one
/// configuration file at `~/Library/Application Support/transcribe/config.json`.
///
/// Leggerissimo settings: nil or "auto" uses the system-language heuristic;
/// otherwise `locale` is a BCP-47 identifier. Every key decodes as optional-with-default, matching the Python loader's
/// fill-missing-with-defaults semantics; unknown keys are ignored by
/// JSONDecoder, so upgrading never breaks.
public struct AppConfig: Codable, Equatable, Sendable {
    public var hotkey: String = "ctrl+space"
    public var locale: String?

    enum CodingKeys: String, CodingKey {
        case hotkey, locale
    }

    public init(
        hotkey: String = "ctrl+space",
        locale: String? = nil,
    ) {
        self.hotkey = hotkey
        self.locale = locale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "ctrl+space"
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
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
