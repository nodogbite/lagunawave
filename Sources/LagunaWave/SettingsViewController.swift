import AppKit

@MainActor
final class SettingsViewController: NSViewController {
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
    private var devices: [AudioInputDevice] = []

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Settings")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let micLabel = NSTextField(labelWithString: "Microphone")
        micLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        devicesPopUp.translatesAutoresizingMaskIntoConstraints = false
        devicesPopUp.target = self
        devicesPopUp.action = #selector(deviceChanged)

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        modelPopUp.translatesAutoresizingMaskIntoConstraints = false
        modelPopUp.addItems(withTitles: [
            "Parakeet TDT v2 (English)",
            "Parakeet TDT v3 (Multilingual)",
        ])
        modelPopUp.target = self
        modelPopUp.action = #selector(modelChanged)
        modelDescription.font = NSFont.systemFont(ofSize: 11)
        modelDescription.textColor = .secondaryLabelColor
        modelDescription.maximumNumberOfLines = 2
        modelDescription.lineBreakMode = .byWordWrapping

        let hotkeyLabel = NSTextField(labelWithString: "Hotkeys")
        hotkeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let pushLabel = NSTextField(labelWithString: "Push-to-talk")
        pushLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pushDescriptionLabel.textColor = .secondaryLabelColor

        let toggleLabel = NSTextField(labelWithString: "Toggle dictation")
        toggleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        toggleDescriptionLabel.textColor = .secondaryLabelColor

        typingMethodLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        typingMethodPopUp.translatesAutoresizingMaskIntoConstraints = false
        typingMethodPopUp.addItems(withTitles: [
            "Simulate Typing",
            "Simulate Keypresses",
            "Paste",
        ])
        typingMethodPopUp.target = self
        typingMethodPopUp.action = #selector(typingMethodChanged)
        typingMethodDescription.font = NSFont.systemFont(ofSize: 11)
        typingMethodDescription.textColor = .secondaryLabelColor
        typingMethodDescription.maximumNumberOfLines = 2
        typingMethodDescription.lineBreakMode = .byWordWrapping

        typingSpeedLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        typingSpeedControl.segmentCount = speedLabels.count
        for (i, label) in speedLabels.enumerated() {
            typingSpeedControl.setLabel(label, forSegment: i)
            typingSpeedControl.setWidth(80, forSegment: i)
        }
        typingSpeedControl.target = self
        typingSpeedControl.action = #selector(typingSpeedChanged)

        vdiPatternsLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        vdiPatternsField.translatesAutoresizingMaskIntoConstraints = false
        vdiPatternsField.placeholderString = Preferences.defaultVDIPatterns
        vdiPatternsField.target = self
        vdiPatternsField.action = #selector(vdiPatternsChanged)
        vdiPatternsDescription.font = NSFont.systemFont(ofSize: 11)
        vdiPatternsDescription.textColor = .secondaryLabelColor
        vdiPatternsDescription.maximumNumberOfLines = 2
        vdiPatternsDescription.lineBreakMode = .byWordWrapping

        let feedbackLabel = NSTextField(labelWithString: "Feedback")
        feedbackLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        audioCueToggle.target = self
        audioCueToggle.action = #selector(audioCueChanged)
        hapticCueToggle.target = self
        hapticCueToggle.action = #selector(hapticCueChanged)
        let troubleshootingLabel = NSTextField(labelWithString: "Troubleshooting")
        troubleshootingLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let accessibilityButton = NSButton(title: "Accessibility Settings…", target: self, action: #selector(openAccessibilitySettings))
        accessibilityButton.bezelStyle = .rounded
        let microphoneButton = NSButton(title: "Microphone Settings…", target: self, action: #selector(openMicrophoneSettings))
        microphoneButton.bezelStyle = .rounded
        let logButton = NSButton(title: "Open Log File", target: self, action: #selector(openLogFile))
        logButton.bezelStyle = .rounded

        let troubleshootingButtons = NSStackView(views: [accessibilityButton, microphoneButton, logButton])
        troubleshootingButtons.orientation = .horizontal
        troubleshootingButtons.spacing = 8

        let stack = NSStackView(views: [
            title,
            spacer(height: 8),
            micLabel,
            devicesPopUp,
            spacer(height: 16),
            modelLabel,
            modelPopUp,
            modelDescription,
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
            typingMethodLabel,
            typingMethodPopUp,
            typingMethodDescription,
            spacer(height: 16),
            typingSpeedLabel,
            typingSpeedControl,
            spacer(height: 16),
            vdiPatternsLabel,
            vdiPatternsField,
            vdiPatternsDescription,
            spacer(height: 16),
            feedbackLabel,
            audioCueToggle,
            hapticCueToggle,
            spacer(height: 16),
            troubleshootingLabel,
            troubleshootingButtons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24)
        ])

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

        vdiPatternsField.stringValue = Preferences.shared.vdiPatterns
        NSLayoutConstraint.activate([
            vdiPatternsField.widthAnchor.constraint(equalToConstant: 340)
        ])
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
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

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(Log.shared.logURL)
    }
}
