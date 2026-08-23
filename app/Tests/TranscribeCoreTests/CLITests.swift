import Foundation
import TranscribeCore
import TranscribeCLI

// Contract tests for the minimal single-command CLI.
enum CLITests {
    static func loc(_ id: String) -> Locale { Locale(identifier: id) }

    static func parseHappy() throws {
        let r = TranscribeCLI.parse(["transcribe", "a.m4a", "b.wav", "--json", "--locale", "it-IT"])
        guard case .success(let inv) = r else { throw TestFailure("parse failed") }
        try requireEqual(inv.files, ["a.m4a", "b.wav"])
        try require(inv.json)
        try requireEqual(inv.localeFlag, "it-IT")
    }

    static func parseRejectsUnknownOption() throws {
        guard case .failure = TranscribeCLI.parse(["transcribe", "--bogus", "a.wav"]) else {
            throw TestFailure("unknown option must fail")
        }
    }

    static func parseRejectsNoInputs() throws {
        guard case .failure = TranscribeCLI.parse(["transcribe"]) else {
            throw TestFailure("no inputs must fail")
        }
    }

    static func exitCodesPinDocumentedValues() throws {
        try requireEqual(CLIError.usage("x").exitCode, Int32(2))
        try requireEqual(CLIError.fileError("x").exitCode, Int32(3))
        try requireEqual(CLIError.localeNotReady("x").exitCode, Int32(4))
        try requireEqual(CLIError.transcriptionFailed("x").exitCode, Int32(5))
    }

    static func resolveAutoHeuristic() throws {
        let supported = [loc("en_GB"), loc("en_US"), loc("it_IT"), loc("de_DE")]
        try requireEqual(LocaleManager.bcp47(TranscribeCLI.resolveAuto(
            system: loc("en_GB"), supported: supported)!), "en-gb")
        try requireEqual(LocaleManager.bcp47(TranscribeCLI.resolveAuto(
            system: loc("de_DE"), supported: supported)!), "de-de")
        try requireEqual(LocaleManager.bcp47(TranscribeCLI.resolveAuto(
            system: loc("ja_JP"), supported: supported)!), "en-us",
            "system language unsupported -> en-US")
    }

    static var allTests: [(String, TestCase)] {
        [
            ("parseHappy", parseHappy),
            ("parseRejectsUnknownOption", parseRejectsUnknownOption),
            ("parseRejectsNoInputs", parseRejectsNoInputs),
            ("exitCodesPinDocumentedValues", exitCodesPinDocumentedValues),
            ("resolveAutoHeuristic", resolveAutoHeuristic),
        ]
    }
}
