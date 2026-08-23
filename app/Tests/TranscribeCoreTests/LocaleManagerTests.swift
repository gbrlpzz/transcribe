import Foundation
import Speech
import TranscribeCore

// Fake service: dictionary-driven, locked state, zero Speech framework calls.
final class FakeService: LocaleAssetService, @unchecked Sendable {
    let lock = NSLock()

    /// Sync scoped locking keeps Swift 6 happy inside async methods.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    var supported: [Locale]
    var probeResults: [String: Bool] = [:]      // keyed by bcp47, default false
    var probeCount: [String: Int] = [:]
    var statusMap: [String: AssetInventory.Status] = [:]
    var requests: [String: () -> (any LocaleInstallRequesting)?] = [:]
    var maxReserve: Int = 5
    private(set) var reserved: [Locale] = []
    private(set) var reserveAttempts: [Locale] = []
    private(set) var releasedLocales: [Locale] = []
    var reserveThrowTooMany = false

    init(supported: [Locale]) { self.supported = supported }

    /// Sync state mutation from @Sendable install closures.
    func setProbe(_ key: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        probeResults[key] = value
    }

    func canonical(_ locale: Locale) async -> Locale? {
        supported.first { LocaleManager.bcp47($0) == LocaleManager.bcp47(locale) }
    }
    func functionalProbe(_ canonical: Locale) async -> Bool {
        let k = LocaleManager.bcp47(canonical)
        return locked {
            probeCount[k, default: 0] += 1
            return probeResults[k] ?? false
        }
    }
    func status(for canonical: Locale) async -> AssetInventory.Status? {
        locked { statusMap[LocaleManager.bcp47(canonical)] ?? .supported }
    }
    func installationRequest(for canonical: Locale) async throws -> (any LocaleInstallRequesting)? {
        locked { requests[LocaleManager.bcp47(canonical)]?() }
    }
    func reserve(_ canonical: Locale) async throws -> Bool {
        try locked {
            reserveAttempts.append(canonical)
            if reserveThrowTooMany && reserved.count >= maxReserve {
                throw NSError(domain: SFSpeechErrorDomain, code: 11)
            }
            if reserved.count >= maxReserve { return false }
            reserved.append(canonical)
            return true
        }
    }
    func release(_ canonical: Locale) async -> Bool {
        locked {
            if let i = reserved.firstIndex(where: { LocaleManager.bcp47($0) == LocaleManager.bcp47(canonical) }) {
                reserved.remove(at: i)
                releasedLocales.append(canonical)
                return true
            }
            return false
        }
    }
    func reservedLocales() async -> [Locale] { locked { reserved } }
    func supportedLocales() async -> [Locale] { supported }
}

// Fake request: closure-driven install + progress.
final class FakeRequest: LocaleInstallRequesting, @unchecked Sendable {
    let lock = NSLock()
    private var _progress: Double = 0
    var install: (@Sendable () async throws -> Void)?
    var installAttempts = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func progressFraction() -> Double { locked { _progress } }
    func setProgress(_ p: Double) { locked { _progress = p } }
    func attempts() -> Int { locked { installAttempts } }
    func downloadAndInstall() async throws {
        locked { installAttempts += 1 }
        try await install?()
    }
}

@MainActor
enum LocaleManagerTests {
    static let en = Locale(identifier: "en_US")
    static let de = Locale(identifier: "de_DE")
    static let it = Locale(identifier: "it_IT")
    static let es = Locale(identifier: "es_ES")

    static func makeService() -> FakeService {
        FakeService(supported: [en, de, it, es])
    }
    /// Fast watchdog settings for tests.
    static func makeManager(_ service: FakeService,
                            stall: TimeInterval = 0.3,
                            poll: TimeInterval = 0.05) -> LocaleManager {
        LocaleManager(service: service, stallTimeout: stall, pollInterval: poll)
    }

    // MARK: Truth rule + cache (np-G3/G4)

    static func probeTruthReadyAndCached() async throws {
        let svc = makeService()
        svc.setProbe("en-us", true)
        let m = makeManager(svc)
        await m.bootstrap()
        try require(m.isReady(en), "en must be ready after bootstrap")
        let before = svc.probeCount["en-us"]
        _ = m.isReady(en)
        _ = m.isReady(Locale(identifier: "en-US"))  // bcp47 alias match
        try requireEqual(svc.probeCount["en-us"], before ?? 0, "isReady must be cache-only (AC-L1)")
    }

    static func bootstrapReservesSystemPrimaryAndProbes() async throws {
        let svc = makeService()
        let m = makeManager(svc)
        await m.bootstrap()
        let want = LocaleManager.primaryLocales(system: .current, supported: [en, de, it, es])
        try requireEqual(svc.reserveAttempts.count, want.count,
                         "bootstrap reserves exactly the dynamic primary set")
        try require(!m.isReady(de), "uninstalled locale must not be ready (np-G4)")
    }

    static func bootstrapAdoptsPreExistingReservation() async throws {
        let svc = makeService()
        for p in LocaleManager.primaryLocales(system: .current, supported: [en, de, it, es]) {
            _ = try await svc.reserve(p)  // system-side reservations from a previous run
        }
        let seeded = svc.reserveAttempts.count
        let m = makeManager(svc)
        await m.bootstrap()
        try requireEqual(svc.reserveAttempts.count - seeded, 0,
                         "adopted primary not re-reserved")
    }

    static func bootstrapSurvivesTightReserveBudget() async throws {
        // System-independent: the supported set always contains this Mac's own
        // locale, so exactly one dynamic primary exists to exercise.
        let svc = FakeService(supported: [.current, en])
        svc.maxReserve = 1  // budget too small: stop reserving, keep probing, no crash
        svc.reserveThrowTooMany = false
        let m = makeManager(svc)
        await m.bootstrap()
        let totalProbes = svc.probeCount.values.reduce(0, +)
        try require(totalProbes >= 1, "the primary is probed despite tight reserve budget")
    }

    // MARK: Install success path (AC-L2)

    static func ensureInstalledSuccessEventsAndProbeBeforeInstalled() async throws {
        let svc = makeService()
        let req = FakeRequest()
        req.install = {
            svc.setProbe("it-it", true)  // assets land → functional truth flips
            req.setProgress(1.0)                             // progress moves → no stall
        }
        svc.requests["it-it"] = { req }
        let m = makeManager(svc)
        let stream = await m.installStatus(it)
        let collector = Task<[InstallEvent], Never> {
            var out: [InstallEvent] = []
            for await e in stream {
                out.append(e)
                if out.count >= 5 { break }
            }
            return out
        }
        try await m.ensureInstalled(it)
        let events = await collector.value
        try requireEqual(events.first, InstallEvent.needsInstall, "snapshot first")
        try require(events.contains(InstallEvent.installed), "installed event present")
        try requireEqual(events.last, InstallEvent.ready, "terminal ready event")
        try require(events.contains(.downloading(progress: 0.0)),
                    "initial progress fraction emitted when install starts")
        try requireEqual(req.installAttempts, 1)
        try require(m.isReady(it), "post-install functional probe flips the cache")
    }

    static func requestNilWithStillEmptyFormatsThrowsNotAvailable() async throws {
        let svc = makeService()
        svc.requests["it-it"] = { nil }  // §5.3: nil request → ready-if-formats-appear else unavailable
        let m = makeManager(svc)
        do { try await m.ensureInstalled(it); throw fail("must throw") }
        catch let e as TestSkipped { throw e }
        catch let e as LocaleManagerError {
            try requireEqual(e, LocaleManagerError.notAvailableAfterInstall)
        } catch let e as TestFailure { throw e }
          catch { throw fail("unexpected error type: \(error)") }
    }

    static func unsupportedStatusThrowsUnsupported() async throws {
        let svc = makeService()
        svc.statusMap["it-it"] = .unsupported
        let m = makeManager(svc)
        do { try await m.ensureInstalled(it); throw fail("must throw") }
        catch let e as LocaleManagerError {
            try requireEqual(e, LocaleManagerError.unsupportedLocale)
        } catch let e as TestFailure { throw e }
          catch { throw fail("unexpected error type: \(error)") }
    }

    static func canonicalRejectsUnknownLocale() async throws {
        let m = makeManager(makeService())
        do { try await m.ensureInstalled(Locale(identifier: "xx-XX")); throw fail("must throw") }
        catch let e as LocaleManagerError {
            try requireEqual(e, LocaleManagerError.unsupportedLocale)
        } catch let e as TestFailure { throw e }
          catch { throw fail("unexpected error type: \(error)") }
    }

    // MARK: Watchdog (np-G10 / AC-L2 timedOut + cancel)

    static func stalledInstallTimesOutWithinBudget() async throws {
        let svc = makeService()
        let req = FakeRequest()
        req.install = { try await Task.sleep(for: .seconds(30)) }  // L-ASSET hang simulation
        svc.requests["it-it"] = { req }
        let m = makeManager(svc, stall: 0.2, poll: 0.05)
        let t0 = Date()
        do { try await m.ensureInstalled(it); throw fail("must time out") }
        catch let e as LocaleManagerError {
            try requireEqual(e, LocaleManagerError.installTimedOut)
            try require(Date().timeIntervalSince(t0) < 5, "watchdog must fire near stall budget")
        } catch let e as TestFailure { throw e }
          catch { throw fail("unexpected error type: \(error)") }
    }

    static func progressChangeResetsStallClock() async throws {
        let svc = makeService()
        let req = FakeRequest()
        req.install = {
            for p in [0.25, 0.5, 0.75] {
                try await Task.sleep(for: .seconds(0.12))
                req.setProgress(p)
            }
            svc.setProbe("it-it", true)
            req.setProgress(1.0)
        }
        svc.requests["it-it"] = { req }
        let m = makeManager(svc, stall: 0.3, poll: 0.05)
        try await m.ensureInstalled(it)  // total ~0.48s > stall but moving
        try require(m.isReady(it), "moving installs must not time out")
    }

    // MARK: Error mapping + one-retry paths (ar-§6)

    static func err11ReleasesLRUAndRetriesOnce() async throws {
        let svc = makeService()
        let m = makeManager(svc)
        await m.bootstrap()
        let primaries = LocaleManager.primaryLocales(system: .current, supported: [en, de, it, es])
        if primaries.map(LocaleManager.bcp47) == ["it-it"] {
            throw TestSkipped("sole primary equals install target — no LRU candidate possible")
        }
        guard let lru = primaries.first else { throw fail("bootstrap must fill reservations") }
        let req = FakeRequest()
        req.install = {
            if req.attempts() == 1 {
                throw NSError(domain: SFSpeechErrorDomain, code: 11)  // tooManyAssetLocalesAllocated
            }
            svc.setProbe("it-it", true)
            req.setProgress(1.0)
        }
        svc.requests["it-it"] = { req }
        try await m.ensureInstalled(Locale(identifier: "it_IT"))
        try requireEqual(svc.releasedLocales.map(LocaleManager.bcp47), [LocaleManager.bcp47(lru)],
                         "LRU reservation released (§5.2)")
        try requireEqual(req.installAttempts, 2, "exactly one retry")
    }

    static func err11WithNothingReleasableRethrows() async throws {
        let svc = makeService()
        svc.maxReserve = 0  // no reservations can exist -> nothing releasable
        let m = makeManager(svc)
        await m.bootstrap()
        let req = FakeRequest()
        req.install = { throw NSError(domain: SFSpeechErrorDomain, code: 11) }
        svc.requests["it-it"] = { req }
        do { try await m.ensureInstalled(it); throw fail("must rethrow") }
        catch let e as LocaleManagerError {
            try requireEqual(e, LocaleManagerError.allocationExhausted)
        } catch let e as TestFailure { throw e }
          catch { throw fail("unexpected error type: \(error)") }
    }

    static func err10ReReservesAndRetriesOnce() async throws {
        let svc = makeService()
        let m = makeManager(svc)
        let req = FakeRequest()
        req.install = {
            if req.attempts() == 1 {
                throw NSError(domain: SFSpeechErrorDomain, code: 10)  // assetLocaleNotAllocated
            }
            svc.setProbe("es-es", true)
            req.setProgress(1.0)
        }
        svc.requests["es-es"] = { req }
        try await m.ensureInstalled(es)
        try requireEqual(req.installAttempts, 2)
        try require(svc.reserveAttempts.contains { LocaleManager.bcp47($0) == "es-es" },
                    "err10 path re-reserves the locale (ar-§6)")
    }

    static func errorCodeMapping() throws {
        func map(_ code: Int) -> LocaleManagerError {
            LocaleManager.mapInstallError(NSError(domain: SFSpeechErrorDomain, code: code))
        }
        try requireEqual(map(10), .localeNotAllocated)
        try requireEqual(map(11), .allocationExhausted)
        try requireEqual(map(12), .installTimedOut)
        try requireEqual(map(15), .unsupportedLocale)
        try requireEqual(map(16), .insufficientResources)
        if case .installFailed = map(99) {} else { throw fail("unknown codes map to installFailed") }
    }

    // MARK: Pure helpers (R42/§5.4 shipped set + primaries)

    static func primaryLocalesMatchesSystemVariant() throws {
        let supported = ["en_GB", "en_US", "it_IT"].map { Locale(identifier: $0) }
        let got = LocaleManager.primaryLocales(system: Locale(identifier: "en_GB"),
                                               supported: supported).map(LocaleManager.bcp47)
        try requireEqual(got, ["en-gb"])
    }

    static func primaryLocalesEmptyWhenLanguageUnsupported() throws {
        let supported = ["en_US", "de_DE"].map { Locale(identifier: $0) }
        let got = LocaleManager.primaryLocales(system: Locale(identifier: "ja_JP"),
                                               supported: supported).map(LocaleManager.bcp47)
        try requireEqual(got, [])
    }

    // MARK: Live fixtures (marked; skipped when assets absent on this machine)

    /// LIVE-FIXTURE: real SystemLocaleAssetService probes. en-US and de-DE are
    /// functional on the reference machine (nat-proto §4); skipped elsewhere /
    /// until assets arrive. it-IT/es-* stay L-ASSET-skipped by design.
    static func live_enUS_deDE_functionalProbe() async throws {
        let svc = SystemLocaleAssetService()
        let enCanon = await svc.canonical(Locale(identifier: "en-US"))
        guard let enCanon, await svc.functionalProbe(enCanon) else {
            throw TestSkipped("en_US assets absent on this machine — skipping live fixture")
        }
        let deCanon = await svc.canonical(Locale(identifier: "de-DE"))
        guard let deCanon, await svc.functionalProbe(deCanon) else {
            throw TestSkipped("de_DE assets absent on this machine — skipping live fixture")
        }
        // Manager-level live check against the truth cache.
        let m = LocaleManager(service: svc)
        try require(await m.refreshReadiness(enCanon), "live en-US probe")
        try require(await m.refreshReadiness(deCanon), "live de-DE probe")
    }

    static var allTests: [(String, TestCase)] {
        [
            ("probeTruthReadyAndCached", probeTruthReadyAndCached),
            ("bootstrapReservesSystemPrimaryAndProbes", bootstrapReservesSystemPrimaryAndProbes),
            ("bootstrapAdoptsPreExistingReservation", bootstrapAdoptsPreExistingReservation),
            ("bootstrapSurvivesTightReserveBudget", bootstrapSurvivesTightReserveBudget),
            ("ensureInstalledSuccessEventsAndProbeBeforeInstalled", ensureInstalledSuccessEventsAndProbeBeforeInstalled),
            ("requestNilWithStillEmptyFormatsThrowsNotAvailable", requestNilWithStillEmptyFormatsThrowsNotAvailable),
            ("unsupportedStatusThrowsUnsupported", unsupportedStatusThrowsUnsupported),
            ("canonicalRejectsUnknownLocale", canonicalRejectsUnknownLocale),
            ("stalledInstallTimesOutWithinBudget", stalledInstallTimesOutWithinBudget),
            ("progressChangeResetsStallClock", progressChangeResetsStallClock),
            ("err11ReleasesLRUAndRetriesOnce", err11ReleasesLRUAndRetriesOnce),
            ("err11WithNothingReleasableRethrows", err11WithNothingReleasableRethrows),
            ("err10ReReservesAndRetriesOnce", err10ReReservesAndRetriesOnce),
            ("errorCodeMapping", errorCodeMapping),
            ("primaryLocalesMatchesSystemVariant", primaryLocalesMatchesSystemVariant),
            ("primaryLocalesEmptyWhenLanguageUnsupported", primaryLocalesEmptyWhenLanguageUnsupported),
            ("live_enUS_deDE_functionalProbe", live_enUS_deDE_functionalProbe),
        ]
    }
}
