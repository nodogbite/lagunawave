import AppKit
import ApplicationServices
import Foundation
import os

// @unchecked Sendable: all mutable state (cancelledLock) is behind
// OSAllocatedUnfairLock. All other properties are immutable or static.
final class TextTyper: @unchecked Sendable {
    private let punctuationDelayMs = 150
    private let cancelledLock = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        cancelledLock.withLock { $0 }
    }

    func cancelTyping() {
        cancelledLock.withLock { $0 = true }
    }

    private func resetCancelled() {
        cancelledLock.withLock { $0 = false }
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func typeText(_ text: String, method: TypingMethod, delayMs: Int) -> Bool {
        guard !text.isEmpty else { return false }
        guard AXIsProcessTrusted() else { return false }
        resetCancelled()

        switch method {
        case .simulateTyping:
            return typeViaUnicode(text, delayMs: delayMs)
        case .simulateKeypresses:
            return typeViaKeycodes(text, delayMs: delayMs, sourceStateID: .combinedSessionState, tapLocation: .cghidEventTap)
        case .paste:
            return typeViaPaste(text)
        }
    }

    func typeTextAsync(_ text: String, method: TypingMethod, delayMs: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.typeText(text, method: method, delayMs: delayMs)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Simulate Typing (Unicode string injection)

    private func typeViaUnicode(_ text: String, delayMs: Int) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.localEventsSuppressionInterval = 0

        let perCharDelayMs = max(0, delayMs)
        var posted = true
        var typed = 0
        for ch in text {
            if isCancelled { break }
            let success = postUnicode(character: ch, source: source)
            posted = posted && success
            typed += 1
            let extra = isSentenceBoundary(ch) ? punctuationDelayMs : 0
            sleepMs(perCharDelayMs + extra)
        }
        if isCancelled {
            Log.typing("TextTyper[unicode]: cancelled after \(typed)/\(text.count) chars")
        } else {
            Log.typing("TextTyper[unicode]: typed \(text.count) chars posted=\(posted) delay=\(perCharDelayMs)ms")
        }
        return posted
    }

    private func postUnicode(character: Character, source: CGEventSource) -> Bool {
        let utf16 = Array(String(character).utf16)
        var posted = false
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                keyDown.post(tap: .cghidEventTap)
                posted = true
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                keyUp.post(tap: .cghidEventTap)
                posted = posted && true
            } else {
                posted = false
            }
        }
        return posted
    }

    // MARK: - Simulate Keypresses (virtual keycode mapping, configurable source/tap)

    private func typeViaKeycodes(_ text: String, delayMs: Int, sourceStateID: CGEventSourceStateID?, tapLocation: CGEventTapLocation) -> Bool {
        let source: CGEventSource?
        if let stateID = sourceStateID {
            source = CGEventSource(stateID: stateID)
            source?.localEventsSuppressionInterval = 0
        } else {
            source = nil
        }

        let label = sourceStateID == nil ? "nil" : (sourceStateID == .hidSystemState ? "hid" : "combined")
        let tapLabel = tapLocation == .cgSessionEventTap ? "session" : "hid"

        let perCharDelayMs = max(0, delayMs)
        var posted = true
        var skipped = 0
        var typed = 0
        for ch in text {
            if isCancelled { break }
            if let mapping = Self.keycodeMap[ch] {
                let success = postKeycode(mapping.keyCode, shift: mapping.shift, source: source, tapLocation: tapLocation)
                posted = posted && success
                typed += 1
            } else {
                skipped += 1
            }
            let extra = isSentenceBoundary(ch) ? punctuationDelayMs : 0
            sleepMs(perCharDelayMs + extra)
        }
        if isCancelled {
            Log.typing("TextTyper[keycodes/\(label)/\(tapLabel)]: cancelled after \(typed)/\(text.count) chars")
        } else {
            if skipped > 0 {
                Log.typing("TextTyper[keycodes/\(label)/\(tapLabel)]: skipped \(skipped) unmapped chars")
            }
            Log.typing("TextTyper[keycodes/\(label)/\(tapLabel)]: typed \(text.count - skipped)/\(text.count) chars posted=\(posted) delay=\(perCharDelayMs)ms")
        }
        return posted
    }

    private func postKeycode(_ keyCode: CGKeyCode, shift: Bool, source: CGEventSource?, tapLocation: CGEventTapLocation) -> Bool {
        // Post separate shift key down/up events around the character.
        // VDI clients (VMware Horizon, Citrix) look for discrete modifier
        // key events in the stream — they ignore .flags on character events.
        if shift {
            guard let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) else { return false }
            shiftDown.flags = .maskShift
            shiftDown.post(tap: tapLocation)
            usleep(2000) // 2ms so VDI registers shift before character
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        let flags: CGEventFlags = shift ? .maskShift : []
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: tapLocation)
        keyUp.post(tap: tapLocation)

        if shift {
            guard let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else { return false }
            shiftUp.flags = []
            shiftUp.post(tap: tapLocation)
        }

        return true
    }

    // MARK: - Paste (clipboard + Cmd+V)

    private func typeViaPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sleepMs(50)

        let success = postCmdV()
        sleepMs(200)

        restorePasteboard(pasteboard, items: savedItems)
        Log.typing("TextTyper[paste]: pasted \(text.count) chars success=\(success)")
        return success
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.localEventsSuppressionInterval = 0

        // Virtual key code 9 = 'v'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Clipboard Save/Restore

    private struct PasteboardEntry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[PasteboardEntry]] {
        var saved: [[PasteboardEntry]] = []
        guard let items = pasteboard.pasteboardItems else { return saved }
        for item in items {
            var entries: [PasteboardEntry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append(PasteboardEntry(type: type, data: data))
                }
            }
            saved.append(entries)
        }
        return saved
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[PasteboardEntry]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        var pbItems: [NSPasteboardItem] = []
        for entries in items {
            let pbItem = NSPasteboardItem()
            for entry in entries {
                pbItem.setData(entry.data, forType: entry.type)
            }
            pbItems.append(pbItem)
        }
        pasteboard.writeObjects(pbItems)
    }

    // MARK: - Send Return

    @discardableResult
    func sendReturn() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.localEventsSuppressionInterval = 0
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            return false
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Helpers

    private func isSentenceBoundary(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "\n" || ch == "\r"
    }

    private func sleepMs(_ ms: Int) {
        guard ms > 0 else { return }
        usleep(useconds_t(ms * 1000))
    }

    // MARK: - US QWERTY Keycode Map

    // swiftlint:disable comma
    private static let keycodeMap: [Character: (keyCode: CGKeyCode, shift: Bool)] = [
        // Letters (lowercase)
        "a": (0, false),  "s": (1, false),  "d": (2, false),  "f": (3, false),
        "h": (4, false),  "g": (5, false),  "z": (6, false),  "x": (7, false),
        "c": (8, false),  "v": (9, false),  "b": (11, false), "q": (12, false),
        "w": (13, false), "e": (14, false), "r": (15, false), "y": (16, false),
        "t": (17, false), "1": (18, false), "2": (19, false), "3": (20, false),
        "4": (21, false), "5": (23, false), "6": (22, false), "7": (26, false),
        "8": (28, false), "9": (25, false), "0": (29, false), "o": (31, false),
        "u": (32, false), "[": (33, false), "i": (34, false), "p": (35, false),
        "l": (37, false), "j": (38, false), "'": (39, false), "k": (40, false),
        ";": (41, false), "\\": (42, false), ",": (43, false), "/": (44, false),
        "n": (45, false), "m": (46, false), ".": (47, false), "`": (50, false),
        "]": (30, false), "-": (27, false), "=": (24, false),

        // Letters (uppercase / shifted)
        "A": (0, true),  "S": (1, true),  "D": (2, true),  "F": (3, true),
        "H": (4, true),  "G": (5, true),  "Z": (6, true),  "X": (7, true),
        "C": (8, true),  "V": (9, true),  "B": (11, true), "Q": (12, true),
        "W": (13, true), "E": (14, true), "R": (15, true), "Y": (16, true),
        "T": (17, true), "O": (31, true), "U": (32, true), "I": (34, true),
        "P": (35, true), "L": (37, true), "J": (38, true), "K": (40, true),
        "N": (45, true), "M": (46, true),

        // Shifted number row symbols
        "!": (18, true), "@": (19, true), "#": (20, true), "$": (21, true),
        "%": (23, true), "^": (22, true), "&": (26, true), "*": (28, true),
        "(": (25, true), ")": (29, true),

        // Shifted punctuation
        "{": (33, true),  "}": (30, true),  "|": (42, true),
        ":": (41, true),  "\"": (39, true), "<": (43, true),
        ">": (47, true),  "?": (44, true),  "~": (50, true),
        "_": (27, true),  "+": (24, true),

        // Whitespace and control
        " ":  (49, false),   // Space
        "\t": (48, false),   // Tab
        "\n": (36, false),   // Return
        "\r": (36, false),   // Return
    ]
    // swiftlint:enable comma
}
