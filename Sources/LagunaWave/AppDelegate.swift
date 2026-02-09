import AppKit
import AVFoundation
import ApplicationServices
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, HotKeyDelegate, NSMenuDelegate {
    private enum ListeningMode {
        case pushToTalk
        case toggle
    }

    private let overlay = OverlayPanel()
    private let audio = AudioCapture()
    private let typer = TextTyper()
    private let transcriber = TranscriptionEngine()
    private var cleanupEngine: TextCleanupEngine { TextCleanupEngine.shared }
    private var isListening = false
    private var listeningMode: ListeningMode?
    private var lastSpeechTime: CFTimeInterval?
    private var toggleStartTime: CFTimeInterval?
    private let silenceThreshold: Float = 0.08
    private let toggleSilenceTimeout: TimeInterval = 10
    private let toggleMaxDuration: TimeInterval = 120
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var micMenuItem: NSMenuItem?
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var lastExternalApp: NSRunningApplication?
    private var lastExternalBundleID: String?
    private var lastExternalPID: pid_t?
    private var savedFocusWindowBounds: CGRect?
    private var escapeMonitor: Any?
    private var retypeClickMonitor: Any?
    private var retypeEscapeMonitor: Any?
    private var pendingFinish: DispatchWorkItem?
    private var typingEscapeMonitor: Any?
    private var autoEnterMenuItem: NSMenuItem?
    private var cleanupMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.general("Launched LagunaWave")
        Log.general("Bundle path: \(Bundle.main.bundlePath)")

        setupStatusItem()

        hotKeyManager = HotKeyManager(delegate: self)
        hotKeyManager?.register(hotKeys: [
            .pushToTalk: Preferences.shared.pushToTalkHotKey,
            .toggle: Preferences.shared.toggleHotKey
        ])

        audio.setInputDevice(uid: Preferences.shared.inputDeviceUID)
        audio.onLevel = { [weak self] level in
            self?.overlay.updateLevel(level)
            self?.handleAudioLevel(level)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(pushHotKeyChanged(_:)), name: .pushHotKeyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleHotKeyChanged(_:)), name: .toggleHotKeyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inputDeviceChanged(_:)), name: .inputDeviceChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRetypeTranscription(_:)), name: .retypeTranscription, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleModelChanged), name: .modelChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleLLMCleanupModelChanged), name: .llmCleanupModelChanged, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        Task { await performFirstRunSetup() }
    }

    private func performFirstRunSetup() async {
        // Step 1: Accessibility permission
        let trusted = AXIsProcessTrusted()
        Log.general("Setup: accessibility trusted=\(trusted)")
        if !trusted {
            await MainActor.run {
                self.overlay.showMessage("Enable Accessibility…")
            }
            // Show the system prompt that links to Settings
            let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

            // Poll until the user enables it in System Settings
            while !AXIsProcessTrusted() {
                try? await Task.sleep(nanoseconds: 500_000_000) // check every 0.5s
            }
            Log.general("Setup: accessibility now trusted")
            await MainActor.run {
                self.overlay.showMessage("Accessibility enabled")
                self.overlay.hide(after: 1.0)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000) // let user see confirmation
        }

        // Step 2: Microphone permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.general("Setup: microphone status=\(micStatus.rawValue)")
        if micStatus == .notDetermined {
            await MainActor.run {
                self.overlay.showMessage("Allow Microphone…")
            }
            // Brief pause so user sees the overlay before the system dialog appears
            try? await Task.sleep(nanoseconds: 300_000_000)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.general("Setup: microphone granted=\(granted)")
            if granted {
                await MainActor.run {
                    self.overlay.showMessage("Microphone enabled")
                    self.overlay.hide(after: 1.0)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            } else {
                await MainActor.run {
                    self.overlay.showMessage("Microphone denied")
                    self.overlay.hide(after: 2.0)
                }
            }
        }

        // Step 3: Download speech models (v2 + v3 in parallel)
        await MainActor.run {
            self.overlay.showProgress("Downloading speech models\u{2026}")
        }
        do {
            try await transcriber.downloadAll()
        } catch {
            Log.general("Setup: ASR model download failed: \(error.localizedDescription)")
            await MainActor.run {
                self.overlay.showMessage("Speech model download failed")
                self.overlay.hide(after: 2.0)
            }
            return
        }

        // Step 4: Load the selected speech model into memory
        await MainActor.run {
            self.overlay.showProgress("Loading speech model\u{2026}")
        }
        do {
            try await transcriber.prepare()
            Log.general("Setup: ASR models ready")
        } catch {
            Log.general("Setup: ASR model load failed: \(error.localizedDescription)")
            await MainActor.run {
                self.overlay.showMessage("Speech model load failed")
                self.overlay.hide(after: 2.0)
            }
            return
        }

        // Step 5: Download and load the cleanup LLM
        await MainActor.run {
            self.overlay.showProgress("Downloading cleanup model\u{2026}")
        }
        do {
            try await cleanupEngine.prepare { [weak self] (progress: Progress) in
                let pct = Int(progress.fractionCompleted * 100)
                Task { @MainActor in
                    self?.overlay.showProgress("Downloading cleanup model\u{2026} \(pct)%")
                }
            }
            Log.general("Setup: cleanup model ready")
        } catch {
            Log.general("Setup: cleanup model failed: \(error.localizedDescription)")
        }

        await MainActor.run {
            self.overlay.showMessage("Ready")
            self.overlay.hide(after: 1.5)
        }
    }

    func hotKeyPressed(kind: HotKeyKind) {
        pendingFinish?.cancel()
        pendingFinish = nil
        if isListening {
            if listeningMode == .toggle, kind == .toggle {
                Log.general("Toggle hotkey pressed: stop listening")
                finishListening(reason: "toggle")
            }
            return
        }

        switch kind {
        case .pushToTalk:
            startListening(mode: .pushToTalk)
        case .toggle:
            startListening(mode: .toggle)
        }
    }

    func hotKeyReleased(kind: HotKeyKind) {
        guard isListening, listeningMode == .pushToTalk, kind == .pushToTalk else { return }
        Log.general("Push-to-talk released: stop listening")
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishListening(reason: "push-release")
        }
        pendingFinish = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func startListening(mode: ListeningMode) {
        if !AXIsProcessTrusted() {
            Log.general("Start listening: accessibility not trusted, prompting")
            let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            overlay.showMessage("Accessibility required")
            overlay.hide(after: 3.0)
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.general("Start listening (\(mode)) mic status=\(status.rawValue)")
        switch status {
        case .authorized:
            beginListening(mode: mode)
        case .notDetermined:
            requestMicrophoneAndBegin(mode: mode)
        default:
            overlay.showMessage("Enable Microphone (LW menu)")
            overlay.hide(after: 1.2)
        }
    }

    private func beginListening(mode: ListeningMode) {
        guard !isListening else { return }
        captureFocusedWindowBounds()
        isListening = true
        listeningMode = mode
        if mode == .toggle {
            let now = CACurrentMediaTime()
            lastSpeechTime = now
            toggleStartTime = now
            let toggleKey = Preferences.shared.toggleHotKey.displayString
            overlay.showListening(hint: "\(toggleKey) stop · Esc cancel")
            installEscapeMonitor()
        } else {
            overlay.showListening(hint: "Release to type")
        }
        let started = audio.start()
        if !started {
            isListening = false
            listeningMode = nil
            removeEscapeMonitor()
            overlay.showMessage("Microphone unavailable")
            overlay.hide(after: 1.2)
            return
        }
        playFeedback(start: true)
    }

    private func requestMicrophoneAndBegin(mode: ListeningMode) {
        NSApp.activate(ignoringOtherApps: true)
        overlay.showMessage("Allow microphone access")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    Log.general("Microphone access granted=\(granted)")
                    if granted {
                        self.beginListening(mode: mode)
                    } else {
                        self.overlay.showMessage("Mic access denied")
                        self.overlay.hide(after: 1.2)
                    }
                }
            }
        }
    }

    private func handleAudioLevel(_ level: Float) {
        guard isListening, listeningMode == .toggle else { return }
        let now = CACurrentMediaTime()
        if level > silenceThreshold {
            lastSpeechTime = now
        }
        if let lastSpeechTime, now - lastSpeechTime >= toggleSilenceTimeout {
            Log.general("Toggle stop: silence timeout")
            finishListening(reason: "silence")
            return
        }
        if let toggleStartTime, now - toggleStartTime >= toggleMaxDuration {
            Log.general("Toggle stop: max duration")
            finishListening(reason: "max-duration")
        }
    }

    private func finishListening(reason: String) {
        guard isListening else { return }
        isListening = false
        listeningMode = nil
        lastSpeechTime = nil
        toggleStartTime = nil
        removeEscapeMonitor()

        let samples = audio.stop()
        playFeedback(start: false)
        Log.general("Finish listening (\(reason)): captured \(samples.count) samples")
        if samples.isEmpty {
            overlay.showMessage("No speech detected")
            overlay.hide(after: 0.8)
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            let ready = await self.transcriber.isReady()
            await MainActor.run {
                self.overlay.showTranscribing(loading: !ready)
            }

            do {
                let transcript = try await self.transcriber.transcribe(samples: samples)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                let preview = String(trimmed.prefix(160))
                Log.transcription("Transcript length=\(trimmed.count) preview=\"\(preview)\"")
                if trimmed.isEmpty {
                    await MainActor.run {
                        self.overlay.showMessage("No speech detected")
                        self.overlay.hide(after: 0.8)
                    }
                    return
                }

                let textToType: String
                let cleanupEnabled = await MainActor.run { Preferences.shared.llmCleanupEnabled }
                if cleanupEnabled {
                    let ready = await self.cleanupEngine.isReady()
                    await MainActor.run { self.overlay.showCleaningUp(loading: !ready) }
                    do {
                        textToType = try await self.cleanupEngine.cleanUp(text: trimmed)
                        Log.cleanup("Cleanup result length=\(textToType.count)")
                    } catch {
                        Log.cleanup("Cleanup failed, using raw: \(error.localizedDescription)")
                        textToType = trimmed
                    }
                } else {
                    textToType = trimmed
                }

                await MainActor.run {
                    if cleanupEnabled, textToType != trimmed {
                        TranscriptionHistory.shared.append(textToType, originalText: trimmed)
                    } else {
                        TranscriptionHistory.shared.append(textToType)
                    }
                }
                let trusted = self.typer.isTrusted()
                Log.general("Accessibility trusted=\(trusted)")
                if !trusted {
                    await MainActor.run {
                        Log.general("Accessibility lost mid-pipeline, prompting")
                        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                        self.overlay.showMessage("Accessibility required")
                        self.overlay.hide(after: 3.0)
                    }
                    return
                }

                await MainActor.run {
                    self.overlay.showTyping()
                }
                await self.restoreFocusForTyping()

                let (delayMs, method) = await MainActor.run {
                    (Preferences.shared.typingDelayMs, self.effectiveTypingMethod())
                }
                Log.typing("Typing with method=\(method) delay=\(delayMs)ms")
                await MainActor.run { self.installTypingEscapeMonitor() }
                let success = await self.typer.typeTextAsync(textToType, method: method, delayMs: delayMs)
                await MainActor.run { self.removeTypingEscapeMonitor() }
                let wasCancelled = self.typer.isCancelled
                Log.typing("Typing posted=\(success) cancelled=\(wasCancelled)")
                if wasCancelled {
                    await MainActor.run {
                        self.overlay.showMessage("Cancelled")
                        self.overlay.hide(after: 0.6)
                    }
                } else if !success {
                    await MainActor.run {
                        self.overlay.showMessage("Typing failed")
                        self.overlay.hide(after: 1.2)
                    }
                } else {
                    let autoEnter = await MainActor.run { Preferences.shared.autoEnterEnabled }
                    if autoEnter {
                        usleep(200_000)
                        let entered = self.typer.sendReturn()
                        Log.typing("Auto-enter posted=\(entered)")
                    }
                }
            } catch {
                Log.transcription("Transcription failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.overlay.showMessage("Transcription failed")
                    self.overlay.hide(after: 1.2)
                }
            }
        }
    }

    private func cancelListening() {
        guard isListening else { return }
        Log.general("Listening cancelled (Escape)")
        isListening = false
        listeningMode = nil
        lastSpeechTime = nil
        toggleStartTime = nil
        removeEscapeMonitor()

        _ = audio.stop()
        playFeedback(start: false)
        overlay.showMessage("Cancelled")
        overlay.hide(after: 0.6)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.cancelListening()
                }
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func installTypingEscapeMonitor() {
        removeTypingEscapeMonitor()
        typingEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.typer.cancelTyping()
            }
        }
    }

    private func removeTypingEscapeMonitor() {
        if let monitor = typingEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            typingEscapeMonitor = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(named: "menubar_icon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.title = "LW"
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "LagunaWave \(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu(title: "Microphone")
        micSubmenu.delegate = self
        micItem.submenu = micSubmenu
        menu.addItem(micItem)
        micMenuItem = micItem

        let cleanupItem = NSMenuItem(title: "Clean Up Text with AI", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = Preferences.shared.llmCleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)
        cleanupMenuItem = cleanupItem

        let enterItem = NSMenuItem(title: "Send Enter After Typing", action: #selector(toggleAutoEnter), keyEquivalent: "")
        enterItem.target = self
        enterItem.state = Preferences.shared.autoEnterEnabled ? .on : .off
        menu.addItem(enterItem)
        autoEnterMenuItem = enterItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Transcription History…", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About LagunaWave", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit LagunaWave", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleCleanup() {
        let newValue = !Preferences.shared.llmCleanupEnabled
        Preferences.shared.llmCleanupEnabled = newValue
        cleanupMenuItem?.state = newValue ? .on : .off
    }

    @objc private func toggleAutoEnter() {
        let newValue = !Preferences.shared.autoEnterEnabled
        Preferences.shared.autoEnterEnabled = newValue
        autoEnterMenuItem?.state = newValue ? .on : .off
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        Preferences.shared.inputDeviceUID = uid
        NotificationCenter.default.post(name: .inputDeviceChanged, object: uid)
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    private func rebuildMicSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = AudioDeviceManager.listInputDevices()
        let selectedUID = Preferences.shared.inputDeviceUID
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == selectedUID) ? .on : .off
            menu.addItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == micMenuItem?.submenu {
            rebuildMicSubmenu(menu)
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindowController()
        }
        historyWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleRetypeTranscription(_ note: Notification) {
        guard let text = note.object as? String, !text.isEmpty else { return }
        beginRetypeFlow(text)
    }

    @objc private func handleModelChanged() {
        overlay.showMessage("Switching model…")
        Task {
            do {
                try await transcriber.reloadModel()
                await MainActor.run {
                    self.overlay.showMessage("Model loaded")
                    self.overlay.hide(after: 1.0)
                }
            } catch {
                Log.general("Model switch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.overlay.showMessage("Model switch failed")
                    self.overlay.hide(after: 1.5)
                }
            }
        }
    }

    @objc private func handleLLMCleanupModelChanged() {
        Task {
            await MainActor.run {
                self.overlay.showProgress("Downloading cleanup model\u{2026}")
            }
            do {
                try await cleanupEngine.reloadModel { [weak self] (progress: Progress) in
                    let pct = Int(progress.fractionCompleted * 100)
                    Task { @MainActor in
                        self?.overlay.showProgress("Downloading cleanup model\u{2026} \(pct)%")
                    }
                }
                await MainActor.run {
                    self.overlay.showMessage("Cleanup model ready")
                    self.overlay.hide(after: 1.5)
                }
            } catch {
                Log.general("Cleanup model switch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.overlay.showMessage("Cleanup model download failed")
                    self.overlay.hide(after: 2.0)
                }
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pushHotKeyChanged(_ note: Notification) {
        guard let hotKey = note.object as? HotKey else { return }
        hotKeyManager?.updateHotKey(kind: .pushToTalk, hotKey: hotKey)
    }

    @objc private func toggleHotKeyChanged(_ note: Notification) {
        guard let hotKey = note.object as? HotKey else { return }
        hotKeyManager?.updateHotKey(kind: .toggle, hotKey: hotKey)
    }

    private func playFeedback(start: Bool) {
        if Preferences.shared.hapticCueEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guard Preferences.shared.audioCueEnabled else { return }
        let soundName = start ? "Tink" : "Pop"
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.volume = 0.2
            sound.play()
        }
    }

    @objc private func inputDeviceChanged(_ note: Notification) {
        let uid = note.object as? String
        audio.setInputDevice(uid: uid)
    }

    @objc private func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
        lastExternalBundleID = app.bundleIdentifier
        lastExternalPID = app.processIdentifier
    }

    private func beginRetypeFlow(_ text: String) {
        overlay.showMessage("Click where you want to type · Esc cancel")
        removeRetypeMonitors()

        retypeEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.cancelRetypeFlow()
                }
            }
        }

        retypeClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.completeRetypeFlow(text)
            }
        }
    }

    private func completeRetypeFlow(_ text: String) {
        removeRetypeMonitors()
        overlay.hide()
        Log.typing("Retype: click detected, typing \(text.count) chars")

        Task { [weak self] in
            guard let self = self else { return }
            // Brief pause for the clicked window to settle focus
            try? await Task.sleep(nanoseconds: 200_000_000)
            let (delayMs, method) = await MainActor.run {
                (Preferences.shared.typingDelayMs, self.effectiveTypingMethod())
            }
            await MainActor.run { self.installTypingEscapeMonitor() }
            let success = await self.typer.typeTextAsync(text, method: method, delayMs: delayMs)
            await MainActor.run { self.removeTypingEscapeMonitor() }
            let wasCancelled = self.typer.isCancelled
            Log.typing("Retype: typing posted=\(success) cancelled=\(wasCancelled)")
            if wasCancelled {
                await MainActor.run {
                    self.overlay.showMessage("Cancelled")
                    self.overlay.hide(after: 0.6)
                }
            }
        }
    }

    private func cancelRetypeFlow() {
        removeRetypeMonitors()
        overlay.showMessage("Cancelled")
        overlay.hide(after: 0.6)
    }

    private func removeRetypeMonitors() {
        if let m = retypeClickMonitor { NSEvent.removeMonitor(m); retypeClickMonitor = nil }
        if let m = retypeEscapeMonitor { NSEvent.removeMonitor(m); retypeEscapeMonitor = nil }
    }

    /// Returns the typing method to use. For VDI apps, forces
    /// simulateKeypresses regardless of the user's setting.
    private func effectiveTypingMethod() -> TypingMethod {
        let userMethod = Preferences.shared.typingMethod
        guard let target = resolveLastExternalApp() else { return userMethod }
        let isVDI = Preferences.shared.isVDIApp(bundleID: target.bundleIdentifier, name: target.localizedName)
        if isVDI && userMethod == .simulateTyping {
            Log.typing("VDI detected: overriding simulateTyping → simulateKeypresses")
            return .simulateKeypresses
        }
        return userMethod
    }

    private func resolveLastExternalApp() -> NSRunningApplication? {
        if let app = lastExternalApp, !app.isTerminated { return app }
        if let pid = lastExternalPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            return app
        }
        if let bundleID = lastExternalBundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return nil
    }

    /// Captures the focused window's bounds (via Accessibility API) before
    /// the overlay appears. Called at the start of listening so we know
    /// exactly which window to click back into after typing.
    private func captureFocusedWindowBounds() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            Log.general("Focus capture: no frontmost app")
            savedFocusWindowBounds = nil
            return
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "?"
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else {
            Log.general("Focus capture: no focused window for \(appName) (AX result=\(result.rawValue))")
            savedFocusWindowBounds = nil
            return
        }

        // CFTypeRef downcasts always succeed at the Swift bridging level,
        // so we use unconditional casts here and rely on return-value checks.
        let axWindow = window as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)

        var position = CGPoint.zero
        var size = CGSize.zero
        if posResult == .success, let pv = positionValue { AXValueGetValue(pv as! AXValue, .cgPoint, &position) }
        if sizeResult == .success, let sv = sizeValue { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

        let bounds = CGRect(origin: position, size: size)
        savedFocusWindowBounds = bounds
        Log.general("Focus capture: \(appName) focused window \(Int(size.width))x\(Int(size.height)) at (\(Int(position.x)),\(Int(position.y)))")
    }

    /// Hides the overlay and restores focus to the target app.
    /// For VDI apps (auto-detected), clicks at the center of the saved
    /// focused window to re-establish keyboard grab. For regular apps,
    /// just activates without clicking (clicking would move the cursor).
    private func restoreFocusForTyping() async {
        await MainActor.run { self.overlay.hide() }

        guard let target = await MainActor.run(body: { self.resolveLastExternalApp() }) else {
            Log.general("Focus restore: no target app to activate")
            return
        }
        let targetName = target.localizedName ?? "?"
        let targetBundle = target.bundleIdentifier

        let isVDI = await MainActor.run {
            Preferences.shared.isVDIApp(bundleID: targetBundle, name: targetName)
        }
        Log.general("Focus restore: target=\(targetName) bundle=\(targetBundle ?? "nil") isVDI=\(isVDI)")

        // Step 1: Make target frontmost
        _ = await MainActor.run { target.activate() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Step 2: For VDI apps, click at center of saved focused window
        // to re-establish keyboard grab. Skip for regular apps.
        guard isVDI else {
            Log.general("Focus restore: not VDI, activate only")
            return
        }

        guard let bounds = await MainActor.run(body: { self.savedFocusWindowBounds }),
              bounds.width > 0, bounds.height > 0 else {
            Log.general("Focus restore: VDI but no saved window bounds, skipping click")
            try? await Task.sleep(nanoseconds: 150_000_000)
            return
        }

        let clickPoint = CGPoint(x: bounds.minX + bounds.width * 0.8, y: bounds.minY + 12)
        Log.general("Focus restore: VDI click at (\(Int(clickPoint.x)),\(Int(clickPoint.y))) size \(Int(bounds.width))x\(Int(bounds.height))")

        if let mouseMove = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: clickPoint, mouseButton: .left) {
            mouseMove.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        Log.general("Focus restore: VDI click sent")
    }
}
