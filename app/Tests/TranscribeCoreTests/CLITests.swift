import Foundation
import Speech
import TranscribeCLI
import TranscribeCore

// CLI surface tests (b-files-cli): parsing, exit-code mapping, locale
// resolution, JSON shape — no Speech runtime touched. Live smoke is
// fixture-gated like the other suites.
@MainActor
struct CLITests {
    static var allTests: [(String, TestCase)] { [
        ("parseFileHappy", parseFileHappy),
        ("parseFlagsAndLocale", parseFlagsAndLocale),
        ("parseRejectsUnknownVerb", parseRejectsUnknownVerb),
        ("parseServeExplicitlyAbsent", parseServeExplicitlyAbsent),
        ("parseUnknownFlagIsUsage", parseUnknownFlagIsUsage),
        ("parseDoctorLanguages", parseDoctorLanguages),
        ("exitCodesPinDocumentedValues", exitCodesPinDocumentedValues),
        ("localeErrorMappingTable", localeErrorMappingTable),
        ("resolveAutoHeuristic", resolveAutoHeuristic),
        ("jsonLineShape", jsonLineShape),
        ("usageDocumentsContract", usageDocumentsContract),
        ("liveFileSmoke", liveFileSmoke),
        ] }

    // MARK: - Parsing

    static func parseFileHappy() throws {
        let inv = try requireParsed(["transcribe", "file", "a.wav", "/tmp/b.mp3"])
        try requireEqual(inv.files, ["a.wav", "/tmp/b.mp3"])
        try require(!inv.json && !inv.noKeep)
        try requireEqual(inv.localeFlag, nil as String?)
    }

    static func parseFlagsAndLocale() throws {
        let inv = try requireParsed([
            "transcribe", "file", "--json", "--no-keep", "--locale", "it-IT", "x.m4a"])
        try require(inv.json && inv.noKeep)
        try requireEqual(inv.localeFlag, "it-IT")
        try requireEqual(inv.files, ["x.m4a"])
    }

    static func parseRejectsUnknownVerb() throws {
        guard case .failure(let e) = TranscribeCLI.parse(["transcribe", "frobnicate"]) else {
            throw fail("expected usage failure")
        }
        try requireEqual(e.exitCode, 2)
    }

    static func parseServeExplicitlyAbsent() throws {
        // R40/R48: the native world has no server; asking for one must say so.
        guard case .failure(let e) = TranscribeCLI.parse(["transcribe", "serve"]) else {
            throw fail("expected usage failure")
        }
        try requireEqual(e.exitCode, 2)
        try require(e.errorMessage.contains("does not exist"))
    }

    static func parseUnknownFlagIsUsage() throws {
        guard case .failure(let e) = TranscribeCLI.parse(["transcribe", "file", "--turbo", "a.wav"]) else {
            throw fail("expected usage failure")
        }
        try requireEqual(e.exitCode, 2)
        guard case .failure = TranscribeCLI.parse(["transcribe"]) else {
            throw fail("bare invocation must be usage")
        }
    }

    static func parseDoctorLanguages() throws {
        let d = try requireParsed(["transcribe", "doctor", "--json"])
        try require(d.json)
        let l = try requireParsed(["transcribe", "languages", "--install", "de-CH"])
        try requireEqual(l.install, "de-CH")
        guard case .failure = TranscribeCLI.parse(["transcribe", "languages", "--wat"]) else {
            throw fail("unknown languages flag must be usage")
        }
    }

    // MARK: - Exit codes + error mapping

    static func exitCodesPinDocumentedValues() throws {
        func code(_ e: CLIError) -> Int32 { e.exitCode }
        try requireEqual(code(.usage("")), Int32(2))
        try requireEqual(code(.fileError("")), Int32(3))
        try requireEqual(code(.localeNotReady("")), Int32(4))
        try requireEqual(code(.transcriptionFailed("")), Int32(5))
    }

    static func localeErrorMappingTable() throws {
        // b-locales contract: install/allocation failures → 4; missing speech stack → 5.
        for e in [LocaleManagerError.unsupportedLocale, .installTimedOut,
                  .allocationExhausted, .localeNotAllocated, .insufficientResources,
                  .notAvailableAfterInstall] {
            try requireEqual(TranscribeCLI.mapLocaleError(e).exitCode, Int32(4), "\(e)")
        }
        try requireEqual(
            TranscribeCLI.mapLocaleError(.speechUnavailable).exitCode, Int32(5))
        try requireEqual(
            TranscribeCLI.mapLocaleError(.installFailed("x")).exitCode, Int32(4))
    }

    // MARK: - Locale resolution (design §5.4 auto heuristic)

    static func loc(_ id: String) -> Locale { Locale(identifier: id) }

    static func resolveAutoHeuristic() throws {
        let supported = [loc("en-US"), loc("en-GB"), loc("it-IT"), loc("de-DE"), loc("es-ES")]
        try requireEqual(TranscribeCLI.resolveAuto(system: loc("en_GB"), supported: supported), loc("en-GB"))
        try requireEqual(TranscribeCLI.resolveAuto(system: loc("de_DE"), supported: supported), loc("de-DE"))
        // Unsupported system language falls back to en-US (§5.4).
        try requireEqual(TranscribeCLI.resolveAuto(system: loc("fr_FR"), supported: supported), loc("en-US"))
        // No English at all: first supported survives rather than nil.
        let noEn = [loc("it-IT"), loc("de-DE")]
        try requireEqual(TranscribeCLI.resolveAuto(system: loc("en_US"), supported: noEn), loc("it-IT"))
        try requireEqual(TranscribeCLI.resolveAuto(system: loc("en_US"), supported: []), nil as Locale?)
    }

    // MARK: - Output shapes

    static func jsonLineShape() throws {
        struct Row: Encodable {
            let file: String; let text: String; let language: String
            let elapsed_ms: Int; let md_path: String
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let line = String(decoding: try enc.encode(
            Row(file: "a.wav", text: "Hello.", language: "en-US",
                elapsed_ms: 171, md_path: "")), as: UTF8.self)
        for key in ["\"elapsed_ms\":171", "\"file\":\"a.wav\"", "\"language\":\"en-US\"",
                    "\"md_path\":\"\"", "\"text\":\"Hello.\""] {
            try require(line.contains(key), "missing \(key) in \(line)")
        }
    }

    static func usageDocumentsContract() throws {
        let u = TranscribeCLI.usageText
        for verb in ["file", "doctor", "languages"] {
            try require(u.contains(verb), "usage must document \(verb)")
        }
        try require(u.contains("--no-keep") && u.contains("--json") && u.contains("--install"))
        for code in ["0 ok", "2 usage", "3 file error", "4 locale not ready", "5 transcription failed"] {
            try require(u.contains(code), "usage must document exit code \(code)")
        }
    }

    // MARK: - Live smoke (fixture-gated, mirrors suite style)

    /// TRANSCRIBE_SMOKE_WAV=<16k wav> runs a real end-to-end file transcription;
    /// skipped silently when unset so the battery stays hermetic.
    static func liveFileSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBE_SMOKE_WAV"],
              FileManager.default.fileExists(atPath: path) else {
            throw TestSkipped("set TRANSCRIBE_SMOKE_WAV to run")
        }
        try await TranscribeCLI.ensureSpeechAuthorized()
        let out = try await FileTranscriber.transcribe(
            url: URL(fileURLWithPath: path), locale: Locale(identifier: "en-US"))
        try require(!out.text.isEmpty, "smoke transcript empty")
    }

    private static func requireParsed(_ argv: [String]) throws -> TranscribeCLI.Invocation {
        switch TranscribeCLI.parse(argv) {
        case .success(let inv): return inv
        case .failure(let e): throw fail("expected success, got: \(e.errorMessage)")
        }
    }
}
