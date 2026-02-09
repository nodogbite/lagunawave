import AppKit

@MainActor
final class SettingsViewController: NSTabViewController {
    private let devicesPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pushHotKeyRecorder = HotKeyRecorderView(frame: .zero)
    private let toggleHotKeyRecorder = HotKeyRecorderView(frame: .zero)
    private let pushDescriptionLabel = NSTextField(labelWithString: "Hold to speak, release to type.")
    private let toggleDescriptionLabel = NSTextField(labelWithString: "Press once to start, press again to stop.")
    private let typingMethodLabel = NSTextField(labelWithString: "Typing method")
    private let typingMethodPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typingMethodDescription = NSTextField(wrappingLabelWithString: "")
    private let typingSpeedLabel = NSTextField(labelWithString: "Typing speed")
    private let typingSpeedControl = NSSegmentedControl()
    private let speedLabels = ["Instant", "Fast", "Natural", "Relaxed"]
    private let speedValues = [0, 15, 35, 65]
    private let vdiPatternsLabel = NSTextField(labelWithString: "VDI app keywords")
    private let vdiPatternsField = NSTextField()
    private let vdiPatternsDescription = NSTextField(wrappingLabelWithString: "Comma-separated. Apps matching these get a click to restore keyboard capture.")
    private let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelDescription = NSTextField(wrappingLabelWithString: "")
    private let audioCueToggle = NSButton(checkboxWithTitle: "Play sound when listening starts/stops", target: nil, action: nil)
    private let hapticCueToggle = NSButton(checkboxWithTitle: "Haptic feedback on start/stop", target: nil, action: nil)
    private let cleanupToggle = NSButton(checkboxWithTitle: "Clean up dictated text with AI", target: nil, action: nil)
    private let cleanupModelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupDescription = NSTextField(wrappingLabelWithString: "Fixes punctuation, capitalization, filler words, and homophones. Runs locally on-device.")
    private let autoEnterToggle = NSButton(checkboxWithTitle: "Send Enter key after typing", target: nil, action: nil)
    private let autoEnterDescription = NSTextField(wrappingLabelWithString: "Automatically presses Return after dictated text is typed.")
    private var devices: [AudioInputDevice] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        configureControls()

        addTab(label: "General", image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil), view: makeGeneralView())
        addTab(label: "Typing", image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil), view: makeTypingView())
        addTab(label: "Models", image: NSImage(systemSymbolName: "cpu", accessibilityDescription: nil), view: makeModelsView())
        addTab(label: "Troubleshooting", image: NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil), view: makeTroubleshootingView())

        loadPreferences()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.makeFirstResponder(nil)
    }

    private func addTab(label: String, image: NSImage?, view: NSView) {
        let vc = NSViewController()
        vc.view = view
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        item.image = image
        addTabViewItem(item)
    }

    // MARK: - Tab Content Views

    private func makeGeneralView() -> NSView {
        let micLabel = NSTextField(labelWithString: "Microphone")
        micLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let hotkeyLabel = NSTextField(labelWithString: "Hotkeys")
        hotkeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let pushLabel = NSTextField(labelWithString: "Push-to-talk")
        pushLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pushDescriptionLabel.textColor = .secondaryLabelColor

        let toggleLabel = NSTextField(labelWithString: "Toggle dictation")
        toggleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        toggleDescriptionLabel.textColor = .secondaryLabelColor

        let feedbackLabel = NSTextField(labelWithString: "Feedback")
        feedbackLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let restoreButton = NSButton(title: "Restore Defaults\u{2026}", target: self, action: #selector(restoreDefaults))
        restoreButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            micLabel,
            devicesPopUp,
            spacer(height: 16),
            hotkeyLabel,
            pushLabel,
            pushHotKeyRecorder,
            pushDescriptionLabel,
            spacer(height: 12),
            toggleLabel,
            toggleHotKeyRecorder,
            toggleDescriptionLabel,
            spacer(height: 16),
            feedbackLabel,
            audioCueToggle,
            hapticCueToggle,
            spacer(height: 16),
            restoreButton
        ])
        configureStack(stack)
        return wrapStack(stack)
    }

    private func makeTypingView() -> NSView {
        typingMethodLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        typingMethodDescription.font = NSFont.systemFont(ofSize: 11)
        typingMethodDescription.textColor = .secondaryLabelColor
        typingMethodDescription.maximumNumberOfLines = 2
        typingMethodDescription.lineBreakMode = .byWordWrapping

        typingSpeedLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        vdiPatternsLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        vdiPatternsDescription.font = NSFont.systemFont(ofSize: 11)
        vdiPatternsDescription.textColor = .secondaryLabelColor
        vdiPatternsDescription.maximumNumberOfLines = 2
        vdiPatternsDescription.lineBreakMode = .byWordWrapping

        autoEnterDescription.font = NSFont.systemFont(ofSize: 11)
        autoEnterDescription.textColor = .secondaryLabelColor
        autoEnterDescription.maximumNumberOfLines = 2
        autoEnterDescription.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [
            typingMethodLabel,
            typingMethodPopUp,
            typingMethodDescription,
            spacer(height: 16),
            typingSpeedLabel,
            typingSpeedControl,
            spacer(height: 16),
            autoEnterToggle,
            autoEnterDescription,
            spacer(height: 16),
            vdiPatternsLabel,
            vdiPatternsField,
            vdiPatternsDescription
        ])
        configureStack(stack)

        NSLayoutConstraint.activate([
            vdiPatternsField.widthAnchor.constraint(equalToConstant: 340)
        ])

        return wrapStack(stack)
    }

    private func makeModelsView() -> NSView {
        let privacyNote = NSTextField(wrappingLabelWithString: "All models run on-device. No data leaves your Mac.")
        privacyNote.font = NSFont.systemFont(ofSize: 11)
        privacyNote.textColor = .secondaryLabelColor

        let modelLabel = NSTextField(labelWithString: "Speech-to-text")
        modelLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        modelDescription.font = NSFont.systemFont(ofSize: 11)
        modelDescription.textColor = .secondaryLabelColor
        modelDescription.maximumNumberOfLines = 2
        modelDescription.lineBreakMode = .byWordWrapping

        let cleanupLabel = NSTextField(labelWithString: "Text cleanup")
        cleanupLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        cleanupDescription.font = NSFont.systemFont(ofSize: 11)
        cleanupDescription.textColor = .secondaryLabelColor
        cleanupDescription.maximumNumberOfLines = 3
        cleanupDescription.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [
            privacyNote,
            spacer(height: 12),
            modelLabel,
            modelPopUp,
            modelDescription,
            spacer(height: 20),
            cleanupLabel,
            cleanupToggle,
            cleanupModelPopUp,
            cleanupDescription,
        ])
        configureStack(stack)

        return wrapStack(stack)
    }

    private func makeTroubleshootingView() -> NSView {
        let accessibilityButton = NSButton(title: "Accessibility Settings\u{2026}", target: self, action: #selector(openAccessibilitySettings))
        accessibilityButton.bezelStyle = .rounded
        let microphoneButton = NSButton(title: "Microphone Settings\u{2026}", target: self, action: #selector(openMicrophoneSettings))
        microphoneButton.bezelStyle = .rounded
        let logButton = NSButton(title: "Open Log File", target: self, action: #selector(openLogFile))
        logButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            accessibilityButton,
            microphoneButton,
            logButton
        ])
        configureStack(stack)
        return wrapStack(stack)
    }

    // MARK: - Layout Helpers

    private func configureStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func wrapStack(_ stack: NSStackView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])
        return container
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: - Configure Controls

    private func configureControls() {
        devicesPopUp.translatesAutoresizingMaskIntoConstraints = false
        devicesPopUp.target = self
        devicesPopUp.action = #selector(deviceChanged)

        modelPopUp.translatesAutoresizingMaskIntoConstraints = false
        modelPopUp.addItems(withTitles: [
            "Parakeet TDT v2 (English)",
            "Parakeet TDT v3 (Multilingual)",
        ])
        modelPopUp.target = self
        modelPopUp.action = #selector(modelChanged)

        typingMethodPopUp.translatesAutoresizingMaskIntoConstraints = false
        typingMethodPopUp.addItems(withTitles: [
            "Simulate Typing",
            "Simulate Keypresses",
            "Paste",
        ])
        typingMethodPopUp.target = self
        typingMethodPopUp.action = #selector(typingMethodChanged)

        typingSpeedControl.segmentCount = speedLabels.count
        for (i, label) in speedLabels.enumerated() {
            typingSpeedControl.setLabel(label, forSegment: i)
            typingSpeedControl.setWidth(80, forSegment: i)
        }
        typingSpeedControl.target = self
        typingSpeedControl.action = #selector(typingSpeedChanged)

        vdiPatternsField.translatesAutoresizingMaskIntoConstraints = false
        vdiPatternsField.placeholderString = Preferences.defaultVDIPatterns
        vdiPatternsField.target = self
        vdiPatternsField.action = #selector(vdiPatternsChanged)

        audioCueToggle.target = self
        audioCueToggle.action = #selector(audioCueChanged)
        hapticCueToggle.target = self
        hapticCueToggle.action = #selector(hapticCueChanged)

        autoEnterToggle.target = self
        autoEnterToggle.action = #selector(autoEnterChanged)

        cleanupToggle.target = self
        cleanupToggle.action = #selector(cleanupToggleChanged)

        cleanupModelPopUp.translatesAutoresizingMaskIntoConstraints = false
        cleanupModelPopUp.addItems(withTitles: [
            "Standard (Qwen3 4B, ~2.5 GB)",
            "Lightweight (Qwen3 1.7B, ~1.3 GB)",
            "Enhanced (Qwen3 30B MoE, ~18 GB)",
        ])
        cleanupModelPopUp.target = self
        cleanupModelPopUp.action = #selector(cleanupModelChanged)

    }

    // MARK: - Load Preferences

    private func loadPreferences() {
        reloadDevices()

        pushHotKeyRecorder.onHotKeyChange = { hotKey in
            Preferences.shared.pushToTalkHotKey = hotKey
            NotificationCenter.default.post(name: .pushHotKeyChanged, object: hotKey)
        }
        pushHotKeyRecorder.setHotKey(Preferences.shared.pushToTalkHotKey)

        toggleHotKeyRecorder.onHotKeyChange = { hotKey in
            Preferences.shared.toggleHotKey = hotKey
            NotificationCenter.default.post(name: .toggleHotKeyChanged, object: hotKey)
        }
        toggleHotKeyRecorder.setHotKey(Preferences.shared.toggleHotKey)

        modelPopUp.selectItem(at: Preferences.shared.asrModelVersion == "v3" ? 1 : 0)
        updateModelDescription()

        audioCueToggle.state = Preferences.shared.audioCueEnabled ? .on : .off
        hapticCueToggle.state = Preferences.shared.hapticCueEnabled ? .on : .off
        typingMethodPopUp.selectItem(at: Preferences.shared.typingMethod.rawValue)
        updateTypingMethodDescription()
        updateTypingSpeedEnabled()

        let savedDelay = Preferences.shared.typingDelayMs
        typingSpeedControl.selectedSegment = speedValues.enumerated()
            .min(by: { abs($0.element - savedDelay) < abs($1.element - savedDelay) })?.offset ?? 2

        autoEnterToggle.state = Preferences.shared.autoEnterEnabled ? .on : .off

        vdiPatternsField.stringValue = Preferences.shared.vdiPatterns

        cleanupToggle.state = Preferences.shared.llmCleanupEnabled ? .on : .off
        switch Preferences.shared.llmCleanupModel {
        case "lightweight": cleanupModelPopUp.selectItem(at: 1)
        case "enhanced": cleanupModelPopUp.selectItem(at: 2)
        default: cleanupModelPopUp.selectItem(at: 0)
        }
        cleanupModelPopUp.isEnabled = cleanupToggle.state == .on
    }

    private func reloadDevices() {
        devices = AudioDeviceManager.listInputDevices()
        devicesPopUp.removeAllItems()
        devices.forEach { devicesPopUp.addItem(withTitle: $0.name) }

        if let saved = Preferences.shared.inputDeviceUID,
           let index = devices.firstIndex(where: { $0.uid == saved }) {
            devicesPopUp.selectItem(at: index)
        } else {
            devicesPopUp.selectItem(at: 0)
        }
    }

    // MARK: - Actions

    @objc private func deviceChanged() {
        let index = devicesPopUp.indexOfSelectedItem
        guard devices.indices.contains(index) else { return }
        let selected = devices[index]
        Preferences.shared.inputDeviceUID = selected.uid
        NotificationCenter.default.post(name: .inputDeviceChanged, object: selected.uid)
    }

    @objc private func audioCueChanged() {
        Preferences.shared.audioCueEnabled = (audioCueToggle.state == .on)
    }

    @objc private func hapticCueChanged() {
        Preferences.shared.hapticCueEnabled = (hapticCueToggle.state == .on)
    }

    @objc private func modelChanged() {
        let version = modelPopUp.indexOfSelectedItem == 1 ? "v3" : "v2"
        Preferences.shared.asrModelVersion = version
        updateModelDescription()
        NotificationCenter.default.post(name: .modelChanged, object: nil)
    }

    private func updateModelDescription() {
        switch Preferences.shared.asrModelVersion {
        case "v3":
            modelDescription.stringValue = "Supports 25 languages. Slightly lower English accuracy."
        default:
            modelDescription.stringValue = "Optimized for English. Higher accuracy for English-only use."
        }
    }

    @objc private func typingMethodChanged() {
        let index = typingMethodPopUp.indexOfSelectedItem
        guard let method = TypingMethod(rawValue: index) else { return }
        Preferences.shared.typingMethod = method
        updateTypingMethodDescription()
        updateTypingSpeedEnabled()
    }

    @objc private func typingSpeedChanged() {
        let index = typingSpeedControl.selectedSegment
        guard speedValues.indices.contains(index) else { return }
        Preferences.shared.typingDelayMs = speedValues[index]
    }

    @objc private func vdiPatternsChanged() {
        Preferences.shared.vdiPatterns = vdiPatternsField.stringValue
    }

    private func updateTypingMethodDescription() {
        switch Preferences.shared.typingMethod {
        case .simulateTyping:
            typingMethodDescription.stringValue = "Types characters via Unicode. Works in most macOS apps."
        case .simulateKeypresses:
            typingMethodDescription.stringValue = "Types via key codes (US QWERTY). Works in VDI and remote desktops."
        case .paste:
            typingMethodDescription.stringValue = "Pastes via clipboard (Cmd+V). Fastest option. Clipboard is restored afterward."
        }
    }

    private func updateTypingSpeedEnabled() {
        let method = Preferences.shared.typingMethod
        let relevant = method != .paste
        typingSpeedControl.isEnabled = relevant
        typingSpeedLabel.textColor = relevant ? .labelColor : .tertiaryLabelColor
    }

    @objc private func autoEnterChanged() {
        Preferences.shared.autoEnterEnabled = (autoEnterToggle.state == .on)
    }

    @objc private func cleanupToggleChanged() {
        Preferences.shared.llmCleanupEnabled = (cleanupToggle.state == .on)
        cleanupModelPopUp.isEnabled = cleanupToggle.state == .on
    }

    @objc private func cleanupModelChanged() {
        let model: String
        switch cleanupModelPopUp.indexOfSelectedItem {
        case 1: model = "lightweight"
        case 2: model = "enhanced"
        default: model = "standard"
        }
        Preferences.shared.llmCleanupModel = model
        NotificationCenter.default.post(name: .llmCleanupModelChanged, object: nil)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(FileLog.shared.currentFileURL)
    }

    @objc private func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore Default Settings?"
        alert.informativeText = "This will reset all settings to their defaults. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Preferences.shared.restoreDefaults()
            self?.loadPreferences()
            NotificationCenter.default.post(name: .pushHotKeyChanged, object: Preferences.shared.pushToTalkHotKey)
            NotificationCenter.default.post(name: .toggleHotKeyChanged, object: Preferences.shared.toggleHotKey)
            NotificationCenter.default.post(name: .modelChanged, object: nil)
            NotificationCenter.default.post(name: .inputDeviceChanged, object: nil)
            NotificationCenter.default.post(name: .llmCleanupModelChanged, object: nil)
        }
    }
}
