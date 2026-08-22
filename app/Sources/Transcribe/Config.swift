import Foundation

/// Mirrors `transcribe/config.py` so the app and the Python engine share
/// one configuration file at ~/Library/Application Support/transcribe/config.json.
/// The engine owns a single model, language mode (auto), and backend; only
/// these keys remain configurable. Unknown keys from older releases are
/// ignored by JSONDecoder, so upgrading never breaks.
struct AppConfig: Codable {
    var hotkey: String = "ctrl+space"
    var port: Int = 8765

    enum CodingKeys: String, CodingKey {
        case hotkey, port
    }

    static func load() -> AppConfig {
        let url = AppConfig.configURL()
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    func save() {
        let url = AppConfig.configURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func configURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/transcribe")
        return base.appendingPathComponent("config.json")
    }
}
