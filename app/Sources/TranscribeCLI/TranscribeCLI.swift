import Foundation
import AVFoundation
import ApplicationServices
import Speech
import TranscribeCore

/// Native `transcribe` CLI (design §9, R40/R48) — the universal interface for
/// agents and humans. Runs INSIDE the app binary via single-binary dispatch
/// (R49): basename(argv[0]) == "transcribe" selects this module; there is no
/// second binary and no server (`serve` does not exist by design).
///
/// Verbs: file · doctor · languages. Exit codes:
///   0 ok · 2 usage · 3 file error · 4 locale not ready/unsupported ·
///   5 transcription failure.
/// With multiple inputs every file is attempted; the exit code reports the
/// worst class seen (5 > 3).
@MainActor
public enum TranscribeCLI {
    // MARK: - Entry (bridged from main.swift top-level code)

    /// Never returns. The CLI body runs on the main actor because LocaleManager
    /// and SessionStore are MainActor-isolated; dispatchMain services the main
    /// queue that hosts the Swift main executor, so the Task below runs and
    /// exits the process with the verb's code.
    /// nonisolated on purpose: called from app main.swift's synchronous
    /// top-level code; everything actor-touching happens inside the Task.
    nonisolated public static func entry() -> Never {
        Task { @MainActor in
            let code = await run(CommandLine.arguments)
            exit(code)
        }
        dispatchMain()
    }

    /// LocaleManagerError → CLI exit-code mapping (b-locales table): every
    /// install/allocation failure surfaces as "locale not ready" (4); only a
    /// missing speech stack itself is a transcription failure (5).
    nonisolated public static func mapLocaleError(_ e: LocaleManagerError) -> CLIError {
        switch e {
        case .speechUnavailable:
            return .transcriptionFailed(
                "Apple speech stack unavailable on this Mac (requires macOS 26+).")
        default:
            return .localeNotReady(String(describing: e))
        }
    }

    // MARK: - Argument parsing (hand-rolled, zero dependencies)

    public struct Invocation {
        public var files: [String] = []
        public var json = false
        public var noKeep = false
        public var localeFlag: String?
        public var install: String?
    }

    public static let usageText = """
    transcribe — local file transcription on Apple's native speech stack (macOS 26+)

    USAGE: transcribe <command> [options]

    COMMANDS:
      file <path>... [--json] [--no-keep] [--locale ll-CC]
          Transcribe audio files (WAV/AIFF/CAF/m4a-AAC/MP3). Writes
          <name>.md beside each file unless --no-keep.
          --json         one JSON object per line:
                         {"file","text","language","elapsed_ms","md_path"}
          --no-keep      print only; write neither sidecar nor session record
          --locale       BCP-47 tag ("it-IT"); default: configured or auto
      doctor [--json]    permissions, app bundle, and locale readiness report
      languages [--json] [--install ll-CC]
          Locale readiness matrix; --install fetches Apple language assets.

    EXIT CODES: 0 ok · 2 usage · 3 file error · 4 locale not ready · 5 transcription failed

    There is no `serve`: the native Transcribe has no server, port, or health endpoint.
    """

    public static func parse(_ argv: [String]) -> Result<Invocation, CLIError> {
        var inv = Invocation()
        guard argv.count >= 2 else { return .failure(.usage("missing command")) }
        let rest = Array(argv.dropFirst(2))
        switch argv[1] {
        case "file":
            if rest.isEmpty { return .failure(.usage("file: no input paths")) }
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--json": inv.json = true
                case "--no-keep": inv.noKeep = true
                case "--locale":
                    guard i + 1 < rest.count else {
                        return .failure(.usage("--locale needs a BCP-47 value"))
                    }
                    i += 1
                    inv.localeFlag = rest[i]
                default:
                    if rest[i].hasPrefix("-") {
                        return .failure(.usage("unknown option \(rest[i])"))
                    }
                    inv.files.append(rest[i])
                }
                i += 1
            }
        case "doctor":
            for a in rest {
                if a == "--json" { inv.json = true } else { return .failure(.usage("unknown option \(a)")) }
            }
        case "languages":
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--json": inv.json = true
                case "--install":
                    guard i + 1 < rest.count else {
                        return .failure(.usage("--install needs a BCP-47 value"))
                    }
                    i += 1
                    inv.install = rest[i]
                default: return .failure(.usage("unknown option \(rest[i])"))
                }
                i += 1
            }
        case "serve":
            return .failure(.usage(
                "`serve` does not exist: native Transcribe has no server. Use `transcribe file`."))
        default:
            return .failure(.usage("unknown command `\(argv[1])`"))
        }
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
            switch argv[1] {
            case "file": return try await cmdFile(inv)
            case "doctor": try await cmdDoctor(inv)
            case "languages": return try await cmdLanguages(inv)
            default: break
            }
            return 0
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

    // MARK: - Locale resolution (config + flag, design §5.4 auto heuristic)

    /// Auto = system language+region locale when supported, else en-US, else
    /// first supported (§5.4). Pure over an already-canonical list: unit-tested.
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
        let raw: String
        if let flag { raw = flag } else {
            let cfg = AppConfig.load()
            raw = cfg.isLocaleAuto ? "" : (cfg.locale ?? "")
        }
        if raw.isEmpty {
            let supported = await svc.supportedLocales()
            guard let picked = resolveAuto(system: .current, supported: supported),
                  let canon = await svc.canonical(picked) else {
                throw CLIError.localeNotReady("no supported locale available on this Mac")
            }
            return canon
        }
        guard let canon = await svc.canonical(Locale(identifier: raw)) else {
            throw CLIError.localeNotReady(
                "\(raw) is not a supported transcription locale here (see `transcribe languages`)")
        }
        return canon
    }

    /// Readiness gate with silent-success auto-install (R47/R44): probe cache →
    /// ensureInstalled (watchdog-wrapped) → ready, else exit 4 with guidance.
    private static func gateLocale(_ lm: LocaleManager, _ locale: Locale) async throws {
        await lm.bootstrap()
        if lm.isReady(locale) { return }
        if !(await lm.refreshReadiness(locale)) {
            do {
                try await installWithProgress(lm, locale)
            } catch let e as LocaleManagerError {
                throw mapLocaleError(e)
            }
        }
        guard lm.isReady(locale) else {
            throw CLIError.localeNotReady(
                "\(locale.identifier(.bcp47)) assets did not become ready — run `transcribe doctor`, "
                + "or add the language in System Settings › Keyboard › Dictation")
        }
    }

    // MARK: - file verb

    /// One JSON line per file; keys sorted, `md_path` "" under --no-keep.
    struct FileResultLine: Encodable {
        let file: String
        let text: String
        let language: String
        let elapsed_ms: Int
        let md_path: String
    }

    private static func cmdFile(_ inv: Invocation) async throws -> Int32 {
        let svc = SystemLocaleAssetService()
        let lm = LocaleManager()
        let locale = try await resolveLocale(lm, svc, inv.localeFlag)
        try await ensureSpeechAuthorized()
        try await gateLocale(lm, locale)

        let cfg = AppConfig.load()
        let store = SessionStore()
        var worst: Int32 = 0
        for path in inv.files {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let out = try await FileTranscriber.transcribe(url: url, locale: locale)
                var mdPath: URL?
                if !inv.noKeep {
                    mdPath = try store.writeMarkdown(audioPath: url, text: out.text)
                    store.saveBestEffort(
                        recording: nil, transcript: out.text,
                        model: "apple/\(out.language)", language: out.language,
                        source: "file", keepTranscripts: cfg.keepTranscripts,
                        sourcePath: url.path)
                }
                if inv.json {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.sortedKeys]
                    let line = FileResultLine(
                        file: path, text: out.text, language: out.language,
                        elapsed_ms: out.elapsedMs, md_path: mdPath?.path ?? "")
                    let data = try enc.encode(line)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print(out.text)
                }
            } catch let e as CLIError {
                fputs("transcribe: \(path): \(e.errorMessage)\n", stderr)
                worst = max(worst, e.exitCode)
            }
        }
        return worst
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
                    + "› Privacy & Security › Speech Recognition (see `transcribe doctor`)")
            }
        default:
            throw CLIError.transcriptionFailed(
                "speech recognition is denied for this context — grant it in System Settings "
                + "› Privacy & Security › Speech Recognition (see `transcribe doctor`)")
        }
    }

    // MARK: - languages verb

    private static func cmdLanguages(_ inv: Invocation) async throws -> Int32 {
        let svc = SystemLocaleAssetService()
        let lm = LocaleManager()
        await lm.bootstrap()
        let shipped = (await svc.supportedLocales()).sorted { LocaleManager.bcp47($0) < LocaleManager.bcp47($1) }

        if let want = inv.install {
            guard let loc = shipped.first(where: {
                LocaleManager.bcp47($0).caseInsensitiveCompare(want) == .orderedSame
            }) else {
                throw CLIError.localeNotReady("\(want) is not offered by this Mac\'s speech stack (see matrix below)")
            }
            do {
                try await installWithProgress(lm, loc)
            } catch let e as LocaleManagerError {
                throw mapLocaleError(e)
            }
            fputs("installed \(LocaleManager.bcp47(loc))\n", stderr)
            if !lm.isReady(loc) { throw CLIError.localeNotReady("assets still not usable after install") }
            return 0
        }

        var rows: [[String: String]] = []
        for loc in shipped {
            let ready = lm.isReady(loc)
            rows.append(["locale": LocaleManager.bcp47(loc), "ready": ready ? "yes" : "no"])
        }
        if inv.json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(rows)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("LOCALE   READY")
            for r in rows { print("\(r["locale"]!.padding(toLength: 9, withPad: " ", startingAt: 0))\(r["ready"]!)") }
            let pending = rows.filter { $0["ready"] == "no" }.map { $0["locale"]! }
            if !pending.isEmpty {
                print("\nnot ready — install with: transcribe languages --install <locale>")
            }
        }
        return 0
    }

    /// Shared install runner: subscribe to the delivered event stream first,
    /// then drive ensureInstalled; progress goes to stderr, terminal events
    /// end the wait, and the task's thrown error decides the outcome.
    private static func installWithProgress(_ lm: LocaleManager, _ locale: Locale) async throws {
        let stream = await lm.installStatus(locale)
        let task = Task { try await lm.ensureInstalled(locale) }
        var lastPct = -1
        outer: for await event in stream {
            switch event {
            case .downloading(let f):
                let pct = Int(f * 100)
                if pct != lastPct { lastPct = pct; fputs("installing \(pct)%\n", stderr) }
            case .ready, .installed: break outer
            case .needsInstall: continue
            case .timedOut: break outer
            case .unsupported: break outer
            case .failed(let e):
                fputs("install failed: \(e)\n", stderr)
                break outer
            }
        }
        try await task.value  // rethrows the real error, if any
    }

    // MARK: - doctor verb

    private static func cmdDoctor(_ inv: Invocation) async throws {
        let svc = SystemLocaleAssetService()
        let lm = LocaleManager()
        await lm.bootstrap()
        let shipped = (await svc.supportedLocales()).sorted { LocaleManager.bcp47($0) < LocaleManager.bcp47($1) }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "authorized"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "not determined"
        @unknown default: mic = "unknown"
        }
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "authorized"
        case .denied: speech = "denied"
        case .restricted: speech = "restricted"
        case .notDetermined: speech = "not determined"
        @unknown default: speech = "unknown"
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let appPath = "/Applications/Transcribe.app"
        let appBinary = appPath + "/Contents/MacOS/Transcribe"
        let appOK = FileManager.default.isExecutableFile(atPath: appBinary)

        if inv.json {
            struct Row: Encodable { let locale: String; let ready: Bool }
            struct Doctor: Encodable {
                let macOS: String
                let speechStackAvailable: Bool
                let microphone: String
                let speechRecognition: String
                let accessibility: Bool
                let appBundleFound: Bool
                let locales: [Row]
            }
            let doc = Doctor(
                macOS: osVersion,
                speechStackAvailable: SpeechTranscriber.isAvailable,
                microphone: mic, speechRecognition: speech,
                accessibility: AXIsProcessTrusted(),
                appBundleFound: appOK,
                locales: shipped.map { .init(locale: LocaleManager.bcp47($0), ready: lm.isReady($0)) })
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            print(String(decoding: try enc.encode(doc), as: UTF8.self))
            return
        }

        print("transcribe doctor")
        print("macOS              \(osVersion)\(v.majorVersion >= 26 ? "" : "  (26+ required)")")
        print("speech stack       \(SpeechTranscriber.isAvailable ? "available" : "UNAVAILABLE")")
        print("microphone         \(mic)")
        print("speech recognition \(speech)\(speech == "authorized" ? "" : "  ← approve once; required")")
        print("accessibility      \(AXIsProcessTrusted() ? "granted" : "denied")  (paste feature, app only)")
        print("app bundle         \(appOK ? appPath : "\(appPath) not found (CLI works standalone)")")
        print("locales")
        for loc in shipped {
            let ready = lm.isReady(loc)
            print("  \(LocaleManager.bcp47(loc).padding(toLength: 8, withPad: " ", startingAt: 0))\(ready ? "ready" : "NOT READY  ← transcribe languages --install \(LocaleManager.bcp47(loc))")")
        }
        if speech != "authorized" {
            print("\nnote: first `transcribe file` run raises a one-time speech-recognition prompt.")
        }
    }
}

/// CLI error surface; each case pins one documented exit code.
public enum CLIError: Error {
    case usage(String)
    case fileError(String)
    case localeNotReady(String)
    case transcriptionFailed(String)

    public var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .fileError: return 3
        case .localeNotReady: return 4
        case .transcriptionFailed: return 5
        }
    }

    public var errorMessage: String {
        switch self {
        case .usage(let m): return m
        case .fileError(let m): return m
        case .localeNotReady(let m): return "locale not ready: \(m)"
        case .transcriptionFailed(let m): return m
        }
    }
}
