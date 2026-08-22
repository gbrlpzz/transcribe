import AppKit
import Carbon
import AVFoundation
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recorder = Recorder()
    private let pill = DictationPill()
    private let filePill = DictationPill()
    private var fileHUDVisible = false
    private var engine: EngineClient!
    private var config = AppConfig.load()

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
    private var levelTimer: Timer?
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
        engine.ensureEngineRunning { [weak self] ok in
            self?.refreshEngineState()
        }
        enginePollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.engine.health { ok in self?.engineUp = ok }
        }
        appReady = true
        let urls = queuedOpenURLs
        queuedOpenURLs.removeAll()
        urls.forEach(handleOpenURL)
        startNextFileIfNeeded()
    }

    private func setupPill() {
        pill.onCancel = { [weak self] _ in
            self?.cancelDictation()
        }
        pill.onHidden = { [weak self] in
            self?.refreshLivePill()
        }
        filePill.onCancel = { [weak self] _ in
            self?.cancelFileTranscription()
        }
        filePill.onHidden = { [weak self] in
            self?.refreshHUD()
        }
    }

    // Finder may deliver a file as an open-file event, while the Quick Action
    // launcher can deliver a transcribe:// URL. Accept both forms and defer
    // them until the engine client exists when the app is launched cold.
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
        if url.scheme == "transcribe", url.host == "file" {
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value else {
                NSLog("Transcribe: file URL had no path")
                return
            }
            enqueueFile(URL(fileURLWithPath: path))
        } else if url.isFileURL {
            enqueueFile(url)
        } else {
            NSLog("Transcribe: ignoring unsupported URL scheme %@", url.scheme ?? "(none)")
        }
    }

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
        refreshLivePill()
        levelTimer?.invalidate()
        let t = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.pill.updateLevel(self?.recorder.level() ?? 0)
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func showTranscribing() {
        levelTimer?.invalidate()
        levelTimer = nil
        statusItem.button?.contentTintColor = fileHUDVisible ? .systemOrange : nil
        refreshLivePill()
    }

    private func flashResult(_ text: String) {
        statusItem.button?.contentTintColor = fileHUDVisible ? .systemOrange : nil
        pill.setPresentation(compact: fileHUDVisible,
                             horizontalOffset: fileHUDVisible ? -18 : 0)
        pill.show(.result(text))
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
                self.engineItem.title = "Engine: running — \(self.modelShortName())"
                self.engineItem.action = #selector(self.restartEngine)
            } else {
                self.engineItem.title = "Engine: not running — Start"
                self.engineItem.action = #selector(self.restartEngine)
            }
        }
    }

    private func modelShortName() -> String {
        "turbo-q4"
    }

    private func setupHotKey() {
        guard let parsed = HotKey.parse(config.hotkey) else {
            NSLog("Transcribe: could not parse hotkey %@", config.hotkey)
            return
        }
        let hk = HotKey()
        hk.onAction = { [weak self] action in
            // Tap-to-toggle: first tap starts recording, second tap stops and
            // transcribes. No press-and-hold, no accidental releases.
            switch action {
            case .pressed: self?.toggleDictation()
            case .released: break
            }
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

    private func refreshPill() {
        refreshHUD()
    }

    private func refreshLivePill() {
        refreshHUD()
    }

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
            filePill.show(.fileTranscribing(file.lastPathComponent))
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
            pill.show(.recording)
        case .transcribing:
            pill.show(.transcribing)
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
            refreshPill()
            presentAlert(title: "Can't Record", message: error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard liveState == .recording, let url = recorder.currentURL else { return }
        if liveCancelled { return }
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
        levelTimer?.invalidate()
        levelTimer = nil
        stopEscapeMonitoring()

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
                    self.refreshPill()
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
                        self.flashResult(text)
                    } else {
                        // Accessibility missing: leave the text on the pasteboard
                        // so Cmd+V still works manually.
                        Paste.copyOnly(text)
                        Paste.clearIfUnchanged(text)
                        self.flashResult(text)
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

    private func enqueueFile(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            pendingFileStatuses.append(.error("File not found"))
            refreshPill()
            return
        }
        fileQueue.append(url)
        startNextFileIfNeeded()
    }

    private func startNextFileIfNeeded() {
        guard activeFileURL == nil else {
            refreshPill()
            return
        }
        guard let url = fileQueue.first else {
            refreshPill()
            return
        }
        fileQueue.removeFirst()
        activeFileURL = url
        let requestID = UUID()
        fileRequestID = requestID
        refreshPill()

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
                pendingFileStatuses.append(.fileResult(url.lastPathComponent))
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
            if ok { self?.engine.reload() }
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
        engine.health { [weak self] ok in
            self?.engineUp = ok
        }
        refreshEngineState()
    }
}
