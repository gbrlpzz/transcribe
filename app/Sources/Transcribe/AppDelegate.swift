import AppKit
import Carbon
import AVFoundation
import ApplicationServices
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recorder = Recorder()
    private let pill = DictationPill()
    private var engine: EngineClient!
    private var config = AppConfig.load()

    // state
    private enum DictationState { case idle, recording, transcribing }
    private var state: DictationState = .idle
    private var isCancelled = false
    // A file request is separate from microphone recording. Keeping an ID lets
    // us ignore a late HTTP response after the user cancels the file job.
    private var activeFileRequest: UUID?
    private var levelTimer: Timer?
    private var escapeHotKey: HotKey?
    private var escapeEventTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?
    private var localEscapeMonitor: Any?

    // menu handles
    private var setupItem: NSMenuItem!
    private var engineItem: NSMenuItem!
    private var modelMenu: NSMenu!
    private var languageMenu: NSMenu!
    private var enginePollTimer: Timer?

    private let modelAliases: [(alias: String, repo: String, note: String)] = [
        ("turbo", "mlx-community/whisper-turbo", "default — fastest (~1.0s)"),
        ("large-v3-turbo", "mlx-community/whisper-large-v3-turbo", "multilingual balance"),
        ("large-v3", "mlx-community/whisper-large-v3", "maximum accuracy"),
        ("medium", "mlx-community/whisper-medium", "lighter"),
        ("small", "mlx-community/whisper-small", "lightest footprint"),
    ]
    private let languages: [(id: String, label: String)] = [
        ("auto", "Auto"), ("en", "English"), ("it", "Italiano"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
    ]

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
    }

    private func setupPill() {
        pill.onCancel = { [weak self] in
            self?.cancelDictation()
        }
    }

    private func startEscapeMonitoring() {
        stopEscapeMonitoring()

        // Carbon hot keys are global and consume the key before the focused
        // application sees it. Register plain Escape only while a dictation is
        // active, so pressing it cancels Transcribe instead of closing a
        // terminal/agent session behind the HUD.
        let hotKey = HotKey()
        hotKey.onAction = { [weak self] action in
            guard case .pressed = action else { return }
            DispatchQueue.main.async {
                self?.cancelDictation()
            }
        }
        if hotKey.register(modifiers: 0, keyCode: 53) { // 53 == kVK_Escape
            escapeHotKey = hotKey
            return
        }

        // Fallback for systems that reject a plain Escape Carbon hot key:
        // a session event tap can both observe and suppress the key globally.
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.escapeEventTapCallback,
            userInfo: userInfo
        ) {
            escapeEventTap = tap
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                escapeRunLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                return
            }
            escapeEventTap = nil
        }

        // Last-resort in-app fallback. It cannot suppress Escape in another
        // app, but still cancels safely when Transcribe owns the event.
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    self?.cancelDictation()
                }
                return nil
            }
            return event
        }
        NSLog("Transcribe: could not install a global Escape interceptor")
    }

    private static let escapeEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = app.escapeEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak app] in
            app?.cancelDictation()
        }
        return nil // consume Escape globally
    }

    private func stopEscapeMonitoring() {
        if let hotKey = escapeHotKey {
            hotKey.unregister()
            escapeHotKey = nil
        }
        if let source = escapeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            escapeRunLoopSource = nil
        }
        if let tap = escapeEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            escapeEventTap = nil
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

        let dictate = NSMenuItem(title: "Dictate", action: #selector(toggleDictation),
                                 keyEquivalent: "d")
        dictate.target = self
        dictate.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(dictate)

        let file = NSMenuItem(title: "Transcribe File…", action: #selector(pickFile),
                              keyEquivalent: "o")
        file.target = self
        menu.addItem(file)

        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenu = NSMenu()
        for m in modelAliases {
            let item = NSMenuItem(title: "\(m.alias) — \(m.note)", action: #selector(selectModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = m.repo
            item.state = (config.model == m.repo || config.model == m.alias) ? .on : .off
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageMenu = NSMenu()
        for l in languages {
            let item = NSMenuItem(title: l.label, action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = l.id
            item.state = (config.language == l.id) ? .on : .off
            languageMenu.addItem(item)
        }
        langItem.submenu = languageMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        engineItem = NSMenuItem(title: "Engine: starting…", action: #selector(restartEngine),
                                keyEquivalent: "")
        engineItem.target = self
        menu.addItem(engineItem)

        let sessions = NSMenuItem(title: "Sessions Folder…", action: #selector(openSessions),
                                  keyEquivalent: "")
        sessions.target = self
        menu.addItem(sessions)
        let clean = NSMenuItem(title: "Clean Up Old Recordings", action: #selector(cleanNow),
                               keyEquivalent: "")
        clean.target = self
        menu.addItem(clean)

        menu.addItem(.separator())

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
        statusItem.button?.contentTintColor = nil
        statusItem.button?.title = ""
    }

    private func showRecording() {
        statusItem.button?.image = Self.templateImage("mic")
        statusItem.button?.contentTintColor = .systemRed
        pill.show(.recording)
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
        statusItem.button?.contentTintColor = nil
        pill.show(.transcribing)
    }

    private func flashResult(_ text: String) {
        statusItem.button?.contentTintColor = nil
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
        let repo = config.model
        for m in modelAliases where repo == m.repo || repo == m.alias {
            return m.alias
        }
        return repo
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

    @objc private func toggleDictation() {
        switch state {
        case .idle: startDictation()
        case .recording: stopDictation()
        case .transcribing: break
        }
    }

    private func startDictation() {
        guard state == .idle else { return }
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
        isCancelled = false
        state = .recording
        showRecording()
        startEscapeMonitoring()
        do {
            _ = try recorder.start()
            NSSound(named: NSSound.Name("Pop"))?.play()
        } catch {
            state = .idle
            stopEscapeMonitoring()
            showIdleIcon()
            presentAlert(title: "Can't Record", message: error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard state == .recording, let url = recorder.currentURL else { return }
        if isCancelled { return }
        state = .transcribing
        showTranscribing()
        recorder.stop()
        NSSound(named: NSSound.Name("Tink"))?.play()
        sendForTranscription(url: url)
    }

    @objc private func cancelDictation() {
        guard state != .idle else { return }
        isCancelled = true
        levelTimer?.invalidate()
        levelTimer = nil
        stopEscapeMonitoring()

        // File transcription has no recorder to stop. Invalidate its request
        // token so a response already in flight cannot resurrect the result.
        if activeFileRequest != nil {
            activeFileRequest = nil
            state = .idle
            showIdleIcon()
            pill.cancel()
            NSSound(named: NSSound.Name("Blow"))?.play()
            return
        }

        if recorder.isRecording {
            if let url = recorder.currentURL {
                try? FileManager.default.removeItem(at: url)
            }
            recorder.stop()
        }

        state = .idle
        showIdleIcon()
        pill.cancel()
        NSSound(named: NSSound.Name("Blow"))?.play()
    }

    private func sendForTranscription(url: URL) {
        engine.ensureEngineRunning { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.state = .idle
                self.stopEscapeMonitoring()
                self.showIdleIcon()
                self.presentAlert(title: "Engine Not Found",
                                  message: "Install the engine first:\n\n    uv tool install transcribe\n\nThen restart Transcribe.")
                return
            }
            self.engineUp = true
            self.engine.transcribe(path: url, language: self.config.language) { result in
                defer {
                    self.state = .idle
                    self.stopEscapeMonitoring()
                }
                if self.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                switch result {
                case .success(let tr):
                    let text = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        self.showIdleIcon()
                        self.pill.show(.empty)
                    } else if self.config.paste && AXIsProcessTrusted() {
                        Paste.paste(text)
                        self.flashResult(text)
                    } else if self.config.paste {
                        Paste.copyOnly(text)
                        self.flashResult(text)
                    } else {
                        Paste.copyOnly(text)
                        self.flashResult(text)
                    }
                case .failure(let error):
                    if !self.isCancelled {
                        self.showIdleIcon()
                        self.pill.show(.error("Failed"))
                        self.presentAlert(title: "Transcription Failed",
                                          message: error.localizedDescription)
                    }
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Actions

    @objc private func openSetup() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let repo = sender.representedObject as? String else { return }
        config.model = repo
        config.save()
        for item in modelMenu.items { item.state = .off }
        sender.state = .on
        engine.reload { [weak self] ok in self?.engineUp = ok }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String else { return }
        config.language = lang
        config.save()
        for item in languageMenu.items { item.state = .off }
        sender.state = .on
    }

    @objc private func restartEngine() {
        engine.ensureEngineRunning { [weak self] ok in
            self?.engineUp = ok
            if ok { self?.engine.reload() }
        }
    }

    @objc private func pickFile() {
        // Keep one transcription at a time. The same HUD is used for dictation
        // and file work, so overlapping jobs would make its status ambiguous.
        guard state == .idle, activeFileRequest == nil else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .wav]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to transcribe locally."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }

            let requestID = UUID()
            self.activeFileRequest = requestID
            self.isCancelled = false
            self.state = .transcribing
            self.showTranscribing()

            self.engine.ensureEngineRunning { [weak self] ok in
                guard let self, self.activeFileRequest == requestID else { return }
                guard ok else {
                    self.activeFileRequest = nil
                    self.state = .idle
                    self.showIdleIcon()
                    self.pill.show(.error("Engine Offline"))
                    self.presentAlert(title: "Engine Not Found",
                                      message: "Run `uv tool install transcribe` first.")
                    return
                }

                self.engine.transcribe(path: url, language: self.config.language) { [weak self] result in
                    guard let self, self.activeFileRequest == requestID else { return }
                    self.activeFileRequest = nil
                    self.state = .idle

                    switch result {
                    case .success(let tr):
                        let text = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            self.showIdleIcon()
                            self.pill.show(.empty)
                            self.presentAlert(title: "Nothing Heard",
                                              message: "No speech was detected in the selected file.")
                            return
                        }

                        Paste.copyOnly(text)
                        let outputURL: URL?
                        do {
                            outputURL = try self.writeMarkdown(for: url, text: text)
                        } catch {
                            outputURL = nil
                        }

                        self.flashResult(text)
                        let savedMessage = outputURL.map { "Saved to \($0.path)." }
                            ?? "The transcript could not be saved beside the audio file."
                        let alert = NSAlert()
                        alert.messageText = "Transcription Ready"
                        alert.informativeText = "\(savedMessage)\n\nThe text was copied to the clipboard."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()

                    case .failure(let error):
                        self.showIdleIcon()
                        self.pill.show(.error("Failed"))
                        self.presentAlert(title: "Transcription Failed",
                                          message: error.localizedDescription)
                    }
                }
            }
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

    @objc private func cleanNow() {
        // honor the configured TTL by asking the CLI; fall back to find(1)
        if let binary = EngineClient.resolveEngineBinary() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["clean"]
            try? proc.run()
            proc.waitUntilExit()
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/transcribe/sessions")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            proc.arguments = [base.path, "-type", "f", "-mtime", "+2", "-delete"]
            try? proc.run()
        }
        presentAlert(title: "Cleanup Done",
                     message: "Recordings and transcripts older than \(Int(config.cleanupTtlHours)) hours were removed.")
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Transcribe"
        alert.informativeText = "Fully local dictation and transcription.\n\nWhisper runs on this Mac — nothing leaves your machine. Audio and transcripts are wiped automatically after \(Int(config.cleanupTtlHours)) hours. Ships with a Prime Agent skill."
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
