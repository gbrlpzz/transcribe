import AppKit
import Carbon
import ApplicationServices
import Speech
import os
import TranscribeCore
import TranscribeCLI

/// AppKit delegate: everything here runs on the main actor (menu bar app,
/// single UI thread). The native dictation engine is @MainActor too, so the
/// lane wiring stays synchronous and race-free.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let pill = DictationPill()
    private let filePill = DictationPill()
    private let localeManager = LocaleManager()
    private var nativeEngine: SpeechDictationEngine!
    private var nativeActive = false
    private let signposter = OSSignposter(subsystem: "app.transcribe", category: "dictation")
    private var fileHUDVisible = false
    private var config = AppConfig.load()

    private enum LiveState { case idle, recording, transcribing }
    private var liveState: LiveState = .idle
    private var liveCancelled = false

    private var fileQueue: [URL] = []
    private var activeFileURL: URL?
    private var fileRequestID: UUID?
    private var fileTask: Task<Void, Never>?
    private var pendingFileStatuses: [DictationPill.PillState] = []
    private var appReady = false
    private var queuedOpenURLs: [URL] = []
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    // menu handles
    private var setupItem: NSMenuItem!
    private var languageMenu: NSMenu!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        nativeEngine = SpeechDictationEngine(localeManager: localeManager)
        nativeEngine.onFailure = { [weak self] message in self?.handleNativeFailure(message) }
        setupStatusItem()
        setupHotKey()
        setupPill()
        Task { await localeManager.bootstrap() }
        appReady = true
        Updater.checkAndInstall()  // lean full-auto: silent unless updating
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
    // Defer them until the native lanes exist on a cold launch.
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

        languageMenu = NSMenu()
        menu.addItem(NSMenuItem(title: "Language", action: nil, keyEquivalent: ""))
        menu.item(at: menu.numberOfItems - 1)?.submenu = languageMenu
        refreshLanguageMenu()

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
        pill.setPresentation(horizontalOffset: fileHUDVisible ? -48 : 0)
        pill.show(.success)
    }

    // MARK: - Setup & language rows

    private func refreshSetupState() {
        guard !AXIsProcessTrusted() else {
            setupItem.isHidden = true
            return
        }
        setupItem.title = "Enable Accessibility to Paste…"
        setupItem.isHidden = false
    }

    private func refreshLanguageMenu() {
        guard let languageMenu else { return }
        languageMenu.removeAllItems()
        addLanguageItem("Auto (system language)", value: "auto", to: languageMenu)
        languageMenu.addItem(.separator())
        Task { @MainActor [weak self, weak languageMenu] in
            guard let self, let languageMenu else { return }
            let locales = await SpeechTranscriber.supportedLocales
                .sorted { LocaleManager.bcp47($0) < LocaleManager.bcp47($1) }
            for locale in locales {
                let id = LocaleManager.bcp47(locale)
                self.addLanguageItem(Locale.current.localizedString(forIdentifier: id) ?? id,
                                     value: id, to: languageMenu)
            }
            self.markSelectedLanguage()
        }
    }

    private func addLanguageItem(_ title: String, value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        menu.addItem(item)
    }

    private func markSelectedLanguage() {
        let selected = config.isLocaleAuto ? "auto" : config.locale?.lowercased()
        for item in languageMenu.items {
            item.state = (item.representedObject as? String)?.lowercased() == selected ? .on : .off
        }
    }

    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        config.locale = value == "auto" ? nil : value
        try? config.save()
        markSelectedLanguage()
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

        // Symmetric cluster: visible solids distribute evenly around the
        // notch center (spacing 96 pt between solid centers).
        filePill.setPresentation(horizontalOffset: concurrent ? 48 : 0)
        if let file = activeFileURL {
            filePill.show(.transcribing(fileName: file.lastPathComponent))
        } else if let status = pendingFileStatuses.first {
            pendingFileStatuses.removeFirst()
            filePill.show(status)
        } else {
            filePill.show(.hidden)
        }

        pill.setPresentation(horizontalOffset: shouldShowFile ? -48 : 0)
        switch liveState {
        case .recording:
            pill.show(.recording)
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
        startDictationNative()
    }

    private func stopDictation() {
        guard liveState == .recording, !liveCancelled else { return }
        stopDictationNative()
    }

    @objc private func cancelDictation() {
        guard liveState != .idle else { return }
        liveCancelled = true
        stopEscapeMonitoring()
        if nativeActive { nativeEngine.cancel() }
        nativeActive = false
        liveState = .idle
        showIdleIcon()
        pill.cancel()
        NSSound(named: NSSound.Name("Blow"))?.play()
        refreshHUD()
    }

    // MARK: - Native dictation lane


    private func startDictationNative() {
        liveCancelled = false
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
            // Tear session state down BEFORE showing the result flash, or the
            // trailing refreshHUD()'s pill.show(.hidden) kills it instantly.
            nativeActive = false
            liveState = .idle
            stopEscapeMonitoring()
            showIdleIcon()
            switch result {
            case .success(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    showIdleIcon()
                    pill.show(.hidden)
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
            case .failure(let error):
                showIdleIcon()
                pill.show(.hidden)
                presentAlert(title: "Transcription Failed",
                             message: error.localizedDescription)
            }
        }
    }

    /// Engine already cleaned itself; tear down session UI visibly (AC-D4:
    /// never a silent wait).
    private func handleNativeFailure(_ message: String) {
        nativeActive = false
        liveState = .idle
        stopEscapeMonitoring()
        showIdleIcon()
        refreshHUD()
        pill.show(.hidden)
        presentAlert(title: "Dictation Unavailable", message: message)
    }

    /// Design §3.10: nothing archives. The transcript lives in the clipboard
    /// and (for files) in the .md beside the audio — the app forgets the rest.
    private func enqueueFile(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            refreshHUD()
            return
        }
        fileQueue.append(url)
        startNextFileIfNeeded()
    }

    private func startNextFileIfNeeded() {
        guard activeFileURL == nil, let url = fileQueue.first else {
            refreshHUD()
            return
        }
        fileQueue.removeFirst()
        activeFileURL = url
        let requestID = UUID()
        fileRequestID = requestID
        refreshHUD()
        fileTask = Task { [weak self] in
            await self?.runFile(url, requestID: requestID)
        }
    }

    private func runFile(_ url: URL, requestID: UUID) async {
        do {
            try await TranscribeCLI.ensureSpeechAuthorized()
            let supported = await SpeechTranscriber.supportedLocales
            let locale: Locale
            if config.isLocaleAuto {
                guard let picked = TranscribeCLI.resolveAuto(system: .current, supported: supported),
                      let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: picked) else {
                    throw CLIError.localeNotReady("no supported locale is available")
                }
                locale = canonical
            } else {
                guard let raw = config.locale,
                      let canonical = await SpeechTranscriber.supportedLocale(
                        equivalentTo: Locale(identifier: raw)) else {
                    throw CLIError.localeNotReady("configured language is not supported")
                }
                locale = canonical
            }
            await localeManager.bootstrap()
            if !localeManager.isReady(locale),
               !(await localeManager.refreshReadiness(locale)) {
                try await localeManager.ensureInstalled(locale)
            }
            guard localeManager.isReady(locale) else {
                throw CLIError.localeNotReady("language assets are not ready")
            }
            let output = try await FileTranscriber.transcribe(url: url, locale: locale)
            guard activeFileURL == url, fileRequestID == requestID, !Task.isCancelled else { return }
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let md = try FileTranscriber.writeMarkdown(audioPath: url, text: output.text)
                pendingFileStatuses.append(.fileSuccess)
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeFileURL == url, fileRequestID == requestID else { return }
            NSLog("Transcribe: file failed %@ — %@", url.path, String(describing: error))
        }
        guard activeFileURL == url, fileRequestID == requestID else { return }
        fileTask = nil
        fileRequestID = nil
        activeFileURL = nil
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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Transcribe \(Updater.currentVersion)"
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
        refreshSetupState()
        refreshLanguageMenu()
    }
}
