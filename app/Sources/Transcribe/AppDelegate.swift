import AppKit
import Carbon
import AVFoundation
import ApplicationServices
import os
import TranscribeCore

/// AppKit delegate: everything here runs on the main actor (menu bar app,
/// single UI thread). The native dictation engine is @MainActor too, so the
/// lane wiring stays synchronous and race-free.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recorder = Recorder()
    private let pill = DictationPill()
    private let filePill = DictationPill()
    // Native lane (engine == "apple"): built only when routed; the mlx path
    // below stays byte-for-byte 0.6.0 (cutover safety).
    private var nativeEngine: SpeechDictationEngine?
    private var nativeActive = false
    private var livePartial: String?
    private let signposter = OSSignposter(subsystem: "app.transcribe", category: "dictation")
    private var fileHUDVisible = false
    private var engine: EngineClient!
    private var config = AppConfig.load()
    private var currentModelName: String?

    // Live dictation and file jobs are independent. The engine serializes
    // inference, but recording and file work can overlap without replacing
    // each other's state or feedback.
    private enum LiveState { case idle, recording, transcribing }
    private var liveState: LiveState = .idle
    private var liveCancelled = false
    private var liveRequestID: UUID?
    private var liveTask: URLSessionDataTask?

    private var fileQueue: [URL] = []
    private var activeFileURL: URL?
    private var fileRequestID: UUID?
    private var fileTask: URLSessionDataTask?
    private var pendingFileStatuses: [DictationPill.PillState] = []
    private var appReady = false
    private var queuedOpenURLs: [URL] = []
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    // menu handles
    private var setupItem: NSMenuItem!
    private var engineItem: NSMenuItem!
    private var enginePollTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = EngineClient(port: config.port)
        setupStatusItem()
        setupHotKey()
        setupPill()
        setupNativeLaneIfRouted()
        engine.ensureEngineRunning { [weak self] ok in
            self?.refreshEngineState()
        }
        // Menu open and every transcribe re-check health anyway; this slow poll
        // only keeps the menu label fresh while the menu is closed.
        enginePollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // RunLoop timers fire on the main thread.
            MainActor.assumeIsolated { self?.checkEngine() }
        }
        appReady = true
        let urls = queuedOpenURLs
        queuedOpenURLs.removeAll()
        urls.forEach(handleOpenURL)
        startNextFileIfNeeded()
    }

    private func setupPill() {
        // One animation clock: the waveform's own 60 Hz tick reads the recorder
        // meter directly (no separate level timer).
        pill.levelProvider = { [weak self] in self?.recorder.level() ?? 0 }
        pill.onCancel = { [weak self] _ in
            self?.cancelDictation()
        }
        pill.onHidden = { [weak self] in
            self?.refreshHUD()
        }
        filePill.onCancel = { [weak self] _ in
            self?.cancelFileTranscription()
        }
        filePill.onHidden = { [weak self] in
            self?.refreshHUD()
        }
    }

    // Finder and the Quick Action hand files over as open-file events.
    // Defer them until the engine client exists on a cold launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("Transcribe: received open URLs (%ld)", urls.count)
        if !appReady {
            queuedOpenURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(handleOpenURL)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        NSLog("Transcribe: received open files (%ld)", filenames.count)
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if !appReady {
            queuedOpenURLs.append(contentsOf: urls)
        } else {
            urls.forEach(enqueueFile)
        }
        application.reply(toOpenOrPrint: .success)
    }

    private func handleOpenURL(_ url: URL) {
        guard url.isFileURL else {
            NSLog("Transcribe: ignoring unsupported URL %@", absoluteStringOf(url))
            return
        }
        enqueueFile(url)
    }

    private func absoluteStringOf(_ url: URL) -> String { url.absoluteString }

    private func startEscapeMonitoring() {
        stopEscapeMonitoring()
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // 53 == kVK_Escape
                DispatchQueue.main.async {
                    self?.cancelDictation()
                }
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    self?.cancelDictation()
                }
                return nil // swallows the event
            }
            return event
        }
    }

    private func stopEscapeMonitoring() {
        if let m = globalEscapeMonitor {
            NSEvent.removeMonitor(m)
            globalEscapeMonitor = nil
        }
        if let m = localEscapeMonitor {
            NSEvent.removeMonitor(m)
            localEscapeMonitor = nil
        }
    }

    private var engineUp = false {
        didSet {
            guard engineUp != oldValue else { return }
            DispatchQueue.main.async { self.refreshEngineState() }
        }
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        showIdleIcon()
        statusItem.button?.toolTip = "Transcribe — tap \(hotKeyLabel()) to start and stop dictation"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // contextual setup row: only appears when something needs attention
        setupItem = NSMenuItem(title: "", action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        setupItem.isHidden = true
        menu.addItem(setupItem)

        // No keyboard-equivalent hints here on purpose: the global hotkey
        // (default ^Space) is the one way to dictate, and advertising a second
        // chord would invite conflicts. Menu items stay as click fallbacks.
        let dictate = NSMenuItem(title: "Dictate", action: #selector(toggleDictation),
                                 keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)

        let file = NSMenuItem(title: "Transcribe File…", action: #selector(pickFile),
                              keyEquivalent: "")
        file.target = self
        menu.addItem(file)

        menu.addItem(.separator())

        engineItem = NSMenuItem(title: "Engine: starting…", action: #selector(restartEngine),
                                keyEquivalent: "")
        engineItem.target = self
        menu.addItem(engineItem)

        let sessions = NSMenuItem(title: "Sessions Folder…", action: #selector(openSessions),
                                  keyEquivalent: "")
        sessions.target = self
        menu.addItem(sessions)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About Transcribe", action: #selector(showAbout),
                                keyEquivalent: ""))
        let quit = NSMenuItem(title: "Quit Transcribe", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu bar appearance

    private func showIdleIcon() {
        statusItem.button?.image = Self.templateImage("mic")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.contentTintColor = fileHUDVisible ? .systemOrange : nil
        statusItem.button?.title = ""
    }

    private func showRecording() {
        statusItem.button?.image = Self.templateImage("mic")
        statusItem.button?.contentTintColor = .systemRed
        refreshHUD()
    }

    private func showTranscribing() {
        statusItem.button?.contentTintColor = fileHUDVisible ? .systemOrange : nil
        refreshHUD()
    }

    private func flashResult() {
        statusItem.button?.contentTintColor = fileHUDVisible ? .systemOrange : nil
        pill.setPresentation(compact: fileHUDVisible,
                             horizontalOffset: fileHUDVisible ? -18 : 0)
        pill.show(.success)
    }

    // MARK: - Setup & state rows

    private func refreshEngineState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                self.setupItem.title = "Enable Accessibility to Paste…"
                self.setupItem.isHidden = false
            } else {
                self.setupItem.isHidden = true
            }
            if self.engineUp {
                let suffix = self.modelShortName().map { " — \($0)" } ?? ""
                self.engineItem.title = "Engine: running\(suffix)"
                self.engineItem.action = #selector(self.restartEngine)
            } else {
                self.engineItem.title = "Engine: not running — Start"
                self.engineItem.action = #selector(self.restartEngine)
            }
        }
    }

    /// Short model label derived from the engine's own /health report, so the
    /// menu can never drift from the model actually loaded.
    private func modelShortName() -> String? {
        guard let name = currentModelName else { return nil }
        let short = name.split(separator: "/").last.map(String.init) ?? name
        return short.hasPrefix("whisper-") ? String(short.dropFirst("whisper-".count)) : short
    }

    private func checkEngine() {
        engine.health { [weak self] up, model in
            guard let self else { return }
            if let model { self.currentModelName = model }
            self.engineUp = up
        }
    }

    private func setupHotKey() {
        guard let parsed = HotKey.parse(config.hotkey) else {
            NSLog("Transcribe: could not parse hotkey %@", config.hotkey)
            return
        }
        let hk = HotKey()
        hk.onAction = { [weak self] _ in
            // Tap-to-toggle: first tap starts recording, second tap stops and
            // transcribes. No press-and-hold, no accidental releases.
            self?.toggleDictation()
        }
        if !hk.register(modifiers: parsed.modifiers, keyCode: parsed.keyCode) {
            presentAlert(title: "Hotkey Not Available",
                         message: "\(hotKeyLabel()) is already in use by another app.\n\nChange it with:\n    transcribe config set hotkey \"ctrl+option+space\"")
        }
        hotKey = hk
    }

    private func hotKeyLabel() -> String {
        let parts = config.hotkey.split(separator: "+").map(String.init)
        let symbols: [String: String] = [
            "ctrl": "⌃", "control": "⌃", "option": "⌥", "alt": "⌥",
            "shift": "⇧", "cmd": "⌘", "command": "⌘",
        ]
        return parts.map { symbols[$0.lowercased()] ?? $0.capitalized }.joined(separator: "")
    }

    // MARK: - Dictation

    /// Keep the two panels as one centered notch cluster. A file is a large
    /// pill by itself. Once live dictation joins, the live pill becomes medium
    /// on the left and the file pill becomes a circular activity indicator on
    /// the right.
    private func refreshHUD() {
        let shouldShowFile = activeFileURL != nil || !pendingFileStatuses.isEmpty
        fileHUDVisible = shouldShowFile
        let concurrent = shouldShowFile && liveState != .idle
        statusItem.button?.contentTintColor = shouldShowFile
            ? .systemOrange
            : (liveState == .recording ? .systemRed : nil)
        statusItem.button?.toolTip = shouldShowFile
            ? "Transcribe — file transcription in progress"
            : "Transcribe — tap \(hotKeyLabel()) to start and stop dictation"

        // The offsets keep the entire medium-pill + circle cluster centered.
        filePill.setPresentation(compact: concurrent,
                                 circle: concurrent,
                                 horizontalOffset: concurrent ? 63 : 0)
        if let file = activeFileURL {
            filePill.show(.transcribing(fileName: file.lastPathComponent))
        } else if let status = pendingFileStatuses.first {
            pendingFileStatuses.removeFirst()
            filePill.show(status)
        } else {
            filePill.show(.hidden)
        }

        pill.setPresentation(compact: shouldShowFile,
                             horizontalOffset: shouldShowFile ? -18 : 0)
        switch liveState {
        case .recording:
            pill.show(.recording(partial: livePartial))
        case .transcribing:
            pill.show(.transcribing(fileName: nil))
        case .idle:
            pill.show(.hidden)
        }
    }

    @objc private func toggleDictation() {
        switch liveState {
        case .idle: startDictation()
        case .recording: stopDictation()
        case .transcribing: break
        }
    }

    private func startDictation() {
        guard liveState == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            presentAlert(title: "Microphone Access Needed",
                         message: "Allow Transcribe to use the microphone in System Settings, then dictate again.",
                         actionTitle: "Open System Settings",
                         action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) })
            return
        default:
            break
        }
        if config.engine == "apple" {
            startDictationNative()
            return
        }
        liveCancelled = false
        liveState = .recording
        showRecording()
        startEscapeMonitoring()
        do {
            _ = try recorder.start()
            NSSound(named: NSSound.Name("Pop"))?.play()
        } catch {
            liveState = .idle
            stopEscapeMonitoring()
            showIdleIcon()
            refreshHUD()
            presentAlert(title: "Can't Record", message: error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard liveState == .recording else { return }
        if liveCancelled { return }
        if config.engine == "apple" { stopDictationNative(); return }
        guard let url = recorder.currentURL else { return }
        liveState = .transcribing
        showTranscribing()
        recorder.stop()
        NSSound(named: NSSound.Name("Tink"))?.play()
        sendForTranscription(url: url)
    }

    @objc private func cancelDictation() {
        guard liveState != .idle else { return }
        liveCancelled = true
        liveRequestID = nil
        liveTask?.cancel()
        liveTask = nil
        stopEscapeMonitoring()

        if nativeActive {
            nativeActive = false
            nativeEngine?.cancel()
            liveState = .idle
            showIdleIcon()
            pill.cancel()
            NSSound(named: NSSound.Name("Blow"))?.play()
            refreshHUD()
            return
        }

        if let url = recorder.currentURL {
            if recorder.isRecording { recorder.stop() }
            try? FileManager.default.removeItem(at: url)
        }

        liveState = .idle
        showIdleIcon()
        pill.cancel()
        NSSound(named: NSSound.Name("Blow"))?.play()
    }

    private func sendForTranscription(url: URL) {
        let requestID = UUID()
        liveRequestID = requestID
        engine.ensureEngineRunning { [weak self] ok in
            guard let self,
                  self.liveState == .transcribing,
                  self.liveRequestID == requestID else { return }
            guard ok else {
                self.liveRequestID = nil
                self.liveState = .idle
                self.stopEscapeMonitoring()
                self.showIdleIcon()
                self.pill.show(.error("Engine Offline"))
                return
            }
            self.engineUp = true
            self.liveTask = self.engine.transcribe(path: url) { [weak self] result in
                guard let self,
                      self.liveRequestID == requestID else { return }
                self.liveRequestID = nil
                self.liveTask = nil
                self.liveState = .idle
                self.stopEscapeMonitoring()

                if self.liveCancelled {
                    try? FileManager.default.removeItem(at: url)
                    self.refreshHUD()
                    return
                }
                switch result {
                case .success(let tr):
                    let text = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        self.showIdleIcon()
                        self.pill.show(.empty)
                    } else if AXIsProcessTrusted() {
                        Paste.paste(text)
                        Paste.clearIfUnchanged(text)
                        self.flashResult()
                    } else {
                        // Accessibility missing: leave the text on the pasteboard
                        // so Cmd+V still works manually.
                        Paste.copyOnly(text)
                        Paste.clearIfUnchanged(text)
                        self.flashResult()
                    }
                case .failure(let error):
                    self.showIdleIcon()
                    self.pill.show(.error("Failed"))
                    self.presentAlert(title: "Transcription Failed",
                                      message: error.localizedDescription)
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Native dictation lane (engine == "apple", design §3)

    /// Build the native engine + LocaleManager only when routed. The mlx path
    /// never touches the Speech stack (cutover safety).
    private func setupNativeLaneIfRouted() {
        guard config.engine == "apple" else { return }
        let localeManager = LocaleManager()
        let eng = SpeechDictationEngine(localeManager: localeManager)
        eng.onPartial = { [weak self] text in self?.handleLivePartial(text) }
        eng.onNotice = { [weak self] message in self?.handleLiveNotice(message) }
        eng.onFailure = { [weak self] message in self?.handleNativeFailure(message) }
        nativeEngine = eng
        Task { await localeManager.bootstrap() }   // AC-L1 cache fill + reservations
    }

    private func startDictationNative() {
        liveCancelled = false
        livePartial = nil
        Task {
            // np-G1 ordering: mic first (guarded above), speech second.
            guard await SpeechPermissions.ensureAuthorizedForDictation() else {
                presentAlert(title: "Speech Recognition Needed",
                             message: "Allow Transcribe to use speech recognition in System Settings, then dictate again.",
                             actionTitle: "Open System Settings",
                             action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!) })
                return
            }
            do {
                try nativeEngine?.start(localeSetting: config.locale)
                nativeActive = true
                liveState = .recording
                showRecording()
                startEscapeMonitoring()
                NSSound(named: NSSound.Name("Pop"))?.play()
            } catch {
                liveState = .idle
                showIdleIcon()
                refreshHUD()
                presentAlert(title: "Can't Record", message: error.localizedDescription)
            }
        }
    }

    private func stopDictationNative() {
        guard let eng = nativeEngine else { return }
        liveState = .transcribing
        showTranscribing()
        NSSound(named: NSSound.Name("Tink"))?.play()
        let stopAt = Date()
        signposter.emitEvent("dictation.stopRequested")
        Task {
            let result = await eng.finish()
            if let m = eng.lastMetrics {
                NSLog("DICTATION firstPartial=%@ms finalize=%.0fms drain=%.0fms stopToText=%.0fms wall(stop→paste-entry branch)=%@",
                      m.firstPartialMs.map { String(format: "%.0f", $0) } ?? "-",
                      m.finalizeMs ?? -1, m.drainMs ?? -1,
                      m.stopToTextMs ?? -1,
                      String(format: "%.0f", Date().timeIntervalSince(stopAt) * 1000))
            }
            guard !liveCancelled else {
                nativeActive = false
                liveState = .idle
                showIdleIcon()
                refreshHUD()
                return
            }
            switch result {
            case .success(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    showIdleIcon()
                    pill.show(.empty)
                } else if AXIsProcessTrusted() {
                    signposter.emitEvent("dictation.pasteEntry")   // AC-D1 endpoint
                    Paste.paste(text)
                    Paste.clearIfUnchanged(text)
                    flashResult()
                } else {
                    // Accessibility missing: leave the text on the pasteboard
                    // so Cmd+V still works manually (0.6.0 parity).
                    signposter.emitEvent("dictation.pasteEntry")
                    Paste.copyOnly(text)
                    Paste.clearIfUnchanged(text)
                    flashResult()
                }
                archiveNativeSession(transcript: text)
            case .failure(let error):
                showIdleIcon()
                pill.show(.error("Failed"))
                presentAlert(title: "Transcription Failed",
                             message: error.localizedDescription)
            }
            nativeActive = false
            liveState = .idle
            stopEscapeMonitoring()
            showIdleIcon()
            refreshHUD()
        }
    }

    /// Streaming partials → HUD label (≤10 Hz deduped upstream, design §10).
    private func handleLivePartial(_ text: String?) {
        livePartial = text
        if liveState == .recording { pill.show(.recording(partial: text)) }
    }

    /// Friendly mid-session status reuses the live-label slot ("Downloading
    /// Italiano…"); real partials overwrite it as soon as they flow.
    private func handleLiveNotice(_ message: String) {
        if liveState == .recording { pill.show(.recording(partial: message)) }
    }

    /// Engine already cleaned itself; tear down session UI visibly (AC-D4:
    /// never a silent wait).
    private func handleNativeFailure(_ message: String) {
        nativeActive = false
        liveState = .idle
        stopEscapeMonitoring()
        showIdleIcon()
        refreshHUD()
        pill.show(.error(message))
        presentAlert(title: "Dictation Unavailable", message: message)
    }

    /// Design §3.10: WAV archive happens OFF the latency path, after paste.
    private func archiveNativeSession(transcript: String) {
        guard let audio = nativeEngine?.lastSessionAudio else { return }
        let localeID = nativeEngine?.lastChosenLaneID ?? ""
        let keep = config.keepTranscripts
        // SessionStore is main-actor isolated; this Task runs AFTER paste has
        // fired, so the archive stays off the hotkey-up latency path (§3.10).
        let store = SessionStore()
        Task(priority: .utility) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe_native_\(UUID().uuidString).wav")
            do {
                try WavFile.data(pcm: audio.pcm, sampleRate: audio.sampleRate,
                                 channels: audio.channels).write(to: tmp)
                store.saveBestEffort(recording: tmp, transcript: transcript,
                                     model: "apple/\(localeID)", language: localeID,
                                     source: "live", keepTranscripts: keep)
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                NSLog("Transcribe: session archive skipped (\(error.localizedDescription))")
            }
        }
    }

    private func enqueueFile(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            pendingFileStatuses.append(.error("File not found"))
            refreshHUD()
            return
        }
        fileQueue.append(url)
        startNextFileIfNeeded()
    }

    private func startNextFileIfNeeded() {
        guard activeFileURL == nil else {
            refreshHUD()
            return
        }
        guard let url = fileQueue.first else {
            refreshHUD()
            return
        }
        fileQueue.removeFirst()
        activeFileURL = url
        let requestID = UUID()
        fileRequestID = requestID
        refreshHUD()

        engine.ensureEngineRunning { [weak self] ok in
            guard let self,
                  self.activeFileURL == url,
                  self.fileRequestID == requestID else { return }
            guard ok else {
                self.finishFile(url: url, requestID: requestID,
                                result: .failure(NSError(domain: "Transcribe", code: 4,
                                                          userInfo: [NSLocalizedDescriptionKey: "Engine is not running"])))
                return
            }
            self.engineUp = true
            self.fileTask = self.engine.transcribe(path: url,
                                                    preserveSource: true) { [weak self] result in
                self?.finishFile(url: url, requestID: requestID, result: result)
            }
        }
    }

    private func finishFile(url: URL, requestID: UUID,
                            result: Result<TranscriptionResult, Error>) {
        guard activeFileURL == url, fileRequestID == requestID else { return }
        fileTask = nil
        fileRequestID = nil
        activeFileURL = nil

        switch result {
        case .success(let transcription):
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                pendingFileStatuses.append(.empty)
            } else {
                // The engine writes the .md beside the source before responding;
                // only fall back to writing it here if it reported none.
                let serverMD = URL(fileURLWithPath: transcription.transcriptPath)
                if transcription.transcriptPath.isEmpty
                    || !FileManager.default.fileExists(atPath: serverMD.path) {
                    do {
                        _ = try writeMarkdown(for: url, text: text)
                    } catch {
                        pendingFileStatuses.append(.error("Could not save file"))
                        startNextFileIfNeeded()
                        return
                    }
                }
                pendingFileStatuses.append(.fileSuccess)
            }
        case .failure:
            pendingFileStatuses.append(.error("File failed"))
        }
        startNextFileIfNeeded()
    }

    private func cancelFileTranscription() {
        fileTask?.cancel()
        fileTask = nil
        fileRequestID = nil
        activeFileURL = nil
        fileQueue.removeAll()
        pendingFileStatuses.removeAll()
        refreshHUD()
        filePill.cancel()
        NSSound(named: NSSound.Name("Blow"))?.play()
    }

    // MARK: - Actions

    @objc private func openSetup() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func restartEngine() {
        engine.ensureEngineRunning { [weak self] ok in
            self?.engineUp = ok
            guard ok else { return }
            self?.reloadEngineRetrying(remaining: 10)
        }
    }

    /// /reload is non-blocking: it answers 503 while a job runs. Retry briefly
    /// instead of discarding the restart; the status row keeps showing the
    /// (still running) engine either way.
    private func reloadEngineRetrying(remaining: Int) {
        engine.reload { [weak self] ok in
            guard let self, !ok, remaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.reloadEngineRetrying(remaining: remaining - 1)
            }
        }
    }

    @objc private func pickFile() {
        let panel = NSOpenPanel()
        // Do not filter by extension or Uniform Type Identifier here. ffmpeg
        // decides whether the selected media has a decodable audio stream, so
        // uncommon containers and files without a normal extension work too.
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.message = "Choose any media file with an audio track to transcribe locally."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.enqueueFile(url)
        }
    }

    private func writeMarkdown(for audioURL: URL, text: String) throws -> URL {
        let outputURL = audioURL.deletingPathExtension().appendingPathExtension("md")
        let title = audioURL.deletingPathExtension().lastPathComponent
        let markdown = "# \(title)\n\n\(text)\n"
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    @objc private func openSessions() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/transcribe/sessions")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        NSWorkspace.shared.open(base)
    }

    @objc private func checkForUpdates() {
        Updater.checkForUpdates()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Transcribe \(Updater.currentVersion)"
        alert.informativeText = "Fully local dictation and transcription.\n\nWhisper runs on this Mac — nothing leaves your machine. Audio and transcripts are cleaned up automatically."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentAlert(title: String, message: String,
                              actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let actionTitle, let action {
            alert.addButton(withTitle: actionTitle)
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { action() }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Helpers

    static func templateImage(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        image?.isTemplate = true
        return image
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        checkEngine()
        refreshEngineState()
    }
}
