import Foundation
import Speech

/// Locale truth + asset authority for Transcribe Leggerissimo (design §5, R42).
///
/// TRUTH RULE (np-G3/G4/G11): a locale is READY if and only if a
/// `SpeechTranscriber` built for it reports a non-empty
/// `availableCompatibleAudioFormats`. `AssetInventory.installedLocales` and
/// `AssetInventory.status` are NEVER used to gate features — installed lists
/// are per-class and lie, status reports `.supported` for fully-working
/// locales. Status is routing information for the install flow and the UI.
///
/// Concurrency: UI-facing reads (`isReady`) are synchronous on
/// the main actor because menu/HUD/picker all live there; probes and installs
/// run off-main and hop back. Swift 6 strict-concurrency clean.
@MainActor
public final class LocaleManager {
    private let service: any LocaleAssetService
    /// np-G10/L-ASSET watchdog budget: downloadAndInstall() can hang forever
    /// with zero error surface; this converts that into .timedOut (AC-L2).
    private let stallTimeout: TimeInterval
    private let pollInterval: TimeInterval

    // Functional-truth cache — the ONLY readiness source.
    private var readiness: [Locale: Bool] = [:]
    private var inFlight: Set<Locale> = []
    /// Reservations we own, oldest first (LRU). Primaries reserve at bootstrap,
    /// user-picked variants on demand (design §5.2).
    private(set) var reservations: [Locale] = []

    public init(service: any LocaleAssetService = SystemLocaleAssetService(),
                stallTimeout: TimeInterval = 120,
                pollInterval: TimeInterval = 1.0) {
        self.service = service
        self.stallTimeout = stallTimeout
        self.pollInterval = pollInterval
    }

    // MARK: - Public API (minimal surface used by the lanes/menu/CLI)

    /// App-start hook: reserve the system language (one slot) and fill the
    /// probe cache so the menu reflects readiness immediately. Never throws —
    /// capability problems surface as events/cache state, not crashes.
    public func bootstrap() async {
        guard SpeechTranscriber.isAvailable else { return }
        let supported = await service.supportedLocales()
        guard !supported.isEmpty else { return }
        let primaries = Self.primaryLocales(system: .current, supported: supported)
        let alreadyReserved = await service.reservedLocales()
        for p in primaries where Self.contains(alreadyReserved, p) {
            adopt(p)  // survive relaunches without wasting budget slots
        }
        for p in primaries {
            if Self.contains(reservations, p) {
                touch(p)
            } else {
                do {
                    if try await service.reserve(p) { reservations.append(p) }
                } catch {
                    if Self.mapInstallError(error) == .allocationExhausted { break }
                    // other reserve failures: stay graceful, keep probing
                }
            }
            _ = await probeAndCache(p)
        }
    }

    /// Cached readiness lookup (never probes; bcp47-matched so "en-US" input
    /// matches the canonicalized key).
    public func isReady(_ locale: Locale) -> Bool {
        if let v = readiness[locale] { return v }
        for (k, v) in readiness where Self.bcp47(k) == Self.bcp47(locale) { return v }
        return false
    }

    /// Full install flow (design §5.3): probe → route by status → installation
    /// request under a stall watchdog → re-probe before declaring installed.
    /// One retry for allocation errors: err 10 re-reserves; err 11 releases
    /// the least-recently-used reservation first.
    public func ensureInstalled(_ locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else { throw LocaleManagerError.speechUnavailable }
        guard let key = await service.canonical(locale) else {
            throw LocaleManagerError.unsupportedLocale
        }
        if isReady(key) { touch(key); return }
        var retriedAllocation = false
        while true {
            do {
                try await installOnce(key)
                return
            } catch let e as LocaleManagerError {
                guard !retriedAllocation else { throw e }
                switch e {
                case .localeNotAllocated:
                    retriedAllocation = true
                    _ = (try? await service.reserve(key)) ?? false  // ar-§6: 10 → re-reserve + retry
                case .allocationExhausted:
                    retriedAllocation = true
                    guard await releaseLeastRecentlyUsed(excluding: [key]) != nil else { throw e }
                    _ = (try? await service.reserve(key)) ?? false  // ar-§6: 11 → free LRU, retry once
                default:
                    throw e
                }
            }
        }
    }

    /// Force a functional probe now and update the cache (lanes call this
    /// before building pipelines when they need fresh truth).
    @discardableResult
    public func refreshReadiness(_ locale: Locale) async -> Bool {
        guard let key = await service.canonical(locale) else { return false }
        return await probeAndCache(key)
    }

    // MARK: - Locale helpers (R42 / design §5.4) — pure helpers, unit-tested

    nonisolated public static func bcp47(_ locale: Locale) -> String {
        // Lowercased: BCP-47 is case-insensitive; canonical form for cache keys.
        locale.identifier(.bcp47)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    /// Primary reservation at startup: the user's language when the speech
    /// stack supports it — exact variant preferred, else any variant of it.
    nonisolated public static func primaryLocales(system: Locale, supported: [Locale]) -> [Locale] {
        let pref = system.language
        guard let want = pref.languageCode?.identifier.lowercased() else { return [] }
        let matches = supported.filter { $0.languageCode?.lowercased() == want }
        let region = pref.region?.identifier.uppercased() ?? ""
        if !region.isEmpty,
           let exact = matches.first(where: { $0.region?.identifier.uppercased() == region }) {
            return [exact]
        }
        return Array(matches.prefix(1))
    }

    // MARK: - Install flow internals

    private func installOnce(_ key: Locale) async throws {
        let st = await service.status(for: key)
        if st == .unsupported {
            throw LocaleManagerError.unsupportedLocale  // ar-§6 15 → hide from picker
        }
        guard let request = try await service.installationRequest(for: key) else {
            // Design §5.3: nil request → treat as ready-if-formats-appear.
            throw LocaleManagerError.notAvailableAfterInstall
        }
        // Best-effort reserve; allocation errors during install drive the retry path.
        _ = (try? await service.reserve(key)) ?? false
        touch(key)
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        // UNSTRUCTURED task on purpose: np-G10 proved downloadAndInstall() can
        // hang ignoring cancellation. A structured group would hang at scope
        // exit awaiting the unkillable child; detached + explicit cancel +
        // report-and-move-on cannot hang ensureInstalled.
        let finished = CompletionFlag()
        let handle = Task.detached(priority: .utility) { [request, finished] in
            defer { finished.finish() }
            try await request.downloadAndInstall()
        }
        defer { handle.cancel() }
        do {
            try await watch(key, handle: handle, request: request, finished: finished)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as LocaleManagerError {
            throw e
        }
        // Post-install functional probe BEFORE marking installed (design §5.3;
        // np-G4: inventory flags alone never gate).
        if await probeAndCache(key) {
        } else {
            throw LocaleManagerError.notAvailableAfterInstall
        }
    }

    /// Polls install progress; any change resets the stall clock and emits a
    /// fraction event (totalUnitCount is opaque until transfer starts — np §4 —
    /// render fraction only). Silence ≥ stallTimeout ⇒ cancel + .timedOut.
    private func watch(_ key: Locale,
                       handle: Task<Void, Error>,
                       request: any LocaleInstallRequesting,
                       finished: CompletionFlag) async throws {
        var last = request.progressFraction()
        var stalled: TimeInterval = 0
        while true {
            if Task.isCancelled {
                handle.cancel()
                throw CancellationError()
            }
            if finished.isFinished { break }
            let f = request.progressFraction()
            if f != last {
                last = f
                stalled = 0
            } else {
                stalled += pollInterval
                if stalled >= stallTimeout {
                    handle.cancel()
                    throw LocaleManagerError.installTimedOut
                }
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        do {
            _ = try await handle.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapInstallError(error)
        }
    }

    private func probeAndCache(_ key: Locale) async -> Bool {
        let ok = await service.functionalProbe(key)
        readiness[key] = ok
        return ok
    }

    /// LRU bookkeeping: release the oldest reservation that is not in-flight.
    /// Returns the released locale or nil when nothing is releasable (caller
    /// then surfaces .allocationExhausted).
    @discardableResult
    private func releaseLeastRecentlyUsed(excluding blocked: Set<Locale>) async -> Locale? {
        for cand in reservations where !blocked.contains(cand) && !inFlight.contains(cand) {
            let released = await service.release(cand)
            if let idx = index(of: cand, in: reservations) { reservations.remove(at: idx) }
            if released { return cand }
        }
        return nil
    }

    private func adopt(_ locale: Locale) {
        if index(of: locale, in: reservations) == nil { reservations.append(locale) }
    }
    private func touch(_ locale: Locale) {
        if let idx = index(of: locale, in: reservations) {
            reservations.append(reservations.remove(at: idx))  // bump to most-recent
        }
    }
    private func index(of target: Locale, in list: [Locale]) -> Array<Locale>.Index? {
        list.firstIndex { $0 == target || Self.bcp47($0) == Self.bcp47(target) }
    }
    nonisolated private static func contains(_ list: [Locale], _ l: Locale) -> Bool {
        list.contains { $0 == l || bcp47($0) == bcp47(l) }
    }

    // MARK: - Error mapping (ar-§6 codes, measured rawValues)

    /// Maps Speech-domain errors onto our typed surface (ar-§6 codes).
    /// Public: the CLI reuses it for human-readable install failures.
    nonisolated public static func mapInstallError(_ error: Error) -> LocaleManagerError {
        let ns = error as NSError
        if ns.domain == SFSpeechErrorDomain, let code = SFSpeechError.Code(rawValue: ns.code) {
            switch code {
            case .assetLocaleNotAllocated: return .localeNotAllocated          // 10
            case .tooManyAssetLocalesAllocated: return .allocationExhausted    // 11
            case .timeout: return .installTimedOut                             // 12
            case .cannotAllocateUnsupportedLocale: return .unsupportedLocale   // 15
            case .insufficientResources: return .insufficientResources         // 16
            default: break
            }
        }
        if let sf = error as? SFSpeechError {
            switch sf.code {
            case .assetLocaleNotAllocated: return .localeNotAllocated
            case .tooManyAssetLocalesAllocated: return .allocationExhausted
            case .timeout: return .installTimedOut
            case .cannotAllocateUnsupportedLocale: return .unsupportedLocale
            case .insufficientResources: return .insufficientResources
            default: break
            }
        }
        return .installFailed(String(describing: error))
    }
}

// MARK: - Events / errors

public enum LocaleManagerError: Error, Equatable, Sendable {
    case speechUnavailable         // SpeechTranscriber.isAvailable == false
    case unsupportedLocale         // ar-§6 15 / absent from supportedLocales → hide from picker
    case installTimedOut           // np-G10 watchdog (120 s default) or ar-§6 12
    case allocationExhausted       // ar-§6 11 tooManyAssetLocalesAllocated with no LRU candidate
    case localeNotAllocated        // ar-§6 10 assetLocaleNotAllocated (retry re-reserves)
    case insufficientResources     // ar-§6 16
    case notAvailableAfterInstall  // np-G3 silence mode persists post-install
    case installFailed(String)
}

// MARK: - Service seam (injection point for tests)

/// One asset-install operation. `progressFraction` must be callable from any
/// thread while `downloadAndInstall` runs (Progress is thread-safe).
public protocol LocaleInstallRequesting: Sendable {
    func progressFraction() -> Double
    func downloadAndInstall() async throws
}

/// Everything LocaleManager needs from the Speech stack. Production impl is
/// `SystemLocaleAssetService`; tests inject fakes (no framework touched).
public protocol LocaleAssetService: Sendable {
    /// Canonical supported form of a user-facing identifier; nil = unsupported.
    func canonical(_ locale: Locale) async -> Locale?
    /// THE truth test (np-G3): transcriber constructs AND compat formats non-empty.
    func functionalProbe(_ canonical: Locale) async -> Bool
    func status(for canonical: Locale) async -> AssetInventory.Status?
    /// nil = nothing to install (design §5.3 ready-if-formats-appear branch).
    func installationRequest(for canonical: Locale) async throws -> (any LocaleInstallRequesting)?
    func reserve(_ canonical: Locale) async throws -> Bool
    @discardableResult func release(_ canonical: Locale) async -> Bool
    func reservedLocales() async -> [Locale]
    func supportedLocales() async -> [Locale]
}

/// Thin production adapter over AssetInventory/SpeechTranscriber.
/// Signatures verified against the macOS 26 swiftinterface (see
/// .work/reports/b-locales.md §0): reserve is `async throws -> Bool`,
/// availableCompatibleAudioFormats is an async property.
public struct SystemLocaleAssetService: LocaleAssetService {
    public init() {}

    public func canonical(_ locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func functionalProbe(_ canonical: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let t = SpeechTranscriber(locale: canonical, preset: .transcription)
        return !(await t.availableCompatibleAudioFormats).isEmpty
    }

    public func status(for canonical: Locale) async -> AssetInventory.Status? {
        let t = SpeechTranscriber(locale: canonical, preset: .transcription)
        return await AssetInventory.status(forModules: [t])
    }

    public func installationRequest(for canonical: Locale) async throws -> (any LocaleInstallRequesting)? {
        let t = SpeechTranscriber(locale: canonical, preset: .transcription)
        guard let raw = try await AssetInventory.assetInstallationRequest(supporting: [t]) else {
            return nil
        }
        return SystemInstallRequest(raw: raw)
    }

    public func reserve(_ canonical: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: canonical)
    }

    public func release(_ canonical: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: canonical)
    }

    public func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    public func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

/// Thread-safe completion flag for the unstructured install task (Task has no
/// synchronous isCompleted); polled by the watchdog loop.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// AssetInstallationRequest wrapper. @unchecked: Apple's request is backed by a
/// thread-safe Progress and was consumed cross-thread throughout nat-proto.
struct SystemInstallRequest: LocaleInstallRequesting, @unchecked Sendable {
    let raw: AssetInstallationRequest
    func progressFraction() -> Double { raw.progress.fractionCompleted }
    func downloadAndInstall() async throws { try await raw.downloadAndInstall() }
}
