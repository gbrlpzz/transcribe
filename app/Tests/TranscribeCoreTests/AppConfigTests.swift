import Foundation
import TranscribeCore

enum AppConfigTests {
    @MainActor static func legacyMinimalJSONGetsDefaultsForMissingKeys() throws {
        let json = #"{"hotkey":"ctrl+x","port":9999}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        try requireEqual(cfg.hotkey, "ctrl+x")
        try requireEqual(cfg.port, 9999)
        try requireEqual(cfg.locale, nil as String?)
        try requireEqual(cfg.engine, "mlx", "cutover default (§16)")
        try requireEqual(cfg.liveCleanupTTLHours, 1.0, "engine parity defaults (§7)")
        try requireEqual(cfg.cleanupTTLHours, 168.0)
        try requireEqual(cfg.cleanupIntervalMinutes, 30.0)
        try requireEqual(cfg.keepTranscripts, true)
    }

    @MainActor static func unknownKeysIgnored() throws {
        let json = #"{"hotkey":"a","bogus_key":[1,2],"another":null}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        try requireEqual(cfg.hotkey, "a")
        try requireEqual(cfg.port, 8765)
    }

    @MainActor static func roundTripPreservesAllKeys() throws {
        var cfg = AppConfig()
        cfg.locale = "it-IT"
        cfg.engine = "apple"
        cfg.liveCleanupTTLHours = 0.5
        cfg.keepTranscripts = false
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        try requireEqual(back, cfg, "Codable round trip")
        // snake_case keys on disk match the Python config exactly.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["live_cleanup_ttl_hours", "cleanup_ttl_hours",
                    "cleanup_interval_minutes", "keep_transcripts"] {
            try require(obj[key] != nil, "disk key \(key) preserved verbatim")
        }
    }

    @MainActor static func autoLocaleSemantics() throws {
        try require(AppConfig().isLocaleAuto, "nil = auto (§5.4/R42)")
        var cfg = AppConfig()
        cfg.locale = "auto"
        try require(cfg.isLocaleAuto)
        cfg.locale = "AUTO"
        try require(cfg.isLocaleAuto)
        cfg.locale = "de-CH"
        try require(!cfg.isLocaleAuto, "explicit BCP-47 pins the language")
    }

    @MainActor static func transcribeHomeOverrideHonored() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgg-home-\(UUID().uuidString)", isDirectory: true)
        setenv("TRANSCRIBE_HOME", tmp.path, 1)
        defer { unsetenv("TRANSCRIBE_HOME") }
        try requireEqual(AppConfig.configURL().standardizedFileURL.path,
                         tmp.appendingPathComponent("config.json").standardizedFileURL.path,
                         "config.py default_home parity")
        try requireEqual(SessionStore.defaultSessionsRoot().standardizedFileURL.path,
                         tmp.appendingPathComponent("sessions").standardizedFileURL.path,
                         "sessions root follows home")
        // save/load round trip through the overridden location.
        var cfg = AppConfig(); cfg.locale = "es-MX"
        try cfg.save()
        try requireEqual(AppConfig.load().locale, "es-MX")
        try? FileManager.default.removeItem(at: tmp)
    }

    static var allTests: [(String, TestCase)] {
        [
            ("legacyMinimalJSONGetsDefaultsForMissingKeys", legacyMinimalJSONGetsDefaultsForMissingKeys),
            ("unknownKeysIgnored", unknownKeysIgnored),
            ("roundTripPreservesAllKeys", roundTripPreservesAllKeys),
            ("autoLocaleSemantics", autoLocaleSemantics),
            ("transcribeHomeOverrideHonored", transcribeHomeOverrideHonored),
        ]
    }
}
