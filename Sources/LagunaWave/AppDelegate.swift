import AppKit
import AVFoundation
import ApplicationServices
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, HotKeyDelegate {
    private enum ListeningMode {
        case pushToTalk
        case toggle
    }

    private let overlay = OverlayPanel()
    private let audio = AudioCapture()
    private let typer = TextTyper()
    private let transcriber = TranscriptionEngine()
    private var isListening = false
    private var listeningMode: ListeningMode?
    private var lastSpeechTime: CFTimeInterval?
    private var toggleStartTime: CFTimeInterval?
    private let silenceThreshold: Float = 0.08
    private let toggleSilenceTimeout: TimeInterval = 10
    private let toggleMaxDuration: TimeInterval = 120
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private var lastExternalApp: NSRunningApplication?
    private var lastExternalBundleID: String?
    private var lastExternalPID: pid_t?
    private var savedFocusWindowBounds: CGRect?
    private var escapeMonitor: Any?
    private var retypeClickMonitor: Any?
    private var retypeEscapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("Launched LagunaWave")
        Log.shared.write("Bundle path: \(Bundle.main.bundlePath)")

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
        Log.shared.write("Setup: accessibility trusted=\(trusted)")
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
            Log.shared.write("Setup: accessibility now trusted")
            await MainActor.run {
                self.overlay.showMessage("Accessibility enabled")
                self.overlay.hide(after: 1.0)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000) // let user see confirmation
        }

        // Step 2: Microphone permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.shared.write("Setup: microphone status=\(micStatus.rawValue)")
        if micStatus == .notDetermined {
            await MainActor.run {
                self.overlay.showMessage("Allow Microphone…")
            }
            // Brief pause so user sees the overlay before the system dialog appears
            try? await Task.sleep(nanoseconds: 300_000_000)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.shared.write("Setup: microphone granted=\(granted)")
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

        // Step 3: Download both models, then load the selected one
        await MainActor.run {
            self.overlay.showTranscribing(loading: true)
        }
        do {
            try await transcriber.downloadAll()
            try await transcriber.prepare()
            Log.shared.write("Setup: models ready")
            await MainActor.run {
                self.overlay.showMessage("Ready")
                self.overlay.hide(after: 1.5)
            }
        } catch {
            Log.shared.write("Setup: model download failed: \(error.localizedDescription)")
            await MainActor.run {
                self.overlay.showMessage("Model download failed")
                self.overlay.hide(after: 2.0)
            }
        }
    }

    func hotKeyPressed(kind: HotKeyKind) {
        if isListening {
            if listeningMode == .toggle, kind == .toggle {
                Log.shared.write("Toggle hotkey pressed: stop listening")
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
        Log.shared.write("Push-to-talk released: stop listening")
        finishListening(reason: "push-release")
    }

    private func startListening(mode: ListeningMode) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.shared.write("Start listening (\(mode)) mic status=\(status.rawValue)")
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
                    Log.shared.write("Microphone access granted=\(granted)")
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
            Log.shared.write("Toggle stop: silence timeout")
            finishListening(reason: "silence")
            return
        }
        if let toggleStartTime, now - toggleStartTime >= toggleMaxDuration {
            Log.shared.write("Toggle stop: max duration")
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
        Log.shared.write("Finish listening (\(reason)): captured \(samples.count) samples")
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
                Log.shared.write("Transcript length=\(trimmed.count) preview=\"\(preview)\"")
                if trimmed.isEmpty {
                    await MainActor.run {
                        self.overlay.showMessage("No speech detected")
                        self.overlay.hide(after: 0.8)
                    }
                    return
                }
                await MainActor.run {
                    TranscriptionHistory.shared.append(trimmed)
                }
                let trusted = self.typer.isTrusted()
                Log.shared.write("Accessibility trusted=\(trusted)")
                if !trusted {
                    await MainActor.run {
                        self.overlay.showMessage("Enable Accessibility (LW menu)")
                        self.overlay.hide(after: 1.2)
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
                Log.shared.write("Typing with method=\(method) delay=\(delayMs)ms")
                let success = self.typer.typeText(trimmed, method: method, delayMs: delayMs)
                Log.shared.write("Typing posted=\(success)")
                if !success {
                    await MainActor.run {
                        self.overlay.showMessage("Typing failed")
                        self.overlay.hide(after: 1.2)
                    }
                }
            } catch {
                Log.shared.write("Transcription failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.overlay.showMessage("Transcription failed")
                    self.overlay.hide(after: 1.2)
                }
            }
        }
    }

    private func cancelListening() {
        guard isListening else { return }
        Log.shared.write("Listening cancelled (Escape)")
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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "LW"

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "LagunaWave \(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
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
                Log.shared.write("Model switch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.overlay.showMessage("Model switch failed")
                    self.overlay.hide(after: 1.5)
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
        Log.shared.write("Retype: click detected, typing \(text.count) chars")

        Task { [weak self] in
            guard let self = self else { return }
            // Brief pause for the clicked window to settle focus
            try? await Task.sleep(nanoseconds: 200_000_000)
            let (delayMs, method) = await MainActor.run {
                (Preferences.shared.typingDelayMs, self.effectiveTypingMethod())
            }
            let success = self.typer.typeText(text, method: method, delayMs: delayMs)
            Log.shared.write("Retype: typing posted=\(success)")
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
            Log.shared.write("VDI detected: overriding simulateTyping → simulateKeypresses")
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
            Log.shared.write("Focus capture: no frontmost app")
            savedFocusWindowBounds = nil
            return
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "?"
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else {
            Log.shared.write("Focus capture: no focused window for \(appName) (AX result=\(result.rawValue))")
            savedFocusWindowBounds = nil
            return
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue)

        var position = CGPoint.zero
        var size = CGSize.zero
        if let pv = positionValue { AXValueGetValue(pv as! AXValue, .cgPoint, &position) }
        if let sv = sizeValue { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

        let bounds = CGRect(origin: position, size: size)
        savedFocusWindowBounds = bounds
        Log.shared.write("Focus capture: \(appName) focused window \(Int(size.width))x\(Int(size.height)) at (\(Int(position.x)),\(Int(position.y)))")
    }

    /// Hides the overlay and restores focus to the target app.
    /// For VDI apps (auto-detected), clicks at the center of the saved
    /// focused window to re-establish keyboard grab. For regular apps,
    /// just activates without clicking (clicking would move the cursor).
    private func restoreFocusForTyping() async {
        await MainActor.run { self.overlay.hide() }

        guard let target = await MainActor.run(body: { self.resolveLastExternalApp() }) else {
            Log.shared.write("Focus restore: no target app to activate")
            return
        }
        let targetName = target.localizedName ?? "?"
        let targetBundle = target.bundleIdentifier

        let isVDI = await MainActor.run {
            Preferences.shared.isVDIApp(bundleID: targetBundle, name: targetName)
        }
        Log.shared.write("Focus restore: target=\(targetName) bundle=\(targetBundle ?? "nil") isVDI=\(isVDI)")

        // Step 1: Make target frontmost
        _ = await MainActor.run { target.activate() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Step 2: For VDI apps, click at center of saved focused window
        // to re-establish keyboard grab. Skip for regular apps.
        guard isVDI else {
            Log.shared.write("Focus restore: not VDI, activate only")
            return
        }

        guard let bounds = await MainActor.run(body: { self.savedFocusWindowBounds }),
              bounds.width > 0, bounds.height > 0 else {
            Log.shared.write("Focus restore: VDI but no saved window bounds, skipping click")
            try? await Task.sleep(nanoseconds: 150_000_000)
            return
        }

        let clickPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        Log.shared.write("Focus restore: VDI click at (\(Int(clickPoint.x)),\(Int(clickPoint.y))) size \(Int(bounds.width))x\(Int(bounds.height))")

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

        Log.shared.write("Focus restore: VDI click sent")
    }
}
