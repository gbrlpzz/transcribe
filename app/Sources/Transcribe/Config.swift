import Foundation

/// Mirrors `transcribe/config.py` so the app and the Python engine share
/// one configuration file at ~/Library/Application Support/transcribe/config.json.
struct AppConfig: Codable {
    var model: String = "mlx-community/whisper-large-v3-turbo"
    var language: String = "auto"
    var backend: String = "auto"
    var device: String = "auto"
    var sampleRate: Int = 16000
    var paste: Bool = true
    var smartText: Bool = true
    var cleanupTtlHours: Double = 48.0
    var keepTranscripts: Bool = true
    var port: Int = 8765
    var warmOnStart: Bool = true
    var hotkey: String = "ctrl+space"
    var pasteMode: String = "cmd-v"
    var launchAtLogin: Bool = false

    enum CodingKeys: String, CodingKey {
        case model, language, backend, device, sampleRate = "sample_rate"
        case paste, smartText = "smart_text", cleanupTtlHours = "cleanup_ttl_hours"
        case keepTranscripts = "keep_transcripts", port, warmOnStart = "warm_on_start"
        case hotkey, pasteMode = "paste_mode", launchAtLogin = "launch_at_login"
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
