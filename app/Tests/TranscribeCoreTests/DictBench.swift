import Foundation
import AVFoundation
import TranscribeCore

// Live verification driver for the dictation lane: routes synthetic clips
// through the REAL SpeechDictationEngine pipeline (FileBufferSource → same
// converter contract → analyzer → results loops → finalize). Not part of the
// unit suite; prints JSON evidence for reports/gates.
//
// Usage (from repo app/):
//   .build/release/TranscribeCoreTests dictbench <clip> [--locale ll-CC|auto]
//       [--runs N] [--speed X]              # latency + transcript runs
//   ... dictbench cancelstorm <clip> --cycles N
//   ... dictbench doubletap <clip>

struct BenchRecord: Codable {
    var run: Int
    var requestedLocale: String
    var chosenLane: String?
    var firstPartialMs: Double?
    var finalizeMs: Double?
    var drainMs: Double?
    var stopToTextMs: Double?
    var chars: Int
    var text: String
}

enum DictBench {

    static func run(_ args: [String]) async {
        guard let first = args.first else { print(usage); exit(2) }
        switch first {
        case "cancelstorm": await cancelStorm(Array(args.dropFirst()))
        case "doubletap":   await doubleTap(Array(args.dropFirst()))
        default:            await runs(args)
        }
    }

    static var usage: String {
        """
        dictbench <clip> [--locale ll-CC|auto] [--runs N] [--speed X]
        dictbench cancelstorm <clip> --cycles N
        dictbench doubletap <clip>
        """
    }

    private static func opt(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func positional(_ args: [String]) -> String? {
        args.first { !$0.hasPrefix("--") }
    }

    // MARK: timed runs

    static func runs(_ args: [String]) async {
        guard let clip = positional(args), clip.hasPrefix("/") else {
            print("need absolute clip path"); print(usage); exit(2)
        }
        let fileURL = URL(fileURLWithPath: clip)
        let requested = opt(args, "--locale") ?? "auto"
        let runs = Int(opt(args, "--runs") ?? "10") ?? 10
        let speed = Double(opt(args, "--speed") ?? "1.0") ?? 1.0

        var records: [BenchRecord] = []
        for i in 0..<runs {
            let rec = await oneRun(fileURL: fileURL, requestedLocale: requested,
                                   speed: speed, run: i)
            let data = try! JSONEncoder().encode(rec)
            print(String(data: data, encoding: .utf8)!)
            records.append(rec)
        }

        // Warm stats: drop run 0 (cold model/assets path).
        let warm = Array(records.dropFirst())
        func stat(_ key: (BenchRecord) -> Double?) -> (p50: Double?, p95: Double?) {
            let vals = warm.compactMap(key).sorted()
            guard !vals.isEmpty else { return (nil, nil) }
            func pct(_ p: Double) -> Double { vals[min(vals.count - 1, Int(p * Double(vals.count)))] }
            return (vals[vals.count / 2], pct(0.95))
        }
        let s2t = stat(\.stopToTextMs)
        let fin = stat(\.finalizeMs)
        let fp = stat(\.firstPartialMs)
        let summary: [String: String] = [
            "warm_runs": String(warm.count),
            "stopToText_p50_ms": s2t.p50.map { String(format: "%.0f", $0) } ?? "-",
            "stopToText_p95_ms": s2t.p95.map { String(format: "%.0f", $0) } ?? "-",
            "finalize_p50_ms": fin.p50.map { String(format: "%.0f", $0) } ?? "-",
            "firstPartial_p50_ms": fp.p50.map { String(format: "%.0f", $0) } ?? "-",
        ]
        print("SUMMARY " + summary.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", "))
    }

    static func oneRun(fileURL: URL, requestedLocale: String, speed: Double, run: Int) async -> BenchRecord {
        let audioDur = ((try? AVAudioFile(forReading: fileURL)).map {
            Double($0.length) / $0.processingFormat.sampleRate } ?? 1.0)
        let engine: SpeechDictationEngine? = await MainActor.run {
            let source = FileBufferSource(url: fileURL, speed: speed)
            let engine = SpeechDictationEngine(localeManager: LocaleManager(), audioSource: source)
            do {
                try engine.start(localeSetting: requestedLocale == "auto" ? nil : requestedLocale)
            } catch {
                print("START_FAILED \(error.localizedDescription)")
                return nil
            }
            return engine
        }
        guard let engine else { exit(4) }

        // Realtime-paced feed matches live-mic frontier conditions.
        try? await Task.sleep(for: Duration.seconds(audioDur / speed + 0.4))

        let res = await engine.finish()          // hops to MainActor
        let metrics = await engine.lastMetrics
        let lane = await engine.lastChosenLaneID
        var rec = BenchRecord(
            run: run, requestedLocale: requestedLocale, chosenLane: lane,
            firstPartialMs: metrics?.firstPartialMs,
            finalizeMs: metrics?.finalizeMs,
            drainMs: metrics?.drainMs,
            stopToTextMs: metrics?.stopToTextMs,
            chars: 0, text: "")
        switch res {
        case .success(let text): rec.text = text; rec.chars = text.count
        case .failure(let e):    rec.text = "ERROR: \(e.localizedDescription)"
        }
        return rec
    }


    // MARK: cancel cycles (AC-D5)

    static func cancelStorm(_ args: [String]) async {
        guard let clip = positional(args) else { print(usage); exit(2) }
        let cycles = Int(opt(args, "--cycles") ?? "20") ?? 20
        for i in 0..<cycles {
            let ok: Bool = await MainActor.run {
                let source = FileBufferSource(url: URL(fileURLWithPath: clip), speed: 8)
                let engine = SpeechDictationEngine(localeManager: LocaleManager(), audioSource: source)
                do { try engine.start(localeSetting: "en-US") } catch {
                    print("CANCELSTORM_START_FAIL \(error)"); return false
                }
                engine.cancel()
                return !engine.isActive
            }
            guard ok else { print("CANCELSTORM FAILED cycle \(i)"); exit(5) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        print("CANCELSTORM OK cycles=\(cycles) no orphaned state")
    }

    // MARK: hotkey double-tap regression

    static func doubleTap(_ args: [String]) async {
        guard let clip = positional(args) else { print(usage); exit(2) }
        let url = URL(fileURLWithPath: clip)
        let dur = ((try? AVAudioFile(forReading: url)).map {
            Double($0.length) / $0.processingFormat.sampleRate } ?? 3.0)

        // start → stop → start works: two back-to-back sessions, fresh analyzers.
        var texts: [Int] = []
        for pass in 1...2 {
            let engine: SpeechDictationEngine? = await MainActor.run {
                let source = FileBufferSource(url: url, speed: 2)
                let engine = SpeechDictationEngine(localeManager: LocaleManager(), audioSource: source)
                do { try engine.start(localeSetting: "en-US") } catch {
                    print("DOUBLETAP FAIL pass \(pass): \(error)"); return nil
                }
                return engine
            }
            guard let engine else { exit(6) }
            try? await Task.sleep(for: Duration.seconds(dur / 2 + 0.3))
            let res = await engine.finish()
            guard case .success(let t) = res, !t.isEmpty else {
                print("DOUBLETAP FAIL pass \(pass): \(res)"); exit(6)
            }
            texts.append(t.count)
        }
        print("DOUBLETAP OK passes=\(texts.count) chars=\(texts)")
    }
}
