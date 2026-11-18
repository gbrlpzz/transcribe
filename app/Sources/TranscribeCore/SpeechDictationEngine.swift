import AVFoundation
import Foundation
import Speech
import os

// Live dictation lane — Leggerissimo design §3 (R41/R42a).
//
// Pipeline (hotkey-down → hotkey-up):
//
//   audio source (hardware mic tap, native rate)
//     → AVAudioConverter → 16 kHz / mono / interleaved Int16   [np-G7, ar-§2]
//     → unbounded AsyncStream<AnalyzerInput>                   [np-G8]
//     → SpeechAnalyzer([SpeechTranscriber(.progressiveTranscription)])
//         volatile results → internal recognition frontier (never rendered)
//         final results    → committed transcript (paste uses finals ONLY)
//   hotkey-up → finalizeAndFinishThroughEndOfInput()            [np-G2]
//             → transcript → Paste.paste (app layer)
//
// Auto runs one transcriber per preferred language over the SAME input
// sequence; the transcript is then the best path through their word-level
// confidences (Transcript.swift). A pinned language is a single transcriber
// whose finals are concatenated untouched.
//
// Evidence anchors: np-G1 TCC ordering · np-G2 explicit finalize · np-G3
// empty-formats silence · np-G5 AttributedString extraction · np-G7 i16
// precondition · np-G8 granularity free · ar-§3.4 flush cost · ar-§3.5/§3.7
// one-sequence-per-analyzer + keep-alive · ar-CONCURRENCY lane priority.

// MARK: - Audio source seam

/// Delivers raw input buffers at the hardware/native rate. Production source
/// is the microphone tap; verification drives the SAME converter/analyzer path
/// with file buffers (acceptance: synthetic clips through the real pipeline).
public protocol DictationAudioSource: AnyObject, Sendable {
    /// Native input format this source delivers (set before/at start).
    var rawFormat: AVAudioFormat? { get }
    /// Begin delivering buffers to `sink`. Called once per session.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Stop delivery. Idempotent, synchronous.
    func stop()
}

/// Hardware microphone tap for the native dictation lane.
public final class MicrophoneTapSource: DictationAudioSource, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()
    private var _level: Float = 0
    private var _rawFormat: AVAudioFormat?

    public init() {}

    public var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    public var rawFormat: AVAudioFormat? { lock.lock(); defer { lock.unlock() }; return _rawFormat }

    public func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = audioEngine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw DictationError.microphoneUnavailable
        }
        lock.lock(); _rawFormat = hw; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buffer, _ in
            self?.storeLevel(buffer)
            sink(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    public func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    /// RMS → dB → the 0…1 waveform level.
    private func storeLevel(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let step = max(1, n / 256)
        var acc: Float = 0
        var count = 0
        var i = 0
        while i < n { acc += ch[i] * ch[i]; count += 1; i += step }
        let rms = sqrt(acc / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        let mapped = max(0, min(1, (db + 55) / 55))
        lock.lock(); _level = mapped; lock.unlock()
    }
}

/// File reader for verification/bench: paces chunks at realtime × speed so
/// latency numbers mirror live-mic conditions (recognition frontier near the
/// playback head, short volatile tail at stop).
public final class FileBufferSource: DictationAudioSource, @unchecked Sendable {
    private let url: URL
    private let chunkFrames: AVAudioFrameCount
    private let speed: Double
    private let lock = NSLock()
    private var _rawFormat: AVAudioFormat?
    private var feedTask: Task<Void, Never>?

    public init(url: URL, chunkFrames: AVAudioFrameCount = 4096, speed: Double = 1.0) {
        self.url = url
        self.chunkFrames = chunkFrames
        self.speed = speed
    }

    public var rawFormat: AVAudioFormat? { lock.lock(); defer { lock.unlock() }; return _rawFormat }

    public func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        lock.lock(); _rawFormat = fmt; lock.unlock()
        let chunkDur = Double(chunkFrames) / fmt.sampleRate
        feedTask = Task { [chunkFrames, speed] in
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
                do { try file.read(into: buf, frameCount: chunkFrames) } catch { break }
                guard buf.frameLength > 0 else { break }
                sink(buf)
                if speed > 0 {
                    try? await Task.sleep(for: Duration.seconds(chunkDur / speed))
                }
            }
        }
    }

    public func stop() { feedTask?.cancel(); feedTask = nil }
}

// MARK: - Converter + stream pump (all cross-thread state lives here)

/// Converts raw source buffers to the analyzer contract (16 kHz mono i16
/// interleaved — feeding anything else trips a hard precondition, np-G7/ar §3.6)
/// and pumps them into the analyzer input stream. Tap callbacks arrive on the
/// audio render thread while binding/cleanup happen on MainActor, so every
/// field sits behind one lock.
final class IngestPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pendingRaw: [AVAudioPCMBuffer] = []

    /// Wire the pipeline to an analyzer input sequence. Buffers delivered
    /// before bind are held and drained here (analyzer setup ≈ 100–300 ms).
    func bind(rawFormat: AVAudioFormat, target: AVAudioFormat,
              continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        // np-G7 guard: refuse targets outside the compatible set BEFORE any
        // buffer can reach the analyzer's crashing precondition.
        let okRate = target.sampleRate == 16000 || target.sampleRate == 8000
        guard target.channelCount == 1, target.commonFormat == .pcmFormatInt16,
              target.isInterleaved, okRate else {
            throw DictationError.unsupportedTargetFormat(target)
        }
        lock.lock()
        if rawFormat.sampleRate == target.sampleRate,
           rawFormat.channelCount == target.channelCount,
           rawFormat.commonFormat == target.commonFormat,
           rawFormat.isInterleaved == target.isInterleaved {
            converter = nil                    // already analyzer-shaped, np-G7
        } else {
            guard let conv = AVAudioConverter(from: rawFormat, to: target) else {
                lock.unlock()
                throw DictationError.converterUnavailable
            }
            converter = conv
        }
        self.continuation = continuation
        let backlog = pendingRaw
        pendingRaw = []
        lock.unlock()
        backlog.forEach { convertAndYield($0) }
    }

    func deliver(_ raw: AVAudioPCMBuffer) {
        lock.lock()
        if continuation != nil { lock.unlock(); convertAndYield(raw); return }
        pendingRaw.append(raw)
        lock.unlock()
    }

    /// End-of-stream: flush converter tail, close the input sequence.
    func finishStream() {
        lock.lock()
        let cont = continuation
        let conv = converter
        lock.unlock()
        if let conv, let cont {
            guard let end = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: 8192) else { return }
            var err: NSError?
            _ = conv.convert(to: end, error: &err, withInputFrom: { _, status in
                status.pointee = .endOfStream
                return nil
            })
            if end.frameLength > 0 { cont.yield(AnalyzerInput(buffer: end)) }
        }
        cont?.finish()
    }

    func reset() {
        lock.lock()
        converter = nil; continuation = nil; pendingRaw = []
        lock.unlock()
    }

    private func convertAndYield(_ raw: AVAudioPCMBuffer) {
        lock.lock()
        let conv = converter
        let cont = continuation
        lock.unlock()
        if let conv {
            let ratio = conv.outputFormat.sampleRate / conv.inputFormat.sampleRate
            let cap = AVAudioFrameCount(Double(raw.frameLength) * ratio + 4096)
            guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
            // AVAudioPCMBuffer is not Sendable; the input block only ever runs
            // synchronously inside convert(), so confinement via this box is sound.
            final class BufferQueue: @unchecked Sendable {
                private let q = NSLock()
                private var items: [AVAudioPCMBuffer]
                init(_ items: [AVAudioPCMBuffer]) { self.items = items }
                func pop() -> AVAudioPCMBuffer? {
                    q.lock(); defer { q.unlock() }
                    return items.isEmpty ? nil : items.removeFirst()
                }
                func isEmpty() -> Bool { q.lock(); defer { q.unlock() }; return items.isEmpty }
            }
            let queue = BufferQueue([raw])
            while true {
                var err: NSError?
                let status = conv.convert(to: out, error: &err, withInputFrom: { _, outStatus in
                    if let next = queue.pop() {
                        outStatus.pointee = .haveData
                        return next
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                })
                if out.frameLength > 0, let cont { cont.yield(AnalyzerInput(buffer: out)) }
                if status == .haveData && !queue.isEmpty() { continue }  // more output pending
                if status == .endOfStream || status == .error || err != nil { break }
                break   // .inputRanDry / nothing produced: wait for next tap buffer
            }
        } else if let cont {
            cont.yield(AnalyzerInput(buffer: raw))   // already in target format: zero-copy path
        }
    }
}

// MARK: - Errors

public enum DictationError: LocalizedError, Equatable {
    case microphoneUnavailable
    case speechUnavailable
    case unsupportedLocale(String)
    case assetsNotReady(String)          // friendly 'language downloading' surface
    case unsupportedTargetFormat(AVAudioFormat)
    case converterUnavailable
    case analysisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "No microphone input is available."
        case .speechUnavailable:
            return "Apple speech transcription is unavailable on this Mac."
        case .unsupportedLocale(let id):
            return "\(id) is not a supported dictation language."
        case .assetsNotReady(let id):
            return "\(id) voice assets aren't on this Mac yet. Add the language under System Settings › Keyboard › Dictation, or pick another language."
        case .unsupportedTargetFormat(let f):
            return "Unsupported analyzer audio format: \(Int(f.sampleRate)) Hz / \(f.channelCount) ch."
        case .converterUnavailable:
            return "Could not build the audio converter for dictation."
        case .analysisFailed(let why):
            return why
        }
    }
}

// MARK: - Engine

/// One engine instance serves repeated toggle sessions (fresh analyzer each,
/// kept alive until its results streams close — ar-§3.5 one-sequence guard,
/// ar-§3.7 deallocation trap). Hotkey double-tap regression safety: every
/// start() rebuilds all session state; cancel()/finish() fully release it.
@MainActor
public final class SpeechDictationEngine {

    struct Lane {
        let id: String                  // BCP-47
        let transcriber: SpeechTranscriber
    }

    /// Mid-session hard failure (assets stall, analyzer error). The engine has
    /// already cleaned itself; the app layer tears down session UI. Not called
    /// while finish() is awaited — that failure is finish()'s return value, and
    /// reporting it twice means two alerts.
    public var onFailure: ((String) -> Void)?

    /// HUD waveform level (thread-safe read through the source).
    public var levelProvider: () -> Float {
        guard let tap = source as? MicrophoneTapSource else { return { 0 } }
        return { [tap] in tap.level }
    }

    public private(set) var isActive = false

    private let localeManager: LocaleManager?
    private let source: any DictationAudioSource
    private let signposter = OSSignposter(subsystem: "app.transcribe", category: "dictation")

    // Per-session state (MainActor-confined).
    private var lanes: [Lane] = []
    private var analyzer: SpeechAnalyzer?
    private var ingest = IngestPipeline()
    private var resultTasks: [Task<Void, Never>] = []
    private var setupTask: Task<Void, Never>?
    private var committed: [ObjectIdentifier: [String]] = [:]
    private var tail: [ObjectIdentifier: String] = [:]
    /// Word-level finals per lane; filled only when `wordLevel` is on.
    private var words: [ObjectIdentifier: [SpokenWord]] = [:]
    private var vocabulary: [String] = []
    /// More than one language, or a vocabulary: results carry time ranges
    /// and confidences and the transcript is composed from words.
    private var wordLevel = false
    private var finishing = false
    private var sessionError: Error?
    /// Set by failSession alongside cleanup so the REAL failure reason survives
    /// to finish()/cancel-time reporting (np-G1 lesson: never lose the why).
    private var pendingSessionError: Error?
    private var sawText = false
    private var startedAt: TimeInterval = 0
    private var firstPartialAt: TimeInterval = 0
    private var stopRequestedAt: TimeInterval = 0

    /// Measured legs of the last finished session (AC-D1 evidence).
    public struct Metrics: Sendable {
        public var firstPartialMs: Double?
        public var finalizeMs: Double?      // stop request → finalize returned
        public var drainMs: Double?         // finalize → result streams closed
        public var stopToTextMs: Double?    // stop request → chosen text ready
    }
    public private(set) var lastMetrics: Metrics?
    /// Languages (BCP-47) that made it into the last transcript.
    public private(set) var lastLanguages: [String] = []

    public init(localeManager: LocaleManager? = nil,
                audioSource: (any DictationAudioSource)? = nil) {
        self.localeManager = localeManager
        self.source = audioSource ?? MicrophoneTapSource()
    }

    // MARK: Session lifecycle

    /// Hotkey-down. Starts audio capture immediately; analyzer setup proceeds
    /// concurrently so early speech lands in the backlog instead of being lost.
    public func start(localeSetting: String?, vocabulary: [String] = []) throws {
        guard !isActive else { return }
        resetSessionState()
        self.vocabulary = vocabulary
        isActive = true
        startedAt = now()
        signposter.emitEvent("dictation.begin")
        let ingest = self.ingest
        try source.start { buffer in ingest.deliver(buffer) }
        let setting = localeSetting
        setupTask = Task { [weak self] in
            await self?.setupAndAnalyze(localeSetting: setting)
        }
    }

    /// Hotkey-up (np-G2): stop capture, force finalize, compose and return the
    /// transcript. Empty string ⇒ nothing heard.
    public func finish() async -> Result<String, Error> {
        guard isActive else {
            defer { pendingSessionError = nil }
            if let e = pendingSessionError { return .failure(e) }
            return .failure(DictationError.analysisFailed("not active"))
        }
        finishing = true
        defer { finishing = false }
        if let setupTask { await setupTask.value }          // ultra-short taps
        if let err = sessionError ?? pendingSessionError {
            cleanup()
            pendingSessionError = nil
            return .failure(err)
        }
        stopRequestedAt = now()
        signposter.emitEvent("dictation.stopRequested")
        source.stop()
        ingest.finishStream()

        var finalizeMs: Double?
        var drainMs: Double?
        func sinceStop() -> Double { (now() - stopRequestedAt) * 1000 }   // ms
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            finalizeMs = sinceStop()
            for task in resultTasks { await Self.awaitWithTimeout(task, seconds: 3) }
            drainMs = sinceStop()
        } catch {
            sessionError = DictationError.analysisFailed(String(describing: error))
        }

        let text = chosenText()
        var m = Metrics(firstPartialMs: nil, finalizeMs: finalizeMs,
                        drainMs: drainMs, stopToTextMs: sinceStop())
        if firstPartialAt > startedAt { m.firstPartialMs = (firstPartialAt - startedAt) * 1000 }
        lastMetrics = m
        signposter.emitEvent("dictation.finalized")
        let error = sessionError ?? pendingSessionError
        cleanup()
        pendingSessionError = nil
        if let error { return .failure(error) }
        return .success(text)
    }

    /// Escape / click-cancel. No orphaned analyzers or tasks survive (AC-D5).
    public func cancel() {
        guard isActive else { return }
        setupTask?.cancel()
        source.stop()
        ingest.finishStream()
        let doomed = analyzer
        for t in resultTasks { t.cancel() }
        cleanup()
        // Strong ref keeps the actor alive until cancellation lands (ar-§3.7:
        // never drop the last reference mid-analysis).
        if let doomed { Task { await doomed.cancelAndFinishNow() } }
    }

    // MARK: Setup

    private func setupAndAnalyze(localeSetting: String?) async {
        let pinnedLocale: Bool = {
            if let l = localeSetting?.lowercased(), !l.isEmpty, l != "auto" { return true }
            return false
        }()
        do {
            guard SpeechTranscriber.isAvailable else { throw DictationError.speechUnavailable }
            var resolved = try await resolveLanes(localeSetting: localeSetting)

            // np-G3: uninstalled locales fail SILENTLY via empty compat formats.
            // Keep ready lanes, DROP dark ones - instantly, with NO install
            // attempt here: downloadAndInstall() can stall ~120 s on Apple's
            // side (np-G10/L-ASSET) and hotkey-up must never wait on it.
            // Installs happen ONLY via an explicit language pick (menu / CLI).
            var ready = [Lane]()
            var darkNames = [String]()
            for lane in resolved {
                if await laneReady(lane.transcriber) { ready.append(lane) }
                else { darkNames.append(displayLanguage(lane.id)) }
            }
            if ready.isEmpty, resolved.count == 1, pinnedLocale, let only = resolved.first {
                // A PINNED locale is explicit intent: one watchdog-wrapped try.
                if let lm = localeManager {
                    try? await lm.ensureInstalled(Locale(identifier: only.id))
                }
                if await laneReady(only.transcriber) { ready = [only] }
            }
            guard !ready.isEmpty else {
                throw DictationError.assetsNotReady(
                    darkNames.joined(separator: ", "))
            }
            resolved = ready
            lanes = resolved

            let modules: [any SpeechModule] = resolved.map { $0.transcriber }
            guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw DictationError.assetsNotReady(
                    resolved.map { displayLanguage($0.id) }.joined(separator: "/"))
            }
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .whileInUse))
            self.analyzer = analyzer

            // AsyncStream's build closure runs synchronously: the continuation
            // exists NOW, so tap buffers can never race the bind below.
            var cont: AsyncStream<AnalyzerInput>.Continuation!
            let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) { c in cont = c }
            if let raw = source.rawFormat {
                try ingest.bind(rawFormat: raw, target: target, continuation: cont)
            }
            try await analyzer.start(inputSequence: stream)
            startResultLoops(resolved)
        } catch is CancellationError {
        } catch {
            failSession(error)
        }
    }

    /// Locale routing: a pinned BCP-47 setting runs a single-module analyzer;
    /// "auto"/nil runs one module per Auto language (LocaleManager.autoLocales,
    /// three at most) over one input sequence.
    func resolveLanes(localeSetting: String?) async throws -> [Lane] {
        var wanted: [Locale] = []
        if let setting = localeSetting?.lowercased(), !setting.isEmpty, setting != "auto" {
            guard let canon = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: setting)) else {
                throw DictationError.unsupportedLocale(setting)
            }
            wanted = [canon]
        } else {
            let supported = await SpeechTranscriber.supportedLocales
            for p in LocaleManager.autoLocales(preferred: LocaleManager.preferredLocales(), supported: supported) {
                if let canon = await SpeechTranscriber.supportedLocale(equivalentTo: p) { wanted.append(canon) }
            }
            if wanted.isEmpty { throw DictationError.speechUnavailable }
        }
        wordLevel = wanted.count > 1 || !vocabulary.isEmpty
        let preset = SpeechTranscriber.Preset.progressiveTranscription
        return wanted.map { locale in
            let transcriber = wordLevel
                ? SpeechTranscriber(locale: locale,
                                    transcriptionOptions: preset.transcriptionOptions,
                                    reportingOptions: preset.reportingOptions,
                                    attributeOptions: preset.attributeOptions.union(SpokenWord.attributes))
                : SpeechTranscriber(locale: locale, preset: preset)
            return Lane(id: locale.identifier(.bcp47), transcriber: transcriber)
        }
    }

    /// np-G3 functional probe. NEVER gate on AssetInventory.installedLocales
    /// (np-G4/G11: it lists locales whose modules still report .supported).
    private func laneReady(_ tr: SpeechTranscriber) async -> Bool {
        await !tr.availableCompatibleAudioFormats.isEmpty
    }

    private func startResultLoops(_ resolvedLanes: [Lane]) {
        for lane in resolvedLanes {
            let laneKey = ObjectIdentifier(lane.transcriber)
            resultTasks.append(Task { @MainActor [weak self] in
                do {
                    for try await r in lane.transcriber.results {
                        self?.apply(r.text, isFinal: r.isFinal, laneKey: laneKey)
                    }
                } catch is CancellationError {
                } catch {
                    self?.failSession(DictationError.analysisFailed(String(describing: error)))
                }
            })
        }
    }

    // MARK: Results

    private func apply(_ result: AttributedString, isFinal: Bool, laneKey: ObjectIdentifier) {
        guard isActive else { return }
        let text = String(result.characters)   // np-G5
        if isFinal {
            if !text.isEmpty { committed[laneKey, default: []].append(text) }
            if wordLevel { words[laneKey, default: []] += SpokenWord.words(in: result) }
            tail[laneKey] = nil
        } else {
            tail[laneKey] = text
        }
        if !sawText && !text.isEmpty {
            sawText = true
            firstPartialAt = now()
            signposter.emitEvent("dictation.firstPartial")
        }
    }

    /// Live text of a lane: committed finals + volatile tail. Results carry
    /// their own spacing (a continuation begins with a space), so they are
    /// concatenated as-is — joining with " " pastes two spaces per sentence.
    private func liveText(of lane: Lane) -> String {
        let key = ObjectIdentifier(lane.transcriber)
        var parts = committed[key] ?? []
        if let t = tail[key], !t.isEmpty { parts.append(t) }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The transcript at finalize. Word level: the best path through the
    /// lanes, vocabulary applied. Otherwise — one pinned language, or a
    /// stream that closed without word-level finals — the first lane that
    /// heard anything, verbatim.
    private func chosenText() -> String {
        if wordLevel {
            let composed = Transcript.compose(
                lanes: lanes.map { (id: $0.id, words: words[ObjectIdentifier($0.transcriber)] ?? []) },
                vocabulary: vocabulary)
            if !composed.text.isEmpty {
                lastLanguages = composed.languages
                return composed.text
            }
        }
        for lane in lanes {
            let text = liveText(of: lane)
            if !text.isEmpty {
                lastLanguages = [lane.id]
                return text
            }
        }
        return ""
    }

    // MARK: Failure & teardown

    /// Release the analyzer ONLY after its streams closed (ar-§3.7 deallocation
    /// trap); reset every session field so the next toggle starts clean.
    private func cleanup() {
        setupTask = nil
        resultTasks = []
        analyzer = nil
        lanes = []
        ingest.reset()
        committed = [:]; tail = [:]; words = [:]
        isActive = false
        sawText = false
        sessionError = nil
    }

    private func failSession(_ error: Error) {
        guard isActive else { return }
        sessionError = error
        source.stop()
        ingest.finishStream()
        let doomed = analyzer
        for t in resultTasks { t.cancel() }
        cleanup()
        if let doomed { Task { await doomed.cancelAndFinishNow() } }
        pendingSessionError = error
        if !finishing { onFailure?(error.localizedDescription) }
    }

    private func resetSessionState() {
        committed = [:]; tail = [:]; words = [:]
        vocabulary = []
        wordLevel = false
        lastLanguages = []
        sessionError = nil
        pendingSessionError = nil
        sawText = false
        startedAt = 0
        firstPartialAt = 0
        stopRequestedAt = 0
        lastMetrics = nil
    }

    private func displayLanguage(_ bcp47: String) -> String {
        let code = Locale(identifier: bcp47).language.languageCode?.identifier ?? bcp47
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func now() -> TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    nonisolated private static func awaitWithTimeout(_ task: Task<Void, Never>, seconds: Double) async {
        _ = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { _ = await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next()!
            group.cancelAll()
            // A group only returns once every child has: on timeout the
            // awaiter above is still parked on `task`, so end the task itself.
            if !first { task.cancel() }
            return first
        }
    }
}
