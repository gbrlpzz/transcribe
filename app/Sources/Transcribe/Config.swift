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

    static func configURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/transcribe")
        return base.appendingPathComponent("config.json")
    }
}
