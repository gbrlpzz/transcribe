import Foundation

// Test runner: executes every suite entry, prints PASS/SKIP/FAIL lines,
// exits non-zero on any failure. `swift run TranscribeCoreTests`.
@main
struct Runner {
    static func main() async {
        // dictbench <wav> ... : live verification of the dictation lane
        // (synthetic clips through the REAL engine pipeline). Not part of the
        // 32-case suite; used by b-dictation acceptance + merge gates.
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "dictbench" {
            await DictBench.run(Array(args.dropFirst(2)))
            return
        }
        let suites: [(String, [(String, TestCase)])] = [
            ("LocaleManagerTests", LocaleManagerTests.allTests),
            ("SessionStoreTests", SessionStoreTests.allTests),
            ("AppConfigTests", AppConfigTests.allTests),
            ("DictationSupportTests", DictationSupportTests.allTests),
            ("CLITests", CLITests.allTests)
        ]
        var passed = 0, skipped = 0, failed = 0
        for (suiteName, tests) in suites {
            print("== \(suiteName)")
            for (name, test) in tests {
                do {
                    try await test()
                    passed += 1
                    print("  PASS \(name)")
                } catch let e as TestSkipped {
                    skipped += 1
                    print("  SKIP \(name) — \(e.reason)")
                } catch {
                    failed += 1
                    print("  FAIL \(name): \(error)")
                }
            }
        }
        print("== \(passed) passed, \(skipped) skipped, \(failed) failed")
        if failed > 0 { exit(1) }
        exit(0)
    }
}
