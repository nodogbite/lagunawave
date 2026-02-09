import Foundation

enum TypingMethod: Int {
    case simulateTyping = 0
    case simulateKeypresses = 1
    case paste = 2
}

@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let inputDeviceUID = "inputDeviceUID"
        static let pushHotKeyData = "pushHotKeyData"
        static let toggleHotKeyData = "toggleHotKeyData"
        static let legacyHotKeyData = "hotKeyData"
        static let audioCueEnabled = "audioCueEnabled"
        static let hapticCueEnabled = "hapticCueEnabled"
        static let typingDelayMs = "typingDelayMs"
        static let typingMethod = "typingMethod"
        static let vdiPatterns = "vdiPatterns"
        static let asrModelVersion = "asrModelVersion"
        static let llmCleanupEnabled = "llmCleanupEnabled"
        static let llmCleanupModel = "llmCleanupModel"
        static let autoEnterEnabled = "autoEnterEnabled"
    }

    static let defaultVDIPatterns = "vmware, horizon, citrix, omnissa, remote desktop, workspaces, parallels, xen"

    private init() {
        defaults.register(defaults: [
            Keys.audioCueEnabled: true,
            Keys.hapticCueEnabled: true,
            Keys.typingDelayMs: 15,
            Keys.typingMethod: TypingMethod.simulateTyping.rawValue,
            Keys.asrModelVersion: "v2",
            Keys.llmCleanupEnabled: true,
            Keys.llmCleanupModel: "standard",
            Keys.vdiPatterns: Self.defaultVDIPatterns,
        ])
        migrateLegacyHotKeyIfNeeded()
    }

    var inputDeviceUID: String? {
        get { defaults.string(forKey: Keys.inputDeviceUID) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Keys.inputDeviceUID)
            }
        }
    }

    var pushToTalkHotKey: HotKey {
        get { loadHotKey(for: Keys.pushHotKeyData, fallback: .defaultPush) }
        set { saveHotKey(newValue, key: Keys.pushHotKeyData) }
    }

    var toggleHotKey: HotKey {
        get { loadHotKey(for: Keys.toggleHotKeyData, fallback: .defaultToggle) }
        set { saveHotKey(newValue, key: Keys.toggleHotKeyData) }
    }

    var audioCueEnabled: Bool {
        get { defaults.bool(forKey: Keys.audioCueEnabled) }
        set { defaults.set(newValue, forKey: Keys.audioCueEnabled) }
    }

    var hapticCueEnabled: Bool {
        get { defaults.bool(forKey: Keys.hapticCueEnabled) }
        set { defaults.set(newValue, forKey: Keys.hapticCueEnabled) }
    }

    var typingDelayMs: Int {
        get { defaults.integer(forKey: Keys.typingDelayMs) }
        set { defaults.set(newValue, forKey: Keys.typingDelayMs) }
    }

    var typingMethod: TypingMethod {
        get { TypingMethod(rawValue: defaults.integer(forKey: Keys.typingMethod)) ?? .simulateTyping }
        set { defaults.set(newValue.rawValue, forKey: Keys.typingMethod) }
    }

    var asrModelVersion: String {
        get { defaults.string(forKey: Keys.asrModelVersion) ?? "v2" }
        set { defaults.set(newValue, forKey: Keys.asrModelVersion) }
    }

    var llmCleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmCleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmCleanupEnabled) }
    }

    var llmCleanupModel: String {
        get { defaults.string(forKey: Keys.llmCleanupModel) ?? "standard" }
        set { defaults.set(newValue, forKey: Keys.llmCleanupModel) }
    }

    var autoEnterEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoEnterEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoEnterEnabled) }
    }

    var vdiPatterns: String {
        get { defaults.string(forKey: Keys.vdiPatterns) ?? Self.defaultVDIPatterns }
        set { defaults.set(newValue, forKey: Keys.vdiPatterns) }
    }

    func restoreDefaults() {
        defaults.removeObject(forKey: Keys.inputDeviceUID)
        defaults.removeObject(forKey: Keys.pushHotKeyData)
        defaults.removeObject(forKey: Keys.toggleHotKeyData)
        defaults.removeObject(forKey: Keys.audioCueEnabled)
        defaults.removeObject(forKey: Keys.hapticCueEnabled)
        defaults.removeObject(forKey: Keys.typingDelayMs)
        defaults.removeObject(forKey: Keys.typingMethod)
        defaults.removeObject(forKey: Keys.vdiPatterns)
        defaults.removeObject(forKey: Keys.asrModelVersion)
        defaults.removeObject(forKey: Keys.llmCleanupEnabled)
        defaults.removeObject(forKey: Keys.llmCleanupModel)
        defaults.removeObject(forKey: Keys.autoEnterEnabled)
    }

    func isVDIApp(bundleID: String?, name: String?) -> Bool {
        let patterns = vdiPatterns
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let haystack = "\(bundleID?.lowercased() ?? "") \(name?.lowercased() ?? "")"
        return patterns.contains { haystack.contains($0) }
    }

    private func loadHotKey(for key: String, fallback: HotKey) -> HotKey {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            return decoded
        }
        return fallback
    }

    private func saveHotKey(_ hotKey: HotKey, key: String) {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: key)
        }
    }

    private func migrateLegacyHotKeyIfNeeded() {
        guard defaults.data(forKey: Keys.pushHotKeyData) == nil else { return }
        guard let data = defaults.data(forKey: Keys.legacyHotKeyData),
              let decoded = try? JSONDecoder().decode(HotKey.self, from: data) else {
            return
        }
        saveHotKey(decoded, key: Keys.pushHotKeyData)
    }
}
