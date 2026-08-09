import AppKit
import Carbon
import AVFoundation
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recorder = Recorder()
    private var engine: EngineClient!
    private var config = AppConfig.load()

    // state
    private enum DictationState { case idle, recording, transcribing }
    private var state: DictationState = .idle
    private var recordingStart: Date?
    private var recordingTimer: Timer?

    // menu handles
    private var setupItem: NSMenuItem!
    private var engineItem: NSMenuItem!
    private var modelMenu: NSMenu!
    private var languageMenu: NSMenu!
    private var enginePollTimer: Timer?

    private let modelAliases: [(alias: String, repo: String, note: String)] = [
        ("large-v3-turbo", "mlx-community/whisper-large-v3-turbo", "best balance"),
        ("large-v3", "mlx-community/whisper-large-v3", "maximum accuracy"),
        ("medium", "mlx-community/whisper-medium", "lighter"),
        ("small", "mlx-community/whisper-small", "lightest multilingual"),
        ("turbo", "mlx-community/whisper-turbo", "English only — fastest"),
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
        engine.ensureEngineRunning { [weak self] ok in
            self?.refreshEngineState()
        }
        enginePollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.engine.health { ok in self?.engineUp = ok }
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
        statusItem.button?.toolTip = "Transcribe — hold \(hotKeyLabel()) to dictate"

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
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func showRecording() {
        statusItem.button?.image = Self.templateImage("record.circle")
        statusItem.button?.contentTintColor = .systemRed
        statusItem.button?.imagePosition = .imageLeading
        recordingStart = Date()
        updateRecordingTime()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateRecordingTime()
        }
    }

    private func updateRecordingTime() {
        guard let start = recordingStart else { return }
        let s = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
    }

    private func showTranscribing() {
        statusItem.button?.image = Self.templateImage("waveform")
        statusItem.button?.contentTintColor = nil
        statusItem.button?.title = ""
    }

    private func flashResult(_ text: String) {
        let preview = String(text.prefix(28)) + (text.count > 28 ? "…" : "")
        statusItem.button?.image = Self.templateImage("checkmark.circle")
        statusItem.button?.title = "  \(preview)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.showIdleIcon()
        }
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
            switch action {
            case .pressed: self?.startDictation()
            case .released: self?.stopDictation()
            }
        }
        hk.register(modifiers: parsed.modifiers, keyCode: parsed.keyCode)
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
        state = .recording
        showRecording()
        do {
            _ = try recorder.start()
            NSSound(named: NSSound.Name("Pop"))?.play()
        } catch {
            state = .idle
            showIdleIcon()
            presentAlert(title: "Can't Record", message: error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard state == .recording, let url = recorder.currentURL else { return }
        state = .transcribing
        showTranscribing()
        recorder.stop()
        NSSound(named: NSSound.Name("Tink"))?.play()
        sendForTranscription(url: url)
    }

    private func sendForTranscription(url: URL) {
        engine.ensureEngineRunning { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.state = .idle
                self.showIdleIcon()
                self.presentAlert(title: "Engine Not Found",
                                  message: "Install the engine first:\n\n    uv tool install prime-transcribe\n\nThen restart Transcribe.")
                return
            }
            self.engineUp = true
            self.engine.transcribe(path: url, language: self.config.language) { result in
                defer { self.state = .idle }
                switch result {
                case .success(let tr):
                    let text = tr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        self.showIdleIcon()
                        self.presentAlert(title: "Nothing Heard",
                                          message: "The recording was empty. Try speaking closer to the microphone.")
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
                    self.showIdleIcon()
                    self.presentAlert(title: "Transcription Failed",
                                      message: error.localizedDescription)
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .wav]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to transcribe locally."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.showTranscribing()
            self.engine.ensureEngineRunning { ok in
                guard ok else {
                    self.showIdleIcon()
                    self.presentAlert(title: "Engine Not Found",
                                      message: "Run `uv tool install prime-transcribe` first.")
                    return
                }
                self.engine.transcribe(path: url, language: self.config.language) { result in
                    self.showIdleIcon()
                    switch result {
                    case .success(let tr):
                        Paste.copyOnly(tr.text)
                        let alert = NSAlert()
                        alert.messageText = "Transcription Ready"
                        alert.informativeText = "\(tr.text)\n\n(Copied to the clipboard.)"
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    case .failure(let error):
                        self.presentAlert(title: "Transcription Failed", message: error.localizedDescription)
                    }
                }
            }
        }
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
        alert.informativeText = "Fully local dictation and transcription for Prime Agent.\n\nWhisper runs on this Mac — nothing leaves your machine. Audio and transcripts are wiped automatically after \(Int(config.cleanupTtlHours)) hours."
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
