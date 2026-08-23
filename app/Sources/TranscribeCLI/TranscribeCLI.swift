import Foundation
import AVFoundation
import ApplicationServices
import Speech
import TranscribeCore

/// Minimal `transcribe` CLI — the agent surface. One command:
///
///     transcribe <audio>... [--json] [--locale ll-CC]
///
/// Writes `<name>.md` beside each file (that IS the persistence) and prints
/// the transcript or one JSON line per file. Exit codes:
/// 0 ok · 2 usage · 3 file error · 4 locale not ready · 5 transcription failed.
@MainActor
public enum TranscribeCLI {
    nonisolated public static func entry() -> Never {
        Task { @MainActor in
            let code = await run(CommandLine.arguments)
            exit(code)
        }
        dispatchMain()
    }

    nonisolated public static func mapLocaleError(_ e: LocaleManagerError) -> CLIError {
        switch e {
        case .speechUnavailable:
            return .transcriptionFailed(
                "Apple speech stack unavailable on this Mac (requires macOS 26+).")
        default:
            return .localeNotReady(String(describing: e))
        }
    }

    public struct Invocation {
        public var files: [String] = []
        public var json = false
        public var localeFlag: String?
    }

    public static let usageText = """
    transcribe <audio>... [--json] [--locale ll-CC]
        Transcribe audio files (WAV/AIFF/CAF/m4a-AAC/MP3). Writes <name>.md
        beside each file. --json prints one JSON line per file:
        {"file","text","language","elapsed_ms","md_path"}
    """

    nonisolated public static func parse(_ argv: [String]) -> Result<Invocation, CLIError> {
        var inv = Invocation()
        var rest = Array(argv.dropFirst())
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--json": inv.json = true
            case "--locale":
                guard let v = rest.first else {
                    return .failure(.usage("--locale needs a BCP-47 value"))
                }
                rest.removeFirst()
                inv.localeFlag = v
            default:
                if a.hasPrefix("-") && a != "-" {
                    return .failure(.usage("unknown option \(a)"))
                }
                inv.files.append(a)
            }
        }
        if inv.files.isEmpty { return .failure(.usage("no input files")) }
        return .success(inv)
    }

    static func run(_ argv: [String]) async -> Int32 {
        let inv: Invocation
        switch parse(argv) {
        case .success(let v): inv = v
        case .failure(let e):
            fputs("transcribe: \(e.errorMessage)\n\n\(usageText)\n", stderr)
            return e.exitCode
        }
        do {
            let svc = SystemLocaleAssetService()
            let lm = LocaleManager()
            let locale = try await resolveLocale(lm, svc, inv.localeFlag)
            try await ensureSpeechAuthorized()
            try await gateLocale(lm, locale)

            var worst: Int32 = 0
            for path in inv.files {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                do {
                    let out = try await FileTranscriber.transcribe(url: url, locale: locale)
                    let md = try FileTranscriber.writeMarkdown(audioPath: url, text: out.text)
                    if inv.json {
                        struct Line: Encodable {
                            let file: String, text: String, language: String
                            let elapsed_ms: Int, md_path: String
                        }
                        let enc = JSONEncoder()
                        enc.outputFormatting = [.sortedKeys]
                        let line = Line(file: path, text: out.text, language: out.language,
                                        elapsed_ms: out.elapsedMs, md_path: md.path)
                        print(String(decoding: try enc.encode(line), as: UTF8.self))
                    } else {
                        print(out.text)
                    }
                } catch let e as CLIError {
                    fputs("transcribe: \(path): \(e.errorMessage)\n", stderr)
                    worst = max(worst, e.exitCode)
                }
            }
            return worst
        } catch let e as CLIError {
            fputs("transcribe: \(e.errorMessage)\n", stderr)
            return e.exitCode
        } catch let e as LocaleManagerError {
            let mapped = mapLocaleError(e)
            fputs("transcribe: \(mapped.errorMessage)\n", stderr)
            return mapped.exitCode
        } catch is CancellationError {
            return 5
        } catch {
            fputs("transcribe: \(error)\n", stderr)
            return 5
        }
    }

    // MARK: - Locale resolution

    /// Auto = system language+region locale when supported, else en-US, else
    /// first supported. Pure over an already-canonical list: unit-tested.
    nonisolated public static func resolveAuto(system: Locale, supported: [Locale]) -> Locale? {
        let sysKey = LocaleManager.bcp47(system)
        if let exact = supported.first(where: { LocaleManager.bcp47($0) == sysKey }) {
            return exact
        }
        let ens = supported.filter { $0.language.languageCode?.identifier == "en" }
        if let us = ens.first(where: { $0.region?.identifier == "US" }) { return us }
        return supported.first
    }

    private static func resolveLocale(_ lm: LocaleManager, _ svc: SystemLocaleAssetService,
                                      _ flag: String?) async throws -> Locale {
        if let flag {
            guard let canon = await svc.canonical(Locale(identifier: flag)) else {
                throw CLIError.localeNotReady("\(flag) is not a supported transcription locale here")
            }
            return canon
        }
        let supported = await svc.supportedLocales()
        guard let picked = resolveAuto(system: .current, supported: supported),
              let canon = await svc.canonical(picked) else {
            throw CLIError.localeNotReady("no supported locale available on this Mac")
        }
        return canon
    }

    /// Readiness gate with silent auto-install: probe cache → ensureInstalled
    /// → ready, else exit 4 with guidance.
    private static func gateLocale(_ lm: LocaleManager, _ locale: Locale) async throws {
        await lm.bootstrap()
        if lm.isReady(locale) { return }
        if !(await lm.refreshReadiness(locale)) {
            do {
                try await lm.ensureInstalled(locale)
            } catch let e as LocaleManagerError {
                throw mapLocaleError(e)
            }
        }
        guard lm.isReady(locale) else {
            throw CLIError.localeNotReady(
                "\(locale.identifier(.bcp47)) assets did not become ready — add the language "
                + "in System Settings › Keyboard › Dictation")
        }
    }

    /// np-G1: without speech-recognition authorization the pipeline emits
    /// nothing at all. Gate it explicitly; one-time prompt when undetermined.
    public static func ensureSpeechAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .notDetermined:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw CLIError.transcriptionFailed(
                    "speech recognition was not approved — grant it once in System Settings "
                    + "› Privacy & Security › Speech Recognition")
            }
        default:
            throw CLIError.transcriptionFailed(
                "speech recognition is denied for this context — grant it in System Settings "
                + "› Privacy & Security › Speech Recognition")
        }
    }
}

// CLIError lives in FileTranscriber.swift (shared error surface).
